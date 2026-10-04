import Foundation

// Historia na wykresach (spec 2026-10-04).
//
// Dwa źródła, jeden kształt: zbieracz `mnas-historia` na serwerze (temperatury, moc —
// `rrdtool xport --json`) i RRD Proxmoksa (CPU, RAM). Oba sprowadzamy do `SeriaHistorii`,
// żeby wykres nie musiał wiedzieć, skąd przyszły liczby.

nonisolated struct PunktHistorii: Sendable, Hashable {
    var czas: Date
    /// `nil` = brak próbki (host stał, timer nie tyknął). Wykres rysuje dziurę, nie zero.
    var wartosc: Double?
}

/// `przeplyw` = bajty na sekundę (zapisy i odczyty dysków, od 1.2.16).
nonisolated enum JednostkaHistorii: Sendable { case stopnie, waty, procent, bajty, liczba, przeplyw }

nonisolated struct SeriaHistorii: Identifiable, Sendable, Hashable {
    var id: String
    var nazwa: String
    var jednostka: JednostkaHistorii
    var punkty: [PunktHistorii]

    private var wartosci: [Double] { punkty.compactMap(\.wartosc) }
    var srednia: Double? { wartosci.isEmpty ? nil : wartosci.reduce(0, +) / Double(wartosci.count) }
    var szczyt: Double? { wartosci.max() }
    var ostatniOdczyt: Date? { punkty.last { $0.wartosc != nil }?.czas }
}

nonisolated struct HistoriaZbieracza: Sendable {
    var wersja: Int?
    var cpu: [SeriaHistorii] = []
    var moc: SeriaHistorii?
    /// Klucz: numer seryjny dysku — ten sam, po którym mNas trzyma temperatury od 1.2.6.
    var dyski: [String: SeriaHistorii] = [:]
    /// Od wersji 2 zbieracza. Klucz: ścieżka montowania (`/`, `/mnt/zasoby`…);
    /// serie `zajete` i `calosc` w bajtach.
    var miejsce: [String: [SeriaHistorii]] = [:]
    /// Od wersji 2. Klucz: numer seryjny dysku; serie `odczyt` i `zapis` w B/s.
    var io: [String: [SeriaHistorii]] = [:]
}

