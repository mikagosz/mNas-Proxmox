import Foundation
import os

/// Układ dashboardu zapisany w **pliku**, a nie w `UserDefaults`.
///
/// > [!important] Skąd to jest
/// > Zgłoszenie 2026-08-29: *„bardzo mnie denerwuje to, że z każdą nową wersją ja
/// > muszę sobie zasrane kafelki ustawiać na nowo, trzeba to zmienić, musi się
/// > zapisywać jakiś dokument config albo coś, żeby tego nie było"*.
/// >
/// > `UserDefaults` samo w sobie **nie było przyczyną** gubienia układu — przyczyna
/// > siedziała w `DashboardLayout.place`, patrz tam. Plik załatwia drugą połowę
/// > życzenia: układ da się **obejrzeć, skopiować na drugiego Maca i cofnąć ręcznie**,
/// > czego z binarnym `plist`-em zrobić się nie da.
///
/// Ścieżka: `~/Library/Application Support/mNas Proxmox/uklad-kafli.json`.
///
/// > [!danger] 🔴 Zapis jest atomowy i to nie jest ozdobnik
/// > Plik jest przepisywany przy **każdym** przesunięciu kafla. Zapis nieatomowy
/// > przerwany zamknięciem programu zostawiłby obcięty JSON, czyli dokładnie ten
/// > objaw, który ta klasa ma usunąć — układ „zniknął sam z siebie".
nonisolated struct KonfiguracjaUkladu: Codable, Equatable, Sendable {

    /// Numer formatu zapisu. Rośnie **tylko** przy zmianie niezgodnej wstecz.
    /// Plik z wyższym numerem niż zna ten program jest ignorowany, a nie zgadywany.
    var wersjaZapisu: Int = 1

    var kolejnosc: [String] = []
    var rozmiary: [String: String] = [:]
    var ukryte: [String] = []
    var zablokowane: [String] = []
    var pozycje: [String: GridPos] = [:]
    var odrzuconeAlerty: [String] = []
    /// Ustawienia panelu paska menu — P14. Osobny typ, patrz `UstawieniaPanelu`.
    var panelPaska: UstawieniaPanelu = .init()

    static let aktualnaWersjaZapisu = 1

    /// Własny dekoder niżej kasuje inicjalizator z pól, więc stoi tu wypisany wprost.
    init(wersjaZapisu: Int = KonfiguracjaUkladu.aktualnaWersjaZapisu,
         kolejnosc: [String] = [],
         rozmiary: [String: String] = [:],
         ukryte: [String] = [],
         zablokowane: [String] = [],
         pozycje: [String: GridPos] = [:],
         odrzuconeAlerty: [String] = [],
         panelPaska: UstawieniaPanelu = .init()) {
        self.wersjaZapisu = wersjaZapisu
        self.kolejnosc = kolejnosc
        self.rozmiary = rozmiary
        self.ukryte = ukryte
        self.zablokowane = zablokowane
        self.pozycje = pozycje
        self.odrzuconeAlerty = odrzuconeAlerty
        self.panelPaska = panelPaska
    }

    /// 🔴 Tak samo jak w `UstawieniaPanelu`: każde pole przez `decodeIfPresent`.
    ///
    /// Plik zapisany starszą wersją nie zna pól dodanych później. Syntezowany dekoder
    /// przewróciłby się na pierwszym brakującym kluczu i program zobaczyłby „nie ma
    /// zapisu" — czyli **układ kafli od nowa**, ten sam objaw co w P13. Nowe pole wolno
    /// tu dokładać wyłącznie z wartością zastępczą.
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        wersjaZapisu = try k.decodeIfPresent(Int.self, forKey: .wersjaZapisu) ?? Self.aktualnaWersjaZapisu
        kolejnosc = try k.decodeIfPresent([String].self, forKey: .kolejnosc) ?? []
        rozmiary = try k.decodeIfPresent([String: String].self, forKey: .rozmiary) ?? [:]
        ukryte = try k.decodeIfPresent([String].self, forKey: .ukryte) ?? []
        zablokowane = try k.decodeIfPresent([String].self, forKey: .zablokowane) ?? []
        pozycje = try k.decodeIfPresent([String: GridPos].self, forKey: .pozycje) ?? [:]
        odrzuconeAlerty = try k.decodeIfPresent([String].self, forKey: .odrzuconeAlerty) ?? []
        panelPaska = try k.decodeIfPresent(UstawieniaPanelu.self, forKey: .panelPaska) ?? .init()
    }
}

// MARK: - Magazyn na dysku

