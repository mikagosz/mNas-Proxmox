import Testing
import Foundation
@testable import mNas

/// Historia na wykresach (spec 2026-10-04). Wejście zbieracza to prawdziwe wyjście
/// `rrdtool xport --json` z serwera testowego (`Fixtures.xportProbka`).
@Suite("Historia: xport zbieracza")
struct HistoriaParsersTests {
    @Test func brakZbieraczaToNil() {
        #expect(HistoriaParsers.zbieracz("@@BRAK\n") == nil)
    }

    @Test func prawdziwaProbkaDajeCpuMocIDysk() throws {
        let h = try #require(HistoriaParsers.zbieracz(Fixtures.xportProbka))
        #expect(h.wersja == 1)
        #expect(h.cpu.first?.id == "pakiet")
        #expect(h.cpu.filter { $0.id.hasPrefix("rdzen") }.map(\.id) == (0...5).map { "rdzen\($0)" })
        let moc = try #require(h.moc)
        #expect(moc.jednostka == .waty)
        let sr = try #require(moc.srednia)
        #expect(sr > 4 && sr < 5)
        let dysk = try #require(h.dyski["SERIAL1"])
        #expect(dysk.jednostka == .stopnie)
        #expect(dysk.szczyt == 34.9)
    }

    @Test func czasPunktuZeStartuIKroku() throws {
        let h = try #require(HistoriaParsers.zbieracz(Fixtures.xportProbka))
        let p = try #require(h.dyski["SERIAL1"]?.punkty)
        #expect(p.count == 9)
        #expect(p[0].czas == Date(timeIntervalSince1970: 1_791_071_160))
        #expect(p[3].czas == Date(timeIntervalSince1970: 1_791_071_340))
        #expect(p[0].wartosc == nil)
        #expect(p[3].wartosc == 34.9)
    }

    @Test func nullToDziuraNieZero() throws {
        let tekst = """
        @@WERSJA 1
        @@PLIK dysk-SERIAL2.rrd
        { "about": "RRDtool graph JSON output", "meta": { "start": 1000, "end": 1180, "step": 60, "legend": ["temp"] },
          "data": [ [ 4.1e+01 ], [ null ], [ 4.3e+01 ] ] }
        """
        let s = try #require(HistoriaParsers.zbieracz(tekst)?.dyski["SERIAL2"])
        #expect(s.punkty.map(\.wartosc) == [41, nil, 43])
        #expect(s.srednia == 42)
        #expect(s.ostatniOdczyt == Date(timeIntervalSince1970: 1120))
    }

    @Test func uszkodzonyPlikNieKasujeReszty() throws {
        let tekst = """
        @@WERSJA 1
        @@PLIK cpu.rrd
        ERROR: opening 'cpu.rrd': No such file
        @@PLIK dysk-SERIAL3.rrd
        { "about": "x", "meta": { "start": 0, "end": 60, "step": 60, "legend": ["temp"] }, "data": [ [ 3.0e+01 ] ] }
        """
        let h = try #require(HistoriaParsers.zbieracz(tekst))
        #expect(h.cpu.isEmpty)
        #expect(h.dyski["SERIAL3"]?.szczyt == 30)
    }

    @Test func brakWersjiToNil() throws {
        let tekst = "@@WERSJA \n"
        #expect(try #require(HistoriaParsers.zbieracz(tekst)).wersja == nil)
    }

    // MARK: - RRD Proxmoksa (Task 4)

    private func wiersze(_ json: String) throws -> [WierszRRD] {
        try JSONDecoder().decode([WierszRRD].self, from: Data(json.utf8))
    }

    @Test func cpuToProcentyZUlamka() throws {
        let w = try wiersze(Fixtures.rrdWezlaPelny)
        let s = HistoriaParsers.cpuProcent(RRDzMaksimami(srednie: w))
        #expect(s.jednostka == .procent)
        #expect(s.punkty.count == 5)
        #expect(s.punkty[0].wartosc == w[0].cpu.map { $0 * 100 })
        #expect((s.punkty[0].wartosc ?? 0) > 1)          // 0,08 ułamka → 8 %
    }

