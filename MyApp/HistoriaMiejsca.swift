import SwiftUI

// Historia miejsca na dyskach (od 1.2.16) — okno z kafla „Miejsce”.
//
// Zgłoszenie 2026-10-04: *„brakuje mi historii zapełniania miejsca i czyszczenia
// miejsca, ilości danych, które wchodziły na dyski”*. Trzy źródła:
// 1. zbieracz `mnas-historia` od wersji 2 — zajętość udziałów i systemów plików na NVMe/SSD
//    (`miejsce-*.rrd`) oraz bajty odczytane i zapisane na każdy dysk (`io-*.rrd`);
// 2. RRD magazynów Proxmoksa — rok wstecz, także dysk kopii na talerzu, bo Proxmox
//    i tak sprawdza go co 10 s.
// Talerze zbieracz czyta tylko, gdy same pracują (licznik jądra drgnął) — decyzja 2026-10-04.

/// Jedno miejsce na wykresie zajętości: seria „zajęte” + bilans w zakresie.
private struct PozycjaMiejsca: Identifiable {
    var id: String
    var nazwa: String
    var zajete: SeriaHistorii
    var calosc: Double?

    private var wartosci: [Double] { zajete.punkty.compactMap(\.wartosc) }
    var teraz: Double? { wartosci.last }
    var zmiana: Double? { guard let a = wartosci.first, let b = wartosci.last else { return nil }; return b - a }

    /// Suma wzrostów i suma spadków między kolejnymi próbkami. Przy długich zakresach
    /// próbki są średnimi z kilku godzin, więc drobne wahania się wygładzają.
    var przybylo: Double { zip(wartosci, wartosci.dropFirst()).map { max(0, $1 - $0) }.reduce(0, +) }
    var zwolniono: Double { zip(wartosci, wartosci.dropFirst()).map { max(0, $0 - $1) }.reduce(0, +) }
}

/// Jeden dysk w tabeli zapisów: suma bajtów w zakresie z prędkości × krok próbki.
private struct PozycjaZapisow: Identifiable {
    var id: String
    var nazwa: String
    var zapis: SeriaHistorii?
    var odczyt: SeriaHistorii?

    static func suma(_ s: SeriaHistorii?) -> Double? {
        guard let p = s?.punkty, p.count > 1 else { return nil }
        let krok = p[1].czas.timeIntervalSince(p[0].czas)
        return p.compactMap(\.wartosc).reduce(0, +) * krok
    }
}

struct HistoriaMiejscaWidok: View {
    @Environment(AppModel.self) private var model
    @State private var okno: OknoRRD = .day
    @State private var udzialy: [PozycjaMiejsca] = []
    @State private var magazyny: [PozycjaMiejsca] = []
    @State private var zapisy: [PozycjaZapisow] = []
    @State private var wybraneUdzialy: Set<String> = []
    @State private var wybraneMagazyny: Set<String> = []
    @State private var wybraneZapisy: Set<String> = []
    @State private var stan: StanZbieracza?
    @State private var blad: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZakresHistorii(okno: $okno)
            if let stan, stan != .dziala { BrakZbieracza(stan: stan) { Task { await odswiez() } } }
            if let blad { BladHistoriiWidok(opis: blad) }
            UwagaTalerze()

