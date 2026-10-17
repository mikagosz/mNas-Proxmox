import Foundation

// Aktualizacje serwera przez `pve-update-check` (od 1.2.30, 2026-10-16).
//
// Narzędzie stoi na hoście: codziennie o 7:30 sprawdza host, kontenery i aplikacje
// w nich (Nextcloud) i zostawia wynik w `/var/lib/pve-update-check/stan.json`.
// mNas tylko czyta ten plik, a instalację zleca jedną komendą w tle (`systemd-run`),
// po czym odpytuje `aktualizacja.json` — postęp w procentach, etap, wynik.
//
// 🔴 mNas nie składa komend z tekstu z serwera: ID maszyny to same cyfry, zakres
// z zamkniętej listy, ścieżka logu tylko z katalogu narzędzia (`AktualizacjeSerwera.poprawne*`).
// 🔴 Host PVE tylko do podglądu — na serwerze nowe jądro wymaga nagłówków i DKMS
// (karta sieciowa), więc host aktualizuje się ręcznie w SSH.

/// Pliki narzędzia w zasobach programu (`MyApp/Zasoby/puc-*`) — te same, które leżą
/// w paczce `pve-update-check` w Brudnopisie.
nonisolated enum NarzedzieAktualizacji {
    /// Musi się zgadzać z `VERSION=` w `puc-pve-update-check.sh` — pilnuje test.
    static let wersja = "2.8"
    static let sciezka = "/usr/local/bin/pve-update-check"
    static let katalogStanu = "/var/lib/pve-update-check"
    static let katalogLogow = "/var/log/pve-update-check/"
    /// Jednostka `systemd-run`, w której chodzi aktualizacja albo cofnięcie zlecone z mNas.
    static let jednostka = "pve-update-check-mnas"

    /// (zasób, miejsce na serwerze, uprawnienia, tylko gdy nie ma)
    static let pliki: [(zasob: String, cel: String, tryb: String, tylkoNowy: Bool)] = [
        ("puc-pve-update-check.sh", sciezka, "755", false),
        ("puc-upgrade.sh", "/usr/local/lib/pve-update-check/upgrade.sh", "644", false),
        ("puc-10-nextcloud.sh", "/etc/pve-update-check/checks.d/10-nextcloud.sh", "644", false),
        ("puc-20-docker.sh", "/etc/pve-update-check/checks.d/20-docker.sh", "644", false),
        ("puc-30-community-scripts.sh", "/etc/pve-update-check/checks.d/30-community-scripts.sh", "644", false),
        ("puc-config.example", "/etc/pve-update-check/config", "600", true),
        ("puc-apps.conf.example", "/etc/pve-update-check/apps.conf", "644", true),
        ("puc-pve-update-check.service", "/etc/systemd/system/pve-update-check.service", "644", false),
        ("puc-pve-update-check.timer", "/etc/systemd/system/pve-update-check.timer", "644", false),
        ("puc-pve-update-check-upgrade.service", "/etc/systemd/system/pve-update-check-upgrade.service", "644", false),
        ("puc-pve-update-check-upgrade.timer", "/etc/systemd/system/pve-update-check-upgrade.timer", "644", false),
    ]

    static func zasob(_ nazwa: String) -> String {
        let kropka = nazwa.firstIndex(of: ".")!
        let (n, r) = (String(nazwa[..<kropka]), String(nazwa[nazwa.index(after: kropka)...]))
        guard let url = Bundle.main.url(forResource: n, withExtension: r),
              let tekst = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return tekst
    }
}

// MARK: - Pliki stanu (kontrakt: MNAS.md w paczce pve-update-check)

nonisolated struct StanAktualizacji: Codable, Sendable, Equatable {
    var format: Int
    var wersja: String
    var host: String
    var sprawdzono: String
    var maszyny: [MaszynaAktualizacji]

    /// Maszyny, przy których jest coś do zrobienia: aktualizacje albo ponowne uruchomienie.
    var doAktualizacji: [MaszynaAktualizacji] { maszyny.filter { $0.maAktualizacje || $0.wymagaRestartu } }
}

