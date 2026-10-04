import Foundation
import CryptoKit
import Security
import os

/// Przypięcie serwera po odcisku **klucza publicznego** jego certyfikatu — TOFU,
/// dokładnie tak, jak od zawsze robi to drugi kanał do tego samego serwera: `known_hosts`
/// po stronie SSH.
///
/// Dlaczego to w ogóle jest: kanałem WebSocket leci jawny, bezterminowy klucz API konta
/// z `sudo = ALL`. Delegat akceptował wcześniej **dowolny** certyfikat, więc każde
/// urządzenie, które przejmie adres serwera w LAN (zatrucie ARP, podszycie się pod DHCP,
/// zmiana adresu — serwer nie ma rezerwacji IP na routerze), dostawało ten klucz
/// w pierwszej ramce.
///
/// Przypinamy klucz publiczny, nie cały certyfikat: dzięki temu odnowienie certyfikatu
/// przez TrueNAS-a (ta sama para kluczy, nowa data ważności) nie zrywa zaufania.
nonisolated enum CertificatePin {

    /// Własny plik — do 1.2.9 oba programy mNas pisały do wspólnego `pinned-certs.json`,
    /// wbrew zasadzie „dwa programy, dwa komplety poświadczeń” (`Keychain.swift`).
    /// TrueNAS od 1.1.1 ma `pinned-certs-truenas.json`; stary plik zostaje tylko do odczytu,
    /// żeby zapamiętane przypięcia przeszły bez ponownego TOFU. Audyt SBW, E1-B-P3-02.
    private static var storeURL: URL {
        directory.appendingPathComponent("pinned-certs-proxmox.json")
    }
    /// Plik, który zablokował połączenie: własny, a gdy go jeszcze nie ma — wspólny sprzed
    /// 1.2.10 (stamtąd przyszło „nieczytelne”, tam ma zajrzeć użytkownik).
    static var unreadableStorePath: String {
        FileManager.default.fileExists(atPath: storeURL.path) ? storeURL.path : legacyStoreURL.path
    }

    private static var legacyStoreURL: URL {
        directory.appendingPathComponent("pinned-certs.json")
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mNas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Odcisk

    /// SHA-256 z reprezentacji zewnętrznej klucza publicznego serwera.
    /// `nil`, gdy z zaufania nie da się wyciągnąć klucza — traktujemy to jako powód do
    /// odrzucenia połączenia, nie do przepuszczenia go „bo się nie udało sprawdzić".
    static func fingerprint(of trust: SecTrust) -> String? {
        guard let key = SecTrustCopyKey(trust) else { return nil }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            error?.release()
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Odcisk w formie do pokazania człowiekowi — pierwsze 32 znaki w czwórkach.
    /// Do porównania „na oko" z tym, co serwer pokazuje w panelu web, to wystarczy.
    static func display(_ fingerprint: String) -> String {
        let head = fingerprint.prefix(32)
        return stride(from: 0, to: head.count, by: 4).map { offset -> String in
            let start = head.index(head.startIndex, offsetBy: offset)
            let end = head.index(start, offsetBy: min(4, head.count - offset))
            return String(head[start..<end])
        }.joined(separator: " ")
    }

    // MARK: - Magazyn (Application Support/mNas/pinned-certs-proxmox.json)

    enum Lookup: Equatable {
        case pinned(String)
        /// Pierwsze połączenie z tym hostem — wolno zapamiętać to, co przyszło.
        case unknown
        /// Plik jest, ale nie da się go przeczytać. Przypięcie mogło w nim być, więc
        /// „nie wiem” nie może znaczyć „pierwszy raz” — inaczej uszkodzony plik po cichu
        /// wyłączałby całą ochronę, a za nowym certyfikatem poleciałby token.
        case storeUnreadable
    }

    static func lookup(_ host: String) -> Lookup {
        guard let all = load() else { return .storeUnreadable }
        return all[normalized(host)].map(Lookup.pinned) ?? .unknown
    }

    static func store(_ fingerprint: String, for host: String) {
        guard var all = load() else { return }
        all[normalized(host)] = fingerprint
        save(all)
    }

    /// Zapomina przypięcie — używane, gdy użytkownik świadomie zatwierdzi nowy certyfikat.
    /// Przy nieczytelnym pliku zaczyna od pustego: tamtych wpisów i tak nie da się odczytać.
    static func forget(host: String) {
        var all = load() ?? [:]
        all.removeValue(forKey: normalized(host))
        save(all)
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `nil` = plik jest, ale nieczytelny. Brak pliku to pusty magazyn.
    private static func load() -> [String: String]? {
        polacz(wlasny: read(storeURL), wspolny: read(legacyStoreURL))
    }

    /// Decyzja z dwóch odczytów (`nil` = brak pliku, `.some(nil)` = nieczytelny) —
    /// osobno, żeby test nie dotykał prawdziwego pliku w `Application Support`.
    ///
    /// 🔴 Nieczytelny **wspólny** plik też daje `nil`, nie pusty magazyn. Wcześniej przy
    /// braku własnego pliku zwracało `[:]`, czyli „pierwsze połączenie” — i pierwszy
    /// lepszy certyfikat przechodził bez pytania. Audyt SBW 2026-10-04, B-P3-01.
    static func polacz(wlasny: [String: String]??,
                       wspolny: @autoclosure () -> [String: String]??) -> [String: String]? {
        switch wlasny {
        case .some(.some(let dict)): return dict
        case .some(.none):           return nil
        case .none:
            switch wspolny() {
            case .some(.some(let dict)): return dict
            case .some(.none):           return nil
            case .none:                  return [:]
            }
        }
    }

    /// `nil` = brak pliku, `.some(nil)` = plik nieczytelny.
    private static func read(_ url: URL) -> [String: String]?? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return .some(nil) }
        return .some(dict)
    }

    /// Zapis atomowy: `removeItem` + `createFile` zostawiały przy przerwaniu w połowie
    /// brak pliku, czyli brak przypięć.
    private static func save(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let url = storeURL
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.certificate.error("Nie udało się zapisać przypięć certyfikatów: \(error.localizedDescription, privacy: .public)")
        }
    }
}