            if !udzialy.isEmpty {
                PanelSection(title: "Udziały i dyski serwera — zajętość") {
                    sekcjaMiejsca(udzialy, wybrane: $wybraneUdzialy)
                    Text("Zbieracz na serwerze, co minutę. Dyski talerzowe tylko wtedy, gdy same pracują — przerwy w linii to sen dysku.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !magazyny.isEmpty {
                PanelSection(title: "Magazyny Proxmoksa — zajętość") {
                    sekcjaMiejsca(magazyny, wybrane: $wybraneMagazyny)
                    Text("Historia z Proxmoksa — do roku wstecz, także dysk kopii.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !zapisy.isEmpty {
                PanelSection(title: "Zapisy i odczyty na dyskach") {
                    sekcjaZapisow
                }
            }
        }
        .task(id: okno) {
            while !Task.isCancelled {
                await odswiez()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: Zajętość

    @ViewBuilder private func sekcjaMiejsca(_ lista: [PozycjaMiejsca], wybrane: Binding<Set<String>>) -> some View {
        let kolory = lista.indices.map { PaletaSerii.kolor($0) }
        let serie = lista.map { var s = $0.zajete; s.id = $0.id; s.nazwa = $0.nazwa; return s }
        let widoczne = zip(serie, kolory).filter { wybrane.wrappedValue.isEmpty || wybrane.wrappedValue.contains($0.0.id) }
        WyborSerii(serie: serie, kolory: kolory, wybrane: wybrane)
        WykresHistorii(serie: widoczne.map(\.0), wysokosc: 220, kolory: widoczne.map(\.1))
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Miejsce"); Text("teraz"); Text("zmiana"); Text("przybyło"); Text("zwolniono")
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(zip(lista, kolory)), id: \.0.id) { p, k in
                GridRow {
                    HStack(spacing: 5) { Circle().fill(k).frame(width: 8, height: 8); Text(p.nazwa) }
                    Text(teraz(p))
                    Text(zmiana(p.zmiana)).foregroundStyle((p.zmiana ?? 0) > 0 ? .orange : ((p.zmiana ?? 0) < 0 ? .green : .secondary))
                    Text("+" + Format.bytes(Int64(p.przybylo)))
                    Text("−" + Format.bytes(Int64(p.zwolniono)))
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    private func teraz(_ p: PozycjaMiejsca) -> String {
        guard let t = p.teraz else { return "—" }
        guard let c = p.calosc, c > 0 else { return Format.bytes(Int64(t)) }
        return String(localized: "\(Format.bytes(Int64(t))) z \(Format.bytes(Int64(c))) (\(Int((t / c * 100).rounded(.up)))%)")
    }

    private func zmiana(_ z: Double?) -> String {
        guard let z else { return "—" }
        if abs(z) < 1 { return String(localized: "bez zmian") }
        return (z > 0 ? "+" : "−") + Format.bytes(Int64(abs(z)))
    }

    // MARK: Zapisy

    @ViewBuilder private var sekcjaZapisow: some View {
        let kolory = zapisy.indices.map { PaletaSerii.kolor($0) }
        let serie: [SeriaHistorii] = zapisy.compactMap { p in
            p.zapis.map { var s = $0; s.id = p.id; s.nazwa = p.nazwa; return s }
        }
        let widoczne = zip(serie, kolory).filter { wybraneZapisy.isEmpty || wybraneZapisy.contains($0.0.id) }
        WyborSerii(serie: serie, kolory: kolory, wybrane: $wybraneZapisy)
        Text("Prędkość zapisu").font(.caption).foregroundStyle(.secondary)
        WykresHistorii(serie: widoczne.map(\.0), wysokosc: 180, kolory: widoczne.map(\.1))
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow { Text("Dysk"); Text("zapisano"); Text("odczytano") }
                .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(zip(zapisy, kolory)), id: \.0.id) { p, k in
                GridRow {
                    HStack(spacing: 5) { Circle().fill(k).frame(width: 8, height: 8); Text(p.nazwa) }
                    Text(PozycjaZapisow.suma(p.zapis).map { Format.bytes(Int64($0)) } ?? "—")
                    Text(PozycjaZapisow.suma(p.odczyt).map { Format.bytes(Int64($0)) } ?? "—")
                }
                .font(.caption.monospacedDigit())
            }
        }
        Text("Suma w wybranym zakresie, z liczników jądra. Historia od instalacji zbieracza w wersji 2.")
            .font(.caption2).foregroundStyle(.tertiary)
    }

    // MARK: Pobieranie

    private func odswiez() async {
        let zakres = okno
        let zb = await model.historiaZbieracza(zakres)
        let mg = await model.historiaMagazynow(zakres)
        guard !Task.isCancelled, zakres == okno else { return }
        blad = nil

        switch zb {
        case .success(let h):
            stan = HistoriaParsers.stan(h)
            udzialy = (h?.miejsce ?? [:]).compactMap { sciezka, serie in
                guard let z = serie.first(where: { $0.id == "zajete" }) else { return nil }
                let c = serie.first { $0.id == "calosc" }?.punkty.compactMap(\.wartosc).last
                return PozycjaMiejsca(id: sciezka, nazwa: nazwaMiejsca(sciezka), zajete: z, calosc: c)
            }
            .sorted { $0.nazwa < $1.nazwa }
            zapisy = (h?.io ?? [:]).map { serial, serie in
                PozycjaZapisow(id: serial, nazwa: nazwaDysku(serial),
                               zapis: serie.first { $0.id == "zapis" },
                               odczyt: serie.first { $0.id == "odczyt" })
            }
            .sorted { $0.nazwa < $1.nazwa }
        case .failure(let e):
            blad = e.opis
        }

        switch mg {
        case .success(let lista):
            magazyny = lista.map { m in
                let punkty = m.wiersze.map {
                    PunktHistorii(czas: Date(timeIntervalSince1970: TimeInterval($0.time)), wartosc: $0.used)
                }
                return PozycjaMiejsca(id: "pve.\(m.id)", nazwa: m.id,
                                      zajete: SeriaHistorii(id: "pve.\(m.id)", nazwa: m.id, jednostka: .bajty, punkty: punkty),
                                      calosc: m.wiersze.compactMap(\.total).last)
            }
        case .failure(let e):
            if blad == nil { blad = e.opis }
        }
    }

    /// Nazwa ludzka: udział Samby albo magazyn z kafla Miejsce, `/` = system.
    private func nazwaMiejsca(_ sciezka: String) -> String {
        if let u = model.udzialy.first(where: { $0.sciezka == sciezka }) { return u.nazwa }
        return sciezka == "/" ? "System (/)" : sciezka
    }

    private func nazwaDysku(_ serial: String) -> String {
        model.disks.first { HistoriaParsers.kluczDysku($0.serial) == serial }.map { $0.model ?? $0.name } ?? serial
    }
}
