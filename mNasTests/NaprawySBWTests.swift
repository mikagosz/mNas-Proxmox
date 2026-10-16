import Testing
import Foundation
@testable import mNas

/// Naprawy po audycie SBW 2026-09-24 (mNas Proxmox 1.2.10). Każdy test pada na kodzie 1.2.9.

@MainActor
@Suite("Audyt SBW: testy nie dotykają danych programu", .serialized)
struct TestyNieDotykajaDanychTests {

    /// E1-S-P1-01. Do 1.2.9 `UserDefaults.standard` pod testami = domena działającego
    /// mNasa, więc każdy przebieg kasował historię zdarzeń użytkownika.
    @Test("Rejestr zdarzeń i odhaczenia piszą do domeny testowej, nie do domeny programu")
    func osobnaDomena() {
        #expect(MagazynUstawien.domyslny !== UserDefaults.standard)

        let przed = UserDefaults.standard.data(forKey: "mNasProxmox.zdarzenia")
        MagazynUstawien.domyslny.removeObject(forKey: "mNasProxmox.zdarzenia")
        let rejestr = RejestrZdarzen()
        rejestr.dopisz(przebieg: Przebieg(id: "sbw", nazwa: "Próbka SBW", zrodlo: .host, stan: .udany),
                       poprzedniStan: nil)

        // Kontrola dodatnia: zapis doszedł — do domeny testowej.
        #expect(MagazynUstawien.domyslny.data(forKey: "mNasProxmox.zdarzenia") != nil)
        // Domena programu bez zmian.
        #expect(UserDefaults.standard.data(forKey: "mNasProxmox.zdarzenia") == przed)
    }
}

@MainActor
@Suite("Audyt SBW: liczby i plik układu")
struct LiczbyIPlikUkladuTests {

    private func dekoduj(_ json: String) throws -> Int64? {
        try JSONDecoder().decode([FlexibleInt].self, from: Data(json.utf8))[0].value
    }

    /// E1-S-P3-01. `Int64(1e19)` to pułapka procesu — test na starym kodzie nie
    /// „pada”, tylko wywraca cały przebieg (kod 133).
    @Test("Liczba spoza Int64 daje brak wartości zamiast zabić program")
    func liczbaSpozaZakresu() throws {
        #expect(try dekoduj("[123]") == 123)
        #expect(try dekoduj("[1.5e18]") == 1_500_000_000_000_000_000)
        #expect(try dekoduj("[2.9]") == 2)
        #expect(try dekoduj("[1e19]") == nil)
        #expect(try dekoduj("[-1e19]") == nil)
    }

    /// E3-S-P3-01, część 1: odrzucony plik zostaje odłożony, zanim coś go nadpisze.
    @Test("Nieczytelny plik układu ląduje w kopii obok")
    func odrzuconyPlikOdlozony() throws {
        let katalog = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mNasProxmox-test-odrzucony-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: katalog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: katalog) }
        let plik = katalog.appendingPathComponent("uklad-kafli.json")
        try Data("{ to nie jest json".utf8).write(to: plik)

        #expect(MagazynUkladu(plik: plik).wczytaj() == nil)

        let kopie = try FileManager.default.contentsOfDirectory(atPath: katalog.path)
            .filter { $0.hasPrefix("uklad-kafli.json.odrzucony-") }
        #expect(kopie.count == 1)
        if let kopia = kopie.first {
            let tresc = try String(contentsOf: katalog.appendingPathComponent(kopia), encoding: .utf8)
            #expect(tresc == "{ to nie jest json")
        }
    }

    /// E3-S-P3-01, część 2: `row` bliski `Int.max` przepełniał `pos.row + size.rows`.
    @Test("Pozycja z pliku przycięta do rozsądnych granic")
    func pozycjaPrzycieta() {
        let p = DashboardLayout.przytnijZPliku(GridPos(col: -3, row: Int.max - 1))
        #expect(p.col == 0)
        #expect(p.row == DashboardLayout.maksWierszZPliku)
        #expect(DashboardLayout.przytnijZPliku(GridPos(col: 2, row: 5)) == GridPos(col: 2, row: 5))
    }
}

/// Naprawy po audycie SBW 2026-10-04 (różnicowy 1.2.9 → 1.2.23).
@Suite("Naprawy SBW 2026-10-04")
struct NaprawySBW20261004Tests {
    @Test("B-P3-01: nieczytelny wspólny plik przypięć blokuje, zamiast udawać pierwsze połączenie")
    func wspolnyNieczytelny() {
        let jeden = ["pve": "abc"]
        // własny czytelny — wygrywa, wspólnego nie trzeba
        #expect(CertificatePin.polacz(wlasny: .some(.some(jeden)), wspolny: .some(nil)) == jeden)
        // własny nieczytelny — blokada
        #expect(CertificatePin.polacz(wlasny: .some(nil), wspolny: nil) == nil)
        // własnego brak, wspólny czytelny — przechodzi stare przypięcie
        #expect(CertificatePin.polacz(wlasny: nil, wspolny: .some(.some(jeden))) == jeden)
        // własnego brak, wspólny NIECZYTELNY — blokada (przed naprawą: pusty magazyn, czyli TOFU)
        #expect(CertificatePin.polacz(wlasny: nil, wspolny: .some(nil)) == nil)
        // żadnego pliku — naprawdę pierwsze połączenie
        #expect(CertificatePin.polacz(wlasny: nil, wspolny: nil) == [:])
    }

    @Test("S-P3-02: usługa zbieracza ma limit czasu, a wersja jest podbita")
    func limitZbieracza() {
        #expect(HistoriaZbieracz.usluga.contains("TimeoutStartSec="))
        #expect(HistoriaZbieracz.wersja >= 3)
        #expect(HistoriaZbieracz.skrypt.contains("WERSJA=\(HistoriaZbieracz.wersja)"))
    }
}
