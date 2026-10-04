import SwiftUI

// Okna historii dla kafli, które nie mają własnego panelu (spec, część 3):
// CPU w czasie, Temperatura rdzeni, Pobór mocy, Przebiegi, Dyski (od 1.2.14).
//
// Wzór wszystkich widoków: zakres na górze, `.task(id: okno)` pobiera przy zmianie
// zakresu i co 60 s (krok RRD), zamknięte okno nie pobiera nic. Widoki nie mają
// własnego przewijania — owija je okno albo panel, w którym stoją.

enum OknoHistorii { static let id = "historia" }

/// Ikona i kolor kafla — **jedno źródło** dla kafla i jego okna historii (od 1.2.14).
///
/// Zgłoszenie [U] 2026-10-04: okna CPU, RAM i Transferów miały nagłówek z ikoną
/// i kolorem swojego kafla, a okna historii nie miały żadnego, a wykres w każdym był
/// domyślnie niebieski. *„Okno ma mieć kolory swojego kafelka, żeby było wiadomo
/// od razu co jest od czego”*. Kafle w `DashboardView` biorą te same wartości, więc
/// zmiana koloru kafla zmienia też okno.
extension DashTileID {
    var ikona: String {
        switch self {
        case .cpuHistory: return "waveform.path.ecg"
        case .coreTemp:   return "thermometer.sun"
        case .power:      return "bolt.fill"
        case .przebiegi:  return "arrow.triangle.2.circlepath"
        case .disks:      return "internaldrive"
        case .miejsce:    return "externaldrive.connected.to.line.below"
        default:          return "chart.xyaxis.line"
        }
    }

    var kolor: Color {
        switch self {
        case .cpuHistory: return .blue
        case .coreTemp:   return .orange
        case .power:      return .yellow
        case .przebiegi:  return .teal
        case .disks:      return .cyan
        case .miejsce:    return .indigo
        default:          return .accentColor
        }
    }
}