    @Test func ramHostaToMemused() throws {
        let w = try wiersze(Fixtures.rrdWezlaPelny)
        let s = HistoriaParsers.ramHosta(RRDzMaksimami(srednie: w))
        #expect(s.jednostka == .bajty)
        #expect(s.punkty[0].wartosc == w[0].memused)
        #expect(w[0].memtotal == 25_025_552_384)
    }

    @Test func kontenerMaMemIMaxmem() throws {
        let w = try wiersze(Fixtures.rrdKonteneraPelny)
        #expect(w.allSatisfy { $0.mem != nil })
        #expect(HistoriaParsers.przydzial(w) == w.last?.maxmem)
    }

    @Test func zatrzymanyKontenerNieWywracaWarstw() {
        // Kontener stał przez dwie środkowe minuty: RRD daje wiersze bez `mem`.
        let w = [WierszRRD(time: 60, mem: 100), WierszRRD(time: 120), WierszRRD(time: 180), WierszRRD(time: 240, mem: 300)]
        let s = HistoriaParsers.ramKontenerow([(nazwa: "samba", vmid: 104, wiersze: RRDzMaksimami(srednie: w))])
        #expect(s.first?.punkty.map(\.wartosc) == [100, nil, nil, 300])
        #expect(s.first?.id == "ct104")
        #expect(s.first?.nazwa == "samba")
    }

    @Test func kontenerySortowanePoSredniej() {
        let a = [WierszRRD(time: 60, mem: 10)], b = [WierszRRD(time: 60, mem: 99)]
        let s = HistoriaParsers.ramKontenerow([(nazwa: "a", vmid: 1, wiersze: RRDzMaksimami(srednie: a)), (nazwa: "b", vmid: 2, wiersze: RRDzMaksimami(srednie: b))])
        #expect(s.map(\.id) == ["ct2", "ct1"])
    }

    // MARK: - Maksima (od 1.2.43)

    /// Zgłoszenie 2026-10-22: CPU 30% w dobie, 19% w tygodniu, 13% w roku — średnie
    /// dłuższych przedziałów zjadały szczyt. Szczyt i linia idą z maksimów, średnia zostaje.
    @Test func maksimaRRDLaczonePoCzasie() {
        let sr = [WierszRRD(time: 60, mem: 10), WierszRRD(time: 120, mem: 20), WierszRRD(time: 180)]
        let mx = [WierszRRD(time: 120, mem: 90), WierszRRD(time: 60, mem: 30)]
        let s = HistoriaParsers.ramKontenerow([(nazwa: "a", vmid: 1, wiersze: RRDzMaksimami(srednie: sr, maksima: mx))])[0]
        #expect(s.punkty.map(\.maks) == [30, 90, nil])
        #expect(s.szczyt == 90)
        #expect(s.srednia == 15)
        #expect(HistoriaParsers.odcinki(s, warstwowy: false).map(\.count) == [2])
    }

    @Test func bezMaksimowSzczytZeSrednich() {
        let s = HistoriaParsers.ramKontenerow([(nazwa: "a", vmid: 1, wiersze: RRDzMaksimami(srednie: [WierszRRD(time: 60, mem: 40)]))])[0]
        #expect(s.szczyt == 40 && s.punkty[0].maks == nil)
    }

    @Test func kolumnaMaxZbieraczaDoklejonaDoSerii() throws {
        let tekst = """
        @@WERSJA 3
        @@PLIK dysk-S1.rrd
        {"meta":{"start":60,"step":1800,"end":180,"rows":2,"columns":2,"legend":["temp","temp.max"]},
         "data":[[30.5,41.0],[null,null]]}
        """
        let h = try #require(HistoriaParsers.zbieracz(tekst))
        let d = try #require(h.dyski["S1"])
        #expect(d.id == "temp")
        #expect(d.punkty.map(\.wartosc) == [30.5, nil])
        #expect(d.punkty.map(\.maks) == [41.0, nil])
        #expect(d.szczyt == 41.0 && d.srednia == 30.5)
    }