nonisolated enum HistoriaParsers {
    /// Kształt `rrdtool 1.7.2 xport --json`, zmierzony 2026-10-04: brak próbki to `null`,
    /// czasu w wierszu nie ma — liczy się go ze `start` + indeks × `step`.
    private struct Xport: Decodable {
        struct Meta: Decodable { var start: Int; var step: Int; var legend: [String] }
        var meta: Meta
        var data: [[Double?]]
    }

    /// Wyjście `ServerCommands.poleceniOdczytuHistorii`. `nil` = zbieracza na serwerze nie ma.
    /// Plik, którego `xport` nie oddał (błąd rrdtool), po prostu wypada — reszta zostaje.
    static func zbieracz(_ tekst: String) -> HistoriaZbieracza? {
        let sekcje = StatsParsers.splitSections(tekst)
        if sekcje["BRAK"] != nil { return nil }
        var h = HistoriaZbieracza()
        for (klucz, tresc) in sekcje {
            if klucz.hasPrefix("WERSJA") {
                h.wersja = Int(klucz.dropFirst("WERSJA".count).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard klucz.hasPrefix("PLIK ") else { continue }
            let plik = String(klucz.dropFirst("PLIK ".count))
            guard let x = try? JSONDecoder().decode(Xport.self, from: Data(tresc.utf8)) else { continue }
            let jednostka: JednostkaHistorii = plik == "moc.rrd" ? .waty
                : plik.hasPrefix("miejsce-") ? .bajty
                : plik.hasPrefix("io-") ? .przeplyw
                : .stopnie
            let serie = x.meta.legend.enumerated().map { (i, ds) in
                SeriaHistorii(id: ds, nazwa: nazwa(ds), jednostka: jednostka,
                              punkty: x.data.enumerated().map { (j, wiersz) in
                                  PunktHistorii(czas: Date(timeIntervalSince1970: TimeInterval(x.meta.start + j * x.meta.step)),
                                                wartosc: i < wiersz.count ? wiersz[i] : nil)
                              })
            }
            switch plik {
            case "cpu.rrd":
                h.cpu = serie.sorted { porzadek($0.id) < porzadek($1.id) }
            case "moc.rrd":
                h.moc = serie.first.map { var s = $0; s.id = "moc"; s.nazwa = String(localized: "Procesor (RAPL)"); return s }
            default:
                if plik.hasPrefix("dysk-"), plik.hasSuffix(".rrd"), let s = serie.first {
                    h.dyski[String(plik.dropFirst(5).dropLast(4))] = s
                } else if plik.hasPrefix("miejsce-"), plik.hasSuffix(".rrd") {
                    // Skrypt zamienia '/' na '_' — tu wracamy do ścieżki.
                    let sciezka = String(plik.dropFirst("miejsce-".count).dropLast(4))
                        .replacingOccurrences(of: "_", with: "/")
                    h.miejsce[sciezka] = serie
                } else if plik.hasPrefix("io-"), plik.hasSuffix(".rrd") {
                    h.io[String(plik.dropFirst(3).dropLast(4))] = serie
                }
            }
        }
        return h
    }

    private static func nazwa(_ ds: String) -> String {
        if ds == "pakiet" { return String(localized: "Cały procesor") }
        if ds.hasPrefix("rdzen") {
            if let n = Int(ds.dropFirst(5)) { return String(localized: "Rdzeń \(n)") }
            return ds
        }
        return ds
    }

    private static func porzadek(_ id: String) -> Int {
        id == "pakiet" ? -1 : Int(id.dropFirst(5)) ?? 999
    }

    // MARK: - RRD Proxmoksa — CPU i RAM

    private static func seria(_ w: [WierszRRD], id: String, nazwa: String,
                              jednostka: JednostkaHistorii, _ v: (WierszRRD) -> Double?) -> SeriaHistorii {
        SeriaHistorii(id: id, nazwa: nazwa, jednostka: jednostka,
                      punkty: w.map { PunktHistorii(czas: Date(timeIntervalSince1970: TimeInterval($0.time)), wartosc: v($0)) })
    }

    /// RRD podaje `cpu` jako ułamek 0–1 — na wykresie procenty.
    static func cpuProcent(_ w: [WierszRRD]) -> SeriaHistorii {
        seria(w, id: "cpu", nazwa: String(localized: "Wykorzystanie CPU"), jednostka: .procent) { $0.cpu.map { $0 * 100 } }
    }

    /// Obciążenie (loadavg 1 min) — spec: zakładka CPU pokazuje „CPU %, obciążenie, temp.”.
    static func obciazenie(_ w: [WierszRRD]) -> SeriaHistorii {
        seria(w, id: "loadavg", nazwa: String(localized: "Obciążenie (1 min)"), jednostka: .liczba) { $0.loadavg }
    }

    static func ramHosta(_ w: [WierszRRD]) -> SeriaHistorii {
        seria(w, id: "ram", nazwa: String(localized: "RAM hosta"), jednostka: .bajty) { $0.memused }
    }

    /// Warstwy wykresu RAM: kontener z największą średnią na dole. Zatrzymany kontener
    /// daje `nil` w swoich minutach — warstwa ma tam dziurę, reszta stoi.
    static func ramKontenerow(_ goscie: [(nazwa: String, vmid: Int, wiersze: [WierszRRD])]) -> [SeriaHistorii] {
        goscie.map { g in seria(g.wiersze, id: "ct\(g.vmid)", nazwa: g.nazwa, jednostka: .bajty) { $0.mem } }
              .sorted { ($0.srednia ?? 0) > ($1.srednia ?? 0) }
    }

    /// Przydział pamięci kontenera — ostatni znany `maxmem`.
    static func przydzial(_ w: [WierszRRD]) -> Double? { w.last { $0.maxmem != nil }?.maxmem }
}

// MARK: - Stan zbieracza i historia logów hosta

nonisolated enum StanZbieracza: Sendable, Equatable { case brak, staraWersja(Int), dziala }

nonisolated struct BladHistorii: Error, Sendable { var opis: String }

extension HistoriaParsers {
    /// Wersja z serwera wyższa niż nasza też jest „działa” — nowszy mNas na drugim Macu
    /// mógł już zaktualizować zbieracz, a starszy program dalej umie czytać jego pliki.
    static func stan(_ h: HistoriaZbieracza?) -> StanZbieracza {
        guard let h else { return .brak }
        let w = h.wersja ?? 0
        return w >= HistoriaZbieracz.wersja ? .dziala : .staraWersja(w)
    }

    /// Ludzka nazwa mechanizmu: ta sama co na kaflu Przebiegi (z komentarza w cronie),
    /// a gdy kafel jeszcze jej nie zna — z nazwy pliku skryptu.
    static func nazwaMechanizmu(skrypt: String, przebiegiHosta: [Przebieg]) -> String {
        przebiegiHosta.first { $0.id == "host.\(skrypt)" }?.nazwa ?? PrzebiegiParsers.nazwaZeSkryptu(skrypt)
    }

    /// Wyjście `ServerCommands.logiPrzebiegow` → historia wszystkich skryptów hosta.
    static func historiaLogowHosta(_ wyjscie: String, przebiegiHosta: [Przebieg]) -> [WpisHistoriiPrzebiegu] {
        var wynik: [WpisHistoriiPrzebiegu] = []
        var skrypt: String?
        var bufor: [Substring] = []
        // Kafel zna już przebiegi hosta (czujki odsiane) → bierzemy tylko je. Czujka z logiem
        // co 10 minut zasypałaby historię, tak jak Kuma (przegląd gałęzi 2026-10-04, #3).
        let znane = Set(przebiegiHosta.map(\.id))
        func domknij() {
            guard let skrypt else { return }
            if !znane.isEmpty, !znane.contains("host.\(skrypt)") { return }
            wynik += PrzebiegiParsers.historiaLogu(bufor.joined(separator: "\n"),
                                                   mechanizm: nazwaMechanizmu(skrypt: skrypt, przebiegiHosta: przebiegiHosta))
        }
        for linia in wyjscie.split(separator: "\n", omittingEmptySubsequences: false) {
            if linia.hasPrefix("### ") {
                domknij()
                bufor = []
                skrypt = linia.dropFirst(4).split(separator: " ").first.map(String.init)
            } else {
                bufor.append(linia)
            }
        }
        domknij()
        return wynik.sorted { $0.start > $1.start }
    }
}

// MARK: - Pod wykres

extension HistoriaParsers {
    /// Odcinki do narysowania. Linia przerywa się na dziurze — inaczej Charts połączyłby
    /// punkty przez lukę i noc bez danych wyglądałaby jak płaski odczyt. Warstwy (RAM
    /// kontenerów) się nie dzielą: muszą się sumować w każdej minucie, dziura liczy się jako zero.
    static func odcinki(_ s: SeriaHistorii, warstwowy: Bool) -> [[PunktHistorii]] {
        if warstwowy { return s.punkty.contains { $0.wartosc != nil } ? [s.punkty] : [] }
        var wynik: [[PunktHistorii]] = []
        var biezacy: [PunktHistorii] = []
        for p in s.punkty {
            if p.wartosc == nil {
                if !biezacy.isEmpty { wynik.append(biezacy); biezacy = [] }
            } else {
                biezacy.append(p)
            }
        }
        if !biezacy.isEmpty { wynik.append(biezacy) }
        return wynik
    }

    /// Szacunek energii: suma moc × czas, tylko tam, gdzie są dane. Średnia × szerokość
    /// zakresu kłamała, gdy zbieracz chodzi krócej niż zakres albo host stał nocą
    /// (przegląd gałęzi 2026-10-04: 2 dni danych w zakresie „Rok” dawały 44 kWh zamiast 0,24).
    /// Krok próbki = odstęp do następnego punktu (ostatni punkt dziedziczy poprzedni krok).
    /// Tylko procesor (RAPL) — zasilacz serwera testowego nie ma telemetrii.
    static func kWh(_ s: SeriaHistorii) -> Double {
        let p = s.punkty
        guard p.count > 1 else { return 0 }
        var dzule = 0.0
        for i in p.indices {
            guard let w = p[i].wartosc else { continue }
            let krok = i + 1 < p.count ? p[i + 1].czas.timeIntervalSince(p[i].czas)
                                       : p[i].czas.timeIntervalSince(p[i - 1].czas)
            dzule += w * krok
        }
        return dzule / 3_600 / 1_000
    }
}

// MARK: - Dysk z panelu ↔ plik zbieracza

extension HistoriaParsers {
    /// Ten sam filtr znaków co w skrypcie (`tr -cd 'A-Za-z0-9_-'`) — sysfs NVMe dokleja
    /// spacje na końcu serialu, a nazwa pliku ich nie ma.
    static func kluczDysku(_ serial: String?) -> String? {
        let k = (serial ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return k.isEmpty ? nil : k
    }

    /// 🔴 O talerzu nie rozstrzyga typ dysku z Proxmoksa — SSD za mostkiem USB przychodzą
    /// jako `hdd`. Rozstrzyga zbieracz (pole udev z obrotami): ma plik = dysk jest mierzony.
    static func seriaDysku(serial: String?, w h: HistoriaZbieracza) -> SeriaHistorii? {
        kluczDysku(serial).flatMap { h.dyski[$0] }
    }
}
