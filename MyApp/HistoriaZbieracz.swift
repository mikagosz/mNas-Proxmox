import Foundation

/// Zbieracz historii po stronie serwera — skrypt i jednostki systemd, które mNas
/// wgrywa przez SSH (spec: Historia-wykresy-projekt-2026-10-04, część 1).
///
/// Treść leży w zasobach (`MyApp/Zasoby/`), nie w literale: to ten sam plik, który
/// czyta człowiek, kiedy sprawdza, co mNas wgrał na serwer.
nonisolated enum HistoriaZbieracz {
    /// Musi się zgadzać z `WERSJA=` w skrypcie — pilnuje test. Podbij przy każdej
    /// zmianie skryptu albo jednostek, inaczej drugi Mac nie zaproponuje aktualizacji.
    static let wersja = 3

    static let katalog = "/var/lib/mnas-historia"
    static let sciezkaSkryptu = "/usr/local/bin/mnas-historia"

    static var skrypt: String { zasob("mnas-historia", "sh") }
    static var usluga: String { zasob("mnas-historia", "service") }
    static var timer: String { zasob("mnas-historia", "timer") }

    private static func zasob(_ nazwa: String, _ rozszerzenie: String) -> String {
        guard let url = Bundle.main.url(forResource: nazwa, withExtension: rozszerzenie),
              let tekst = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return tekst
    }
}