    @Test func odczytHistoriiBierzeMaksZPowrotemDoSrednich() {
        let c = ServerCommands.poleceniOdczytuHistorii(.week)
        #expect(c.contains(#""DEF:m$d=$f:$d:MAX" "XPORT:m$d:$d.max""#))
        #expect(c.contains(#""CDEF:m$d=rm$d,1000000,/""#))
        #expect(c.contains(#""${a[@]}" "${m[@]}" 2>/dev/null"#))
    }

    // MARK: - Stan zbieracza (Task 6)

    @Test func stanZbieracza() {
        #expect(HistoriaParsers.stan(nil) == .brak)
        #expect(HistoriaParsers.stan(HistoriaZbieracza(wersja: 0)) == .staraWersja(0))
        #expect(HistoriaParsers.stan(HistoriaZbieracza(wersja: nil)) == .staraWersja(0))
        #expect(HistoriaParsers.stan(HistoriaZbieracza(wersja: HistoriaZbieracz.wersja)) == .dziala)
        #expect(HistoriaParsers.stan(HistoriaZbieracza(wersja: HistoriaZbieracz.wersja + 1)) == .dziala)
    }

    @Test func nazwaMechanizmuZPrzebieguHosta() {
        let p = [Przebieg(id: "host./usr/local/bin/kopia-projektow-na-usb.sh", nazwa: "Kopia PROJEKTY", zrodlo: .host, stan: .udany)]
        #expect(HistoriaParsers.nazwaMechanizmu(skrypt: "/usr/local/bin/kopia-projektow-na-usb.sh", przebiegiHosta: p) == "Kopia PROJEKTY")
        #expect(HistoriaParsers.nazwaMechanizmu(skrypt: "/usr/local/bin/kopia-zdjec-na-usb.sh", przebiegiHosta: p) == "Kopia zdjec na usb")
    }

    @Test func logiDzieloneNaSkrypty() {
        let wyjscie = """
        ### /usr/local/bin/a.sh /var/log/a.log
        2026-10-04 01:00:00  OK: jeden
        ### /usr/local/bin/b.sh /var/log/b.log
        2026-10-04 02:00:00  BLAD: dwa
        """
        let w = HistoriaParsers.historiaLogowHosta(wyjscie, przebiegiHosta: [])
        #expect(w.map(\.mechanizm) == ["B", "A"])
        #expect(w.map(\.stan) == [.bledny, .udany])
    }

    // MARK: - Odcinki i formatowanie (Task 7)

    private func seria(_ v: [Double?]) -> SeriaHistorii {
        SeriaHistorii(id: "x", nazwa: "x", jednostka: .stopnie,
                      punkty: v.enumerated().map { PunktHistorii(czas: Date(timeIntervalSince1970: Double($0.offset * 60)), wartosc: $0.element) })
    }

    @Test func dziuraDzieliLinieNaOdcinki() {
        let o = HistoriaParsers.odcinki(seria([1, 2, nil, nil, 5, nil, 7]), warstwowy: false)
        #expect(o.map { $0.map(\.wartosc) } == [[1, 2], [5], [7]])
    }

    @Test func warstwyNieDzielaSieNaDziurach() {
        // Warstwy muszą się sumować w każdej minucie — dziura to zero, nie przerwa.
        let o = HistoriaParsers.odcinki(seria([1, nil, 3]), warstwowy: true)
        #expect(o.count == 1)
        #expect(o[0].map(\.wartosc) == [1, nil, 3])
    }

    @Test func pustaSeriaNieMaOdcinkow() {
        #expect(HistoriaParsers.odcinki(seria([nil, nil]), warstwowy: false).isEmpty)
    }

    @Test func formatWartosci() {
        #expect(FormatHistorii.wartosc(nil, .stopnie) == "—")
        #expect(FormatHistorii.wartosc(41.6, .stopnie) == "42 °C")
        #expect(FormatHistorii.wartosc(4.86, .waty) == "4,9 W" || FormatHistorii.wartosc(4.86, .waty) == "4.9 W")
        #expect(FormatHistorii.wartosc(8.2, .procent) == "8%")
    }


    // MARK: - Dysk w panelu ↔ plik zbieracza (Task 9)

