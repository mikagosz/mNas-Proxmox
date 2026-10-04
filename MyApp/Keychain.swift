import Foundation
import Security
import os

/// Sekret tokenu API trzymamy w Keychain. Plik w Application Support jest **wyłącznie
/// awaryjny** — powstaje dopiero wtedy, gdy `SecItemAdd` odmówi (apka bywała niepodpisana
/// → odpowiedź `errSecMissingEntitlement` i klucz „znikał" po restarcie).
///
/// Wcześniej zapis do pliku był bezwarunkowy, więc słabszy magazyn istniał nawet wtedy,
/// gdy Keychain przyjął klucz bez problemu — a przełącznik w oknie łączenia obiecywał
/// tylko Keychain. Teraz: sukces Keychain **kasuje** ewentualny stary plik.
///
/// > Wszystkie identyfikatory są **rozdzielone od wersji pod TrueNAS-a**: inna usługa
/// > Keychain, inny katalog awaryjny, inne klucze UserDefaults. Obie apki stoją na tym
/// > samym Macu i sekret Proxmoksa nie ma nic wspólnego z kluczem TrueNAS-a — wspólny
/// > magazyn oznaczałby, że jedna po cichu podstawia drugiej dane, które nigdy nie zadziałają.
/// > Z tego samego powodu **nie ma tu migracji ze starej nazwy usługi**.
enum Keychain {
    private static let service = "com.mikagosz.mNasProxmox"
    private static let account = "proxmox-api-token"

    /// Czy jesteśmy w środku przebiegu testów.
    ///
    /// > [!danger] Dlaczego testy nie mają prawa dotknąć pęku kluczy
    /// > Zgłoszenie [U] 2026-08-23: *„ciągle wyskakuje mi okno do wpisywania hasła
    /// > systemowego, CIĄGLE"*. Treść okna, ze zrzutu: *„Aplikacja mNas Proxmox potrzebuje
    /// > dostępu do klucza «com.mikagosz.mNasProxmox» w Twoim pęku kluczy"*.
    /// >
    /// > Przyczyna: `TEST_HOST` w konfiguracji testów to **`mNas.app`**, więc każde
    /// > uruchomienie testów startuje prawdziwą aplikację, a ta przy starcie sięga po
    /// > zapisany token. Każdy build daje inną binarkę, więc pozwolenie z poprzedniego
    /// > razu nie obowiązuje i system pyta od nowa — przy każdym przebiegu testów.
    /// >
    /// > Testy tego tokenu nie potrzebują: sprawdzają parsery, nie łączenie się z serwerem.
    /// > Pod testami czytanie zwraca więc `nil`, a zapis nic nie robi. Okno przestaje
    /// > wyskakiwać, a normalne uruchomienie aplikacji zachowuje się bez zmian.
    ///
    /// `XCTestConfigurationFilePath` ustawia sam runner — zmienna istnieje **wyłącznie**
    /// w przebiegu testów i nie da się jej pomylić z niczym innym.
    static var podTestami: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    // MARK: - Klucz API

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        guard !podTestami else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)

        if status == errSecSuccess {
            // Keychain zadziałał — słabszy magazyn nie ma prawa dalej istnieć.
            deleteKeyFile()
            Log.keychain.notice("Klucz API zapisany w Keychain")
        } else {
            saveKeyFile(key)
            Log.keychain.error("SecItemAdd = \(status, privacy: .public) — awaryjnie plik w Application Support (0600)")
        }
        return status == errSecSuccess
    }

    static func loadAPIKey() -> String? {
        guard !podTestami else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, !data.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }
        // Keychain pusty/odmówił → plik awaryjny.
        return loadKeyFile()
    }

    static func deleteAPIKey() {
        // Kasowanie też pod blokadą — przebieg testów nie ma prawa ruszyć zapisanego
        // tokenu [U]. To by było gorsze niż samo okienko.
        guard !podTestami else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        deleteKeyFile()
    }

    // MARK: - Magazyn awaryjny (Application Support/mNas-Proxmox/api-token)

    private static var keyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mNas-Proxmox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("api-token")
    }

    /// Prawa 0600 nadajemy **przy tworzeniu**, nie po zapisie. `Data.write` zakłada prawa
    /// z umask (zwykle 0644) i dopiero osobne `setAttributes` je zawężało — między tymi
    /// krokami plik z kluczem był czytelny dla innych kont.
    private static func saveKeyFile(_ key: String) {
        let url = keyFileURL
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path,
                                       contents: Data(key.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    private static func deleteKeyFile() {
        try? FileManager.default.removeItem(at: keyFileURL)
    }

    private static func loadKeyFile() -> String? {
        guard let data = try? Data(contentsOf: keyFileURL), !data.isEmpty else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: - Adres i użytkownik (UserDefaults)
    //
    // Nie są tajemnicą, więc świadomie nie idą do Keychain — ale trzymamy je tutaj,
    // żeby całe „co apka pamięta między uruchomieniami" było w jednym miejscu.

    static func saveHost(_ host: String) { UserDefaults.standard.set(host, forKey: "mNasProxmox.host") }
    static func loadHost() -> String? { UserDefaults.standard.string(forKey: "mNasProxmox.host") }

    static func saveUsername(_ user: String) { UserDefaults.standard.set(user, forKey: "mNasProxmox.username") }
    static func loadUsername() -> String? { UserDefaults.standard.string(forKey: "mNasProxmox.username") }
}