nonisolated struct MaszynaAktualizacji: Codable, Sendable, Equatable, Identifiable {
    var typ: String
    var id: String
    var etykieta: String
    var system: String?
    var pakiety: Int
    var bezpieczenstwo: Int
    var listaPakietow: [Pakiet]?
    var aplikacje: Int
    var noweWersje: [String]
    var nextcloudSerwer: Bool
    var restart: Bool
    var bledy: [String]
    var wolneMb: Int?
    /// Od narzędzia 2.4: zainstalowana wersja Nextclouda i czy dostępna to nowa wersja GŁÓWNA (34 → 35).
    var nextcloudZainstalowany: String?
    var nextcloudGlowna: Bool?
    /// Od narzędzia 2.5: jednostki systemd, których procesy trzymają w pamięci podmienione biblioteki.
    var uslugiDoRestartu: [String]?
    /// Od 2.7, tylko host: jądro uruchomione, najnowsze zainstalowane i czy moduły DKMS
    /// (sterownik karty sieciowej r8152) są zbudowane dla najnowszego.
    var jadroUruchomione: String?
    var jadroNowe: String?
    var dkmsGotowe: Bool?
    var sprawdzono: String?

    struct Pakiet: Codable, Sendable, Equatable, Hashable {
        var nazwa: String
        var z: String
        var na: String
        var bezpieczenstwo: Bool
    }

    enum CodingKeys: String, CodingKey {
        case typ, id, etykieta, system, pakiety, bezpieczenstwo, aplikacje, restart, bledy, sprawdzono
        case listaPakietow = "lista_pakietow", noweWersje = "nowe_wersje"
        case nextcloudSerwer = "nextcloud_serwer", wolneMb = "wolne_mb"
        case nextcloudZainstalowany = "nextcloud_zainstalowany", nextcloudGlowna = "nextcloud_glowna"
        case uslugiDoRestartu = "uslugi_do_restartu"
        case jadroUruchomione = "jadro_uruchomione", jadroNowe = "jadro_nowe", dkmsGotowe = "dkms_gotowe"
    }

    var maAktualizacje: Bool { pakiety > 0 || aplikacje > 0 }

    /// Usługi, które da się uruchomić ponownie pojedynczo (`pve-update-check -R`). dbus, systemd
    /// i podobne wymagają restartu całego kontenera — ta sama lista co w skrypcie.
    var uslugiPojedynczo: [String] {
        (uslugiDoRestartu ?? []).filter { !Self.tylkoZKontenerem($0) }
    }
    var wymagaRestartuKontenera: Bool {
        restart || (uslugiDoRestartu ?? []).contains(where: Self.tylkoZKontenerem)
    }
    var wymagaRestartu: Bool { !uslugiPojedynczo.isEmpty || wymagaRestartuKontenera }

    /// Restart hosta wniesie nowe jądro (zainstalowane, jeszcze nie uruchomione).
    var czekaNoweJadro: Bool {
        guard let n = jadroNowe, let u = jadroUruchomione else { return false }
        return n != u
    }

    static func tylkoZKontenerem(_ u: String) -> Bool {
        u == "dbus.service" || u == "dbus-broker.service" || u == "init.scope" || u == "-.slice"
            || u.hasPrefix("systemd-") || u.hasPrefix("user@")
    }

    /// Jedyne, co jest do zainstalowania, to nowa wersja główna Nextclouda — obecna linia jest
    /// aktualna — kropka niebieska, jak przy „wszystko aktualne” (2026-10-16).
    var tylkoWersjaGlowna: Bool { pakiety == 0 && aplikacje == 1 && nextcloudGlowna == true }

    /// Kolor kropki: pomarańcz = poprawki bezpieczeństwa albo błąd, żółty = zwykłe aktualizacje,
    /// niebieski = aktualne (najwyżej nowa wersja główna do świadomej instalacji).
    enum Pilnosc: Int, Comparable, Sendable {
        case aktualne, wersjaGlowna, aktualizacje, pilne
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    var pilnosc: Pilnosc {
        if bezpieczenstwo > 0 || !bledy.isEmpty { return .pilne }
        if !uslugiPojedynczo.isEmpty || restart { return .aktualizacje }
        if tylkoWersjaGlowna { return .wersjaGlowna }
        if maAktualizacje { return .aktualizacje }
        // sam dbus/systemd po aktualizacji bibliotek: poprawka czeka na restart kontenera
        return wymagaRestartuKontenera ? .aktualizacje : .aktualne
    }
    var jestHostem: Bool { typ == "host" }
    /// Klucz do identyfikacji w widoku i w poleceniach — `ct:108`, `host:host`.
    var klucz: String { "\(typ):\(id)" }

    /// Teksty z `occ update:check` są po angielsku i długie — w mNas wystarczy
    /// „Nextcloud 34.0.5” albo „calendar 5.5.2”.
    var noweWersjeKrotko: [String] {
        noweWersje.map { t in
            let k = Self.skroc(t)
            guard nextcloudGlowna == true, t.contains(" is available"), !t.contains("Update for "),
                  let v = k.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else { return k }
            return String(localized: "nowa wersja główna Nextcloud \(String(k[v]))")
        }
    }

    static func skroc(_ t: String) -> String {
        var s = t
        if s.hasPrefix("Nextcloud: ") { s.removeFirst("Nextcloud: ".count) }
        if let r = s.range(of: #"^Nextcloud ([0-9.]+) is available.*"#, options: .regularExpression), !r.isEmpty,
           let v = s.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) {
            return String(localized: "serwer Nextcloud \(String(s[v]))")
        }
        if let r = s.range(of: #"^Update for (.+) to version ([0-9.]+) is available\.?$"#, options: .regularExpression), !r.isEmpty {
            let bez = s.replacingOccurrences(of: "Update for ", with: "")
                       .replacingOccurrences(of: " is available.", with: "")
                       .replacingOccurrences(of: " is available", with: "")
                       .replacingOccurrences(of: " to version ", with: " ")
            return String(localized: "Nextcloud: aplikacja \(bez)")
        }
        return s
    }
}

nonisolated struct PostepAktualizacji: Codable, Sendable, Equatable {
    var stan: String              // trwa | ok | bledy | nic | przerwana (od narzędzia 2.8 albo martwy pid)
    var maszyna: String?
    var zakres: String?
    var start: String?
    var koniec: String?
    var etap: String?
    var podsumowanie: String?
    var wyniki: [Wynik]
    var log: String?
    var postep: Int?
    /// Maszyny, po których snapshot albo plik kopii zniknął (odczyt `@@COFNIJ <id> 0`, nie z JSON-a).
    var bezKopii: [String]?

    struct Wynik: Codable, Sendable, Equatable {
        var typ: String
        var id: String
        var etykieta: String
        var wynik: String         // ok | blad | pominieto
        var snapshot: String?
        var problemy: String?
        var kopia: String?
        /// Weryfikacja przed sprzątaniem coś wykryła — co dokładnie (od narzędzia 2.3).
        var ostrzezenia: [String]?
        /// Co zostało do ręcznego skasowania (`pve-update-check -c ID`): `apt` albo `nc <ścieżka>`.
        var doSprzatania: [String]?

        enum CodingKeys: String, CodingKey {
            case typ, id, etykieta, wynik, snapshot, problemy, kopia, ostrzezenia
            case doSprzatania = "do_sprzatania"
        }

        /// Pozycje listy po ludzku: „pobrane pakiety apt”, „kopia updatera Nextclouda nextcloud-34.0.3…”.
        var doSprzataniaOpis: [String] {
            (doSprzatania ?? []).map { p in
                if p == "apt" { return String(localized: "pobrane pakiety apt (/var/cache/apt)") }
                if p.hasPrefix("nc ") { return String(localized: "kopia updatera Nextclouda \(p.split(separator: "/").last.map(String.init) ?? p)") }
                return p
            }
        }
    }

    var trwa: Bool { stan == "trwa" }
    var przerwana: Bool { stan == "przerwana" }
    /// „trwa” z procesem, którego już nie ma (SIGKILL, narzędzie sprzed 2.8) — wyniku nikt nie
    /// zapisał, więc nie ma też `koniec`. Przerwanie złapane przez samo narzędzie ma `koniec`.
    var przerwanaBezWyniku: Bool { przerwana && koniec == nil }
    var ulamek: Double { Double(min(max(postep ?? 0, 0), 100)) / 100 }
    /// Wynik, po którym coś czeka na ręczne skasowanie.
    var doSprzatania: Wynik? {
        guard zakres != "sprzatanie" else { return nil }
        return wyniki.first { !($0.doSprzatania ?? []).isEmpty }
    }

    /// Czy po tej aktualizacji jest do czego wrócić (snapshot `puc_` albo kopia vzdump),
    /// i czy serwer ich jeszcze nie skasował.
    var moznaCofnac: Wynik? {
        guard zakres != "cofniecie", zakres != "sprzatanie" else { return nil }
        let brak = Set(bezKopii ?? [])
        return wyniki.first { $0.wynik != "pominieto" && ($0.snapshot != nil || $0.kopia != nil) && !brak.contains($0.id) }
    }
}

/// Zakres aktualizacji — tylko te trzy wartości idą do komendy (`-o`).
nonisolated enum ZakresAktualizacji: String, CaseIterable, Sendable, Identifiable {
    case wszystko, pakiety, aplikacje
    var id: String { rawValue }
    var opis: String {
        switch self {
        case .wszystko:  return String(localized: "Wszystko")
        case .pakiety:   return String(localized: "Tylko pakiety systemu")
        case .aplikacje: return String(localized: "Tylko aplikacje")
        }
    }
}

/// Wynik jednego odczytu z serwera: stan narzędzia, ostatnie sprawdzenie, postęp.
nonisolated struct OdczytAktualizacji: Sendable, Equatable {
    enum Narzedzie: Sendable, Equatable { case brak, staraWersja(String), jest(String) }
    var narzedzie: Narzedzie
    var stan: StanAktualizacji?
    var postep: PostepAktualizacji?
    /// Maszyny z czymś do zainstalowania — kropka pomarańczowa albo żółta (ta sama reguła co kafel).
    /// Znak aktualizacji na ikonce w pasku menu (1.2.39).
    var doZainstalowania: Int { stan?.doAktualizacji.filter { $0.pilnosc >= .aktualizacje }.count ?? 0 }
    /// Jednostka `pve-update-check-mnas` (aktualizacja albo cofnięcie) albo sprawdzanie
    /// z timera — póki coś chodzi, nowego startu nie zlecamy.
    var zajete: Bool
    var sprawdzaTeraz: Bool
    var ogonLogu: [String]
}

nonisolated enum AktualizacjeParsers {
    /// Wyjście `ServerCommands.poleceniOdczytuAktualizacji` — sekcje po znacznikach `@@`.
    static func odczyt(_ tekst: String) -> OdczytAktualizacji {
        var wersja: String?
        var sekcje: [String: [String]] = [:]
        var biezaca = ""
        var jednostka = "", timer = ""
        var martwy = false
        var bezKopii: [String] = []
        for linia in tekst.components(separatedBy: "\n") {
            if linia.hasPrefix("@@WERSJA") {
                let w = linia.dropFirst("@@WERSJA".count).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").last ?? ""
                wersja = w.isEmpty ? nil : w
            } else if linia.hasPrefix("@@JEDNOSTKA") {
                jednostka = linia.dropFirst("@@JEDNOSTKA".count).trimmingCharacters(in: .whitespaces)
            } else if linia.hasPrefix("@@TIMER") {
                timer = linia.dropFirst("@@TIMER".count).trimmingCharacters(in: .whitespaces)
            } else if linia.hasPrefix("@@MARTWY") { martwy = true; biezaca = ""
            } else if linia.hasPrefix("@@COFNIJ") {
                let p = linia.split(separator: " ")
                if p.count == 3, p[2] == "0" { bezKopii.append(String(p[1])) }
                biezaca = ""
            } else if linia.hasPrefix("@@STAN") { biezaca = "stan" }
            else if linia.hasPrefix("@@POSTEP") { biezaca = "postep" }
            else if linia.hasPrefix("@@LOG") { biezaca = "log" }
            else if linia.hasPrefix("@@KONIEC") { biezaca = "" }
            else if !biezaca.isEmpty { sekcje[biezaca, default: []].append(linia) }
        }
        let dekoder = JSONDecoder()
        func json<T: Decodable>(_ k: String, _ t: T.Type) -> T? {
            guard let l = sekcje[k], !l.contains("@@BRAK") else { return nil }
            return try? dekoder.decode(T.self, from: Data(l.joined(separator: "\n").utf8))
        }
        let narzedzie: OdczytAktualizacji.Narzedzie
        if let wersja {
            narzedzie = wersja.compare(NarzedzieAktualizacji.wersja, options: .numeric) == .orderedAscending
                ? .staraWersja(wersja) : .jest(wersja)
        } else { narzedzie = .brak }
        // „trwa” z martwym pid nie skończy się nigdy — pasek stał na 61% także po restarcie
        // programu (2026-10-16). Pokazujemy to jako przerwaną aktualizację z logiem.
        var postep = json("postep", PostepAktualizacji.self)
        if martwy, postep?.trwa == true { postep?.stan = "przerwana" }
        if !bezKopii.isEmpty { postep?.bezKopii = bezKopii }
        return OdczytAktualizacji(
            narzedzie: narzedzie,
            stan: json("stan", StanAktualizacji.self),
            postep: postep,
            zajete: jednostka == "active" || jednostka == "activating",
            sprawdzaTeraz: timer == "active" || timer == "activating",
            ogonLogu: (sekcje["log"] ?? []).map(bezSterujacych).filter { !$0.isEmpty })
    }

    /// Sekwencje sterujące terminala (`ESC[2K`, `ESC[5D` — paski z `updater.phar`) i `\r`.
    static func bezSterujacych(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
         .replacingOccurrences(of: "\r", with: "")
         .trimmingCharacters(in: .whitespaces)
    }

    /// Numer CT/VM — same cyfry, bez zera na początku i bez przesadnej długości.
    static func poprawneID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 9 && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) && s.first != "0"
    }

    /// Log tylko z katalogu narzędzia i tylko z bezpiecznych znaków — idzie do `tail`.
    static func poprawnyLog(_ s: String) -> Bool {
        guard s.hasPrefix(NarzedzieAktualizacji.katalogLogow), !s.contains("..") else { return false }
        return s.unicodeScalars.allSatisfy { u in
            CharacterSet.alphanumerics.contains(u) && u.isASCII || "/-_.".unicodeScalars.contains(u)
        }
    }

    /// Data ISO 8601 z serwera (`2026-10-16T07:30:12+02:00`).
    static func data(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}