    @Test func kluczDyskuJakWSkrypcie() {
        // Skrypt: `tr -cd 'A-Za-z0-9_-'` — sysfs NVMe dokleja spacje na końcu serialu.
        #expect(HistoriaParsers.kluczDysku("TESTSN0260        ") == "TESTSN0260")
        #expect(HistoriaParsers.kluczDysku("TESTSN-WX51") == "TESTSN-WX51")
        #expect(HistoriaParsers.kluczDysku(nil) == nil)
        #expect(HistoriaParsers.kluczDysku("  ") == nil)
    }

    /// 🔴 Proxmox podaje SSD za mostkiem USB jako `hdd` (zmierzone 2026-10-04: MX500 i NONAME
    /// mają `type: hdd`) — więc o talerzu nie decyduje typ z panelu, tylko to, czy zbieracz
    /// (który rozstrzyga po polu udev z obrotami) ma plik dla tego serialu.
    @Test func seriaDyskuPoSerialuNiePoTypie() throws {
        let h = try #require(HistoriaParsers.zbieracz(Fixtures.xportProbka))
        #expect(HistoriaParsers.seriaDysku(serial: "SERIAL1   ", w: h)?.szczyt == 34.9)
        #expect(HistoriaParsers.seriaDysku(serial: "INNY", w: h) == nil)
        #expect(HistoriaParsers.seriaDysku(serial: nil, w: h) == nil)
    }

    // MARK: - Poprawki po przeglądzie gałęzi

    /// Przegląd #1: energia liczona z czasu POKRYTEGO danymi, nie z szerokości zakresu.
    /// Zbieracz od 2 dni, zakres „Rok”: 5 W × 2 doby = 0,24 kWh, a nie 5 W × 366 dni.
    @Test func energiaTylkoZPokrytegoCzasu() {
        // Krok dobowy (zakres Rok): 2 dni z danymi, reszta pusta.
        var punkty = (0..<366).map { PunktHistorii(czas: Date(timeIntervalSince1970: Double($0 * 86_400)), wartosc: nil) }
        punkty[364].wartosc = 5
        punkty[365].wartosc = 5
        let s = SeriaHistorii(id: "moc", nazwa: "moc", jednostka: .waty, punkty: punkty)
        #expect(abs(HistoriaParsers.kWh(s) - 0.24) < 0.000_001)
    }

    @Test func energiaPustejSeriiToZero() {
        let s = SeriaHistorii(id: "moc", nazwa: "moc", jednostka: .waty,
                              punkty: [PunktHistorii(czas: Date(timeIntervalSince1970: 0), wartosc: nil)])
        #expect(HistoriaParsers.kWh(s) == 0)
    }

    /// Przegląd #3: czujka z logiem (np. co 10 min) nie może zasypać historii przebiegów.
    /// Gdy kafel zna już listę przebiegów hosta (bez czujek), historia bierze tylko je.
    @Test func historiaPomijaSkryptySpozaPrzebiegow() {
        let wyjscie = """
        ### /usr/local/bin/kopia.sh /var/log/kopia.log
        2026-10-04 01:00:00  OK: kopia
        ### /usr/local/bin/czujka.sh /var/log/czujka.log
        2026-10-04 01:10:00  OK: czujka
        """
        let znane = [Przebieg(id: "host./usr/local/bin/kopia.sh", nazwa: "Kopia", zrodlo: .host, stan: .udany)]
        #expect(HistoriaParsers.historiaLogowHosta(wyjscie, przebiegiHosta: znane).map(\.mechanizm) == ["Kopia"])
        // Lista jeszcze niewczytana — nie ma po czym odsiać, pokazujemy wszystko.
        #expect(HistoriaParsers.historiaLogowHosta(wyjscie, przebiegiHosta: []).count == 2)
    }

    /// Przegląd #4: spec każe w zakładce CPU pokazać też obciążenie (loadavg).
    @Test func obciazenieZRRDWezla() throws {
        let w = try wiersze(Fixtures.rrdWezlaPelny)
        let s = HistoriaParsers.obciazenie(RRDzMaksimami(srednie: w))
        #expect(s.jednostka == .liczba)
        #expect(s.punkty[0].wartosc == w[0].loadavg)
        #expect(FormatHistorii.wartosc(0.56, .liczba) == "0,56" || FormatHistorii.wartosc(0.56, .liczba) == "0.56")
    }
}