/// Czytanie i pisanie pliku układu. Wydzielone od `DashboardLayout`, żeby dało się
/// testować sam zapis bez budowania całego modelu okna.
///
/// > [!danger] 🔴 Pod testami magazyn **nie jest wyłączany, tylko przekierowywany**
/// > Pierwsza wersja tej klasy po prostu odcinała zapis, gdy leci przebieg testów —
/// > tak jak robi to `Keychain.podTestami`. Skutek był taki, że testy trwałości układu
/// > („kłódki przeżywają restart") zaczęły przechodzić **z powodu braku zapisu**,
/// > czyli sprawdzały nic. Dziś przebieg testów dostaje własny plik w katalogu
/// > tymczasowym: prawdziwy układ użytkownika jest tak samo nietykalny, a zapis dalej da się
/// > zmierzyć. To jest dokładnie ta pułapka, przed którą ostrzega reguła
/// > „zero z sita bez kontroli dodatniej znaczy «nie wiem»".
nonisolated struct MagazynUkladu: Sendable {

    var plik: URL

    /// Magazyn używany przez program. Pod testami wskazuje katalog tymczasowy,
    /// **nigdy** prawdziwy plik użytkownika.
    static var domyslny: MagazynUkladu {
        MagazynUkladu(plik: podTestami ? plikTestowy : plikProdukcyjny)
    }

    /// `Application Support`, nie `Documents` — to jest stan programu, a nie dokument
    /// użytkownika, mimo że użytkownik nazwał go „dokumentem config".
    static var katalogProdukcyjny: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("mNas Proxmox", isDirectory: true)
    }

    static var plikProdukcyjny: URL { katalogProdukcyjny.appendingPathComponent("uklad-kafli.json") }

    /// Osobny plik na każdy przebieg testów — inaczej dwa zestawy widziałyby swoje zapisy.
    static var plikTestowy: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mNasProxmox-testy-uklad-\(ProcessInfo.processInfo.processIdentifier).json")
    }

    static var podTestami: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    func wczytaj() -> KonfiguracjaUkladu? {
        guard let dane = try? Data(contentsOf: plik) else { return nil }
        guard let konf = try? JSONDecoder().decode(KonfiguracjaUkladu.self, from: dane) else {
            Log.uklad.error("Plik układu jest nieczytelny — odkładam kopię, wchodzi układ domyślny")
            odlozOdrzucony()
            return nil
        }
        // Plik z przyszłości: nie zgadujemy, co znaczą nieznane pola.
        guard konf.wersjaZapisu <= KonfiguracjaUkladu.aktualnaWersjaZapisu else {
            Log.uklad.error("Plik układu ma wersję \(konf.wersjaZapisu) — ten program zna \(KonfiguracjaUkladu.aktualnaWersjaZapisu)")
            odlozOdrzucony()
            return nil
        }
        return konf
    }

    /// Kopia odrzuconego pliku obok oryginału, zanim cokolwiek go nadpisze.
    ///
    /// Odrzucenie samo niczego nie kasowało, ale okno przy pierwszym pomiarze szerokości
    /// utrwala pozycje (`utrwalPozycje` → `persist()`), więc układ domyślny lądował na
    /// miejscu odrzuconego pliku — „zostaje nietknięty” było nieprawdą.
    /// Audyt SBW 2026-09-24, E3-S-P3-01. Kopia ze znacznikiem czasu: kolejne
    /// odrzucenie nie nadpisze poprzedniej.
    func odlozOdrzucony() {
        let znacznik = Int(Date().timeIntervalSince1970)
        let kopia = plik.deletingLastPathComponent()
            .appendingPathComponent("\(plik.lastPathComponent).odrzucony-\(znacznik)")
        do {
            try FileManager.default.copyItem(at: plik, to: kopia)
            Log.uklad.notice("Odrzucony plik układu odłożony: \(kopia.lastPathComponent, privacy: .public)")
        } catch {
            Log.uklad.error("Nie udało się odłożyć odrzuconego pliku układu: \(error.localizedDescription)")
        }
    }

    func zapisz(_ konf: KonfiguracjaUkladu) {
        do {
            try FileManager.default.createDirectory(at: plik.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let koder = JSONEncoder()
            // Czytelnie i w stałej kolejności — plik ma się dać obejrzeć okiem
            // i porównać `diff`-em między dwoma Makami.
            koder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try koder.encode(konf).write(to: plik, options: .atomic)
        } catch {
            Log.uklad.error("Nie udało się zapisać układu: \(error.localizedDescription)")
        }
    }

    /// Kasuje plik — używane przez testy, żeby każdy zestaw startował z czystego stanu.
    func wyczysc() {
        try? FileManager.default.removeItem(at: plik)
    }
}