struct OknoHistoriiKafla: View {
    var kafel: DashTileID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Ten sam nagłówek co w `PanelScaffold` — okna CPU, RAM i Transferów.
            HStack {
                Label("\(kafel.title) — historia", systemImage: kafel.ikona)
                    .font(.title3.bold())
                    .foregroundStyle(kafel.kolor)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            switch kafel {
            case .przebiegi:
                // Lista ma własne przewijanie.
                HistoriaPrzebiegowWidok().padding(16)
            default:
                ThinScrollView {
                    VStack(alignment: .leading, spacing: 14) { tresc }
                        .padding(16)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 420)
        .background(.background)
        .navigationTitle("\(kafel.title) — historia")
        .scrollIndicators(.never)
        .zapamietajRozmiarOkna("historia.\(kafel.rawValue)")
    }

    @ViewBuilder private var tresc: some View {
        switch kafel {
        case .cpuHistory: HistoriaCPUWidok()
        case .coreTemp:   HistoriaTemperaturWidok()
        case .power:      HistoriaMocyWidok()
        case .disks:      HistoriaTemperaturDyskowWidok()
        case .miejsce:    HistoriaMiejscaWidok()
        default:         Text("Ten kafel nie ma okna historii.").foregroundStyle(.secondary)
        }
    }
}

/// CPU % z RRD Proxmoksa + temperatura całego procesora ze zbieracza.
struct HistoriaCPUWidok: View {
    @Environment(AppModel.self) private var model
    @State private var okno: OknoRRD = .hour
    @State private var cpu: SeriaHistorii?
    @State private var obciazenie: SeriaHistorii?
    @State private var temp: SeriaHistorii?
    @State private var blad: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZakresHistorii(okno: $okno)
            if let blad { BladHistoriiWidok(opis: blad) }
            if let cpu {
                PanelSection(title: "Wykorzystanie CPU") {
                    WykresHistorii(serie: [cpu], kolory: [DashTileID.cpuHistory.kolor])
                    PodsumowanieSerii(seria: cpu)
                }
            }
            if let obciazenie, obciazenie.srednia != nil {
                PanelSection(title: "Obciążenie") {
                    WykresHistorii(serie: [obciazenie], wysokosc: 120, kolory: [DashTileID.cpuHistory.kolor])
                    PodsumowanieSerii(seria: obciazenie)
                }
            }
            if let temp {
                PanelSection(title: "Temperatura procesora") {
                    WykresHistorii(serie: [temp], kolory: [DashTileID.cpuHistory.kolor])
                    PodsumowanieSerii(seria: temp)
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

    private func odswiez() async {
        // SSH nie reaguje na anulowanie — wynik starego zakresu potrafi przyjść po nowym.
        // Zapamiętany zakres odrzuca taki spóźniony wynik (przegląd gałęzi, #2).
        let zakres = okno
        let rrd = await model.historiaWezla(zakres)
        guard !Task.isCancelled, zakres == okno else { return }
        switch rrd {
        case .success(let w): cpu = HistoriaParsers.cpuProcent(w); obciazenie = HistoriaParsers.obciazenie(w); blad = nil
        case .failure(let e): blad = e.opis
        }
        let zb = await model.historiaZbieracza(zakres)
        guard !Task.isCancelled, zakres == okno else { return }
        if case .success(let h?) = zb { temp = h.cpu.first { $0.id == "pakiet" } }
    }
}

/// Temperatury rdzeni i całego procesora ze zbieracza.
struct HistoriaTemperaturWidok: View {
    @Environment(AppModel.self) private var model
    @State private var okno: OknoRRD = .hour
    @State private var serie: [SeriaHistorii] = []
    /// Identyfikatory zaznaczonych serii. Pusty zbiór = wszystkie.
    @State private var wybrane: Set<String> = []

    private var kolory: [Color] { serie.indices.map { PaletaSerii.kolor($0) } }
    private var widoczne: [(SeriaHistorii, Color)] {
        zip(serie, kolory).filter { wybrane.isEmpty || wybrane.contains($0.0.id) }
    }
    @State private var stan: StanZbieracza?
    @State private var blad: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZakresHistorii(okno: $okno)
            if let stan, stan != .dziala { BrakZbieracza(stan: stan) { Task { await odswiez() } } }
            if let blad { BladHistoriiWidok(opis: blad) }
            if !serie.isEmpty {
                // Każdy rdzeń osobnym kolorem + wybór, które widać — zgłoszenie [U]
                // 2026-10-04: „klikam rdzeń 0 i rdzeń 3 i widzę tylko te dwa”.
                // Kolor przypięty do miejsca na pełnej liście, nie na liście widocznych:
                // wyłączenie rdzenia 1 nie przemalowuje rdzenia 2.
                WyborSerii(serie: serie, kolory: kolory, wybrane: $wybrane)
                WykresHistorii(serie: widoczne.map(\.0), wysokosc: 260, kolory: widoczne.map(\.1))
                ForEach(widoczne.map(\.0)) { PodsumowanieSerii(seria: $0) }
                OstatniOdczyt(serie: serie)
            }
        }
        .task(id: okno) {
            while !Task.isCancelled {
                await odswiez()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func odswiez() async {
        let zakres = okno
        let wynik = await model.historiaZbieracza(zakres)
        guard !Task.isCancelled, zakres == okno else { return }
        switch wynik {
        case .success(let h): stan = HistoriaParsers.stan(h); serie = h?.cpu ?? []; blad = nil
        case .failure(let e): blad = e.opis
        }
    }
}

/// Pobór mocy procesora (RAPL) + szacunek energii w zakresie.
struct HistoriaMocyWidok: View {
    @Environment(AppModel.self) private var model
    @State private var okno: OknoRRD = .hour
    @State private var moc: SeriaHistorii?
    @State private var stan: StanZbieracza?
    @State private var blad: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZakresHistorii(okno: $okno)
            if let stan, stan != .dziala { BrakZbieracza(stan: stan) { Task { await odswiez() } } }
            if let blad { BladHistoriiWidok(opis: blad) }
            if let moc {
                WykresHistorii(serie: [moc], wysokosc: 240, kolory: [DashTileID.power.kolor])
                PodsumowanieSerii(seria: moc)
                if moc.srednia != nil {
                    let kwh = HistoriaParsers.kWh(moc)
                    Text("≈ \(kwh.formatted(.number.precision(.fractionLength(2)))) kWh w tym zakresie (sam procesor, RAPL — zasilacz nie ma pomiaru)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                OstatniOdczyt(serie: [moc])
            }
        }
        .task(id: okno) {
            while !Task.isCancelled {
                await odswiez()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func odswiez() async {
        let zakres = okno
        let wynik = await model.historiaZbieracza(zakres)
        guard !Task.isCancelled, zakres == okno else { return }
        switch wynik {
        case .success(let h): stan = HistoriaParsers.stan(h); moc = h?.moc; blad = nil
        case .failure(let e): blad = e.opis
        }
    }
}

/// Temperatury wszystkich dysków ze zbieracza na jednym wykresie (od 1.2.14).
/// Zgłoszenie [U] 2026-10-04: historia temperatur dysków była tylko w panelu jednego
/// dysku, a klik w kafel „Dyski” nic nie otwierał.
struct HistoriaTemperaturDyskowWidok: View {
    @Environment(AppModel.self) private var model
    @State private var okno: OknoRRD = .hour
    @State private var serie: [SeriaHistorii] = []
    @State private var bezHistorii: [String] = []
    @State private var stan: StanZbieracza?
    @State private var blad: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZakresHistorii(okno: $okno)
            if let stan, stan != .dziala { BrakZbieracza(stan: stan) { Task { await odswiez() } } }
            if let blad { BladHistoriiWidok(opis: blad) }
            if !serie.isEmpty {
                WykresHistorii(serie: serie, wysokosc: 260)
                ForEach(serie) { PodsumowanieSerii(seria: $0) }
                OstatniOdczyt(serie: serie)
            }
            UwagaTalerze()
            if stan == .dziala, !bezHistorii.isEmpty {
                Text("Bez historii: \(bezHistorii.joined(separator: ", ")). Dyski talerzowe odczytujemy tylko wtedy, gdy same pracują (np. przy kopii) — zbieracz ich nie budzi; do pierwszej pracy nie mają historii. Niektóre dyski nie podają temperatury.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: okno) {
            while !Task.isCancelled {
                await odswiez()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func odswiez() async {
        let zakres = okno
        let wynik = await model.historiaZbieracza(zakres)
        guard !Task.isCancelled, zakres == okno else { return }
        switch wynik {
        case .success(let h):
            stan = HistoriaParsers.stan(h)
            var zHistoria: [SeriaHistorii] = []
            var bez: [String] = []
            for d in model.disks {
                let nazwa = d.model ?? d.name
                if let h, var s = HistoriaParsers.seriaDysku(serial: d.serial, w: h) {
                    // Każdy plik dysku ma tę samą nazwę źródła w RRD — bez własnego `id`
                    // wykres zlałby serie w jedną.
                    s.id = d.name
                    s.nazwa = nazwa
                    zHistoria.append(s)
                } else {
                    bez.append(nazwa)
                }
            }
            serie = zHistoria
            bezHistorii = bez
            blad = nil
        case .failure(let e):
            blad = e.opis
        }
    }
}

/// Uwaga przy każdej historii dysków: talerze są mierzone tylko w chwilach pracy.
/// Prośba [U] 2026-10-04: *„trzeba dać informację, że historia dysków talerzowych
/// jest pobierana w momencie aktywności dysków, że nie jest na bieżąco”*.
struct UwagaTalerze: View {
    var body: some View {
        Label {
            Text("Dyski talerzowe (np. dysk kopii) mają historię **tylko z chwil, gdy same pracują** — przy kopii albo zapisie. Zbieracz ich nie budzi, więc ich dane **nie są na bieżąco**, a przerwy w linii to czas, gdy dysk spał.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
        }
        .font(.caption)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.indigo.opacity(0.08)))
    }
}

/// Stała paleta dla wielu serii jednej wielkości — rdzenie mają być rozróżnialne
/// na pierwszy rzut oka, więc kolejne kolory leżą daleko od siebie na kole barw.
enum PaletaSerii {
    static let kolory: [Color] = [.red, .orange, .yellow, .green, .mint, .cyan,
                                  .blue, .indigo, .purple, .pink, .brown, .teal]
    static func kolor(_ i: Int) -> Color { kolory[i % kolory.count] }
}

/// Przyciski serii nad wykresem: klik włącza albo wyłącza serię, „Wszystkie” czyści wybór.
struct WyborSerii: View {
    var serie: [SeriaHistorii]
    var kolory: [Color]
    @Binding var wybrane: Set<String>

    var body: some View {
        FlowLayoutSerii {
            Button("Wszystkie") { wybrane = [] }
                .buttonStyle(.bordered)
                .tint(wybrane.isEmpty ? .accentColor : .secondary)
            ForEach(Array(zip(serie, kolory)), id: \.0.id) { s, k in
                let wl = wybrane.contains(s.id)
                Button {
                    if wl { wybrane.remove(s.id) } else { wybrane.insert(s.id) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(k).frame(width: 9, height: 9)
                        Text(s.nazwa)
                    }
                }
                .buttonStyle(.bordered)
                .tint(wl ? k : .secondary)
                .opacity(wybrane.isEmpty || wl ? 1 : 0.55)
            }
        }
        .controlSize(.small)
    }
}

/// Zawijany rząd przycisków — przy sześciu rdzeniach i pakiecie nie mieszczą się w linii.
struct FlowLayoutSerii: Layout {
    var odstep: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let szer = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, wiersz: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let r = v.sizeThatFits(.unspecified)
            if x > 0, x + r.width > szer { x = 0; y += wiersz + odstep; wiersz = 0 }
            x += r.width + odstep; wiersz = max(wiersz, r.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, szer), height: y + wiersz)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, wiersz: CGFloat = 0
        for v in subviews {
            let r = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + r.width > bounds.maxX { x = bounds.minX; y += wiersz + odstep; wiersz = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(r))
            x += r.width + odstep; wiersz = max(wiersz, r.height)
        }
    }
}

/// Ostrzeżenie, gdy zbieracz przestał pisać — po 5 minutach ciszy.
struct OstatniOdczyt: View {
    var serie: [SeriaHistorii]

    var body: some View {
        if let o = serie.compactMap(\.ostatniOdczyt).max(), Date().timeIntervalSince(o) > 300 {
            Text("Ostatni odczyt: \(o.formatted(date: .abbreviated, time: .shortened)) — zbieracz na serwerze stoi?")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

/// Minione przebiegi: kopie z Proxmoksa i wpisy skryptów hosta.
struct HistoriaPrzebiegowWidok: View {
    @Environment(AppModel.self) private var model
    @State private var wpisy: [WpisHistoriiPrzebiegu] = []
    @State private var filtrMechanizmu: String?
    @State private var tylkoBledy = false
    @State private var rozwiniety: String?
    @State private var szczegoly: [String: SzczegolyVzdump] = [:]
    @State private var blad: String?
    @State private var laduje = true

    private var mechanizmy: [String] { Array(Set(wpisy.map(\.mechanizm))).sorted() }
    private var widoczne: [WpisHistoriiPrzebiegu] {
        wpisy.filter { (filtrMechanizmu == nil || $0.mechanizm == filtrMechanizmu) && (!tylkoBledy || $0.stan == .bledny) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Mechanizm", selection: $filtrMechanizmu) {
                    Text("Wszystkie").tag(String?.none)
                    ForEach(mechanizmy, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .frame(maxWidth: 300)
                Toggle("Tylko błędy", isOn: $tylkoBledy)
                Spacer()
                if laduje { ProgressView().controlSize(.small) }
                Text("\(widoczne.count) przebiegów").font(.caption).foregroundStyle(.secondary)
            }
            if let blad { BladHistoriiWidok(opis: blad) }
            List(widoczne) { w in wiersz(w) }
        }
        .task { await odswiez() }
    }

    @ViewBuilder private func wiersz(_ w: WpisHistoriiPrzebiegu) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: ikona(w.stan)).foregroundStyle(kolor(w.stan))
                Text(w.start.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                Text(w.mechanizm).fontWeight(.medium)
                Spacer()
                if let t = w.czasTrwania, t > 0 {
                    Text(Duration.seconds(t).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if rozwiniety == w.id {
                if let o = w.opis {
                    Text(o).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let s = szczegoly[w.id] {
                    if let m = s.magazyn { Text("Magazyn: \(m)").font(.caption) }
                    ForEach(s.goscie, id: \.vmid) { g in
                        Text("CT \(g.vmid) · \(g.czas ?? "—") · \(g.rozmiar ?? String(localized: "przyrostowo"))")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await rozwin(w) } }
    }

    private func ikona(_ s: Przebieg.Stan) -> String {
        switch s {
        case .udany: return "checkmark.circle.fill"
        case .trwa:  return "clock"
        default:     return "xmark.octagon.fill"
        }
    }

    private func kolor(_ s: Przebieg.Stan) -> Color {
        switch s {
        case .udany: return .green
        case .trwa:  return .blue
        default:     return .red
        }
    }

    private func odswiez() async {
        laduje = true
        switch await model.historiaPrzebiegow() {
        case .success(let w): wpisy = w; blad = nil
        case .failure(let e): blad = e.opis
        }
        laduje = false
    }

    private func rozwin(_ w: WpisHistoriiPrzebiegu) async {
        rozwiniety = rozwiniety == w.id ? nil : w.id
        if rozwiniety == w.id, let upid = w.upid, szczegoly[w.id] == nil {
            szczegoly[w.id] = await model.szczegolyPrzebiegu(upid: upid)
        }
    }
}
