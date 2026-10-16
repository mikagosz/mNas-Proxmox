import SwiftUI

// Zakładka „Historia” w panelach, które już istnieją: CPU, RAM, dysk (spec, część 3).

enum ZakladkaPanelu: Hashable { case teraz, historia }

struct PrzelacznikZakladki: View {
    @Binding var zakladka: ZakladkaPanelu

    var body: some View {
        Picker("Widok", selection: $zakladka) {
            Text("Teraz").tag(ZakladkaPanelu.teraz)
            Text("Historia").tag(ZakladkaPanelu.historia)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 240)
    }
}

/// Wykres warstwowy kontenerów + przerywana linia RAM hosta + tabela.
/// Decyzja 2026-10-04: warstwy „do obejrzenia” — może się zmienić po zobaczeniu.
struct HistoriaRAMWidok: View {
    @Environment(AppModel.self) private var model
    @State private var okno: OknoRRD = .hour
    @State private var host: SeriaHistorii?
    @State private var kontenery: [SeriaHistorii] = []
    @State private var przydzialy: [String: Double] = [:]
    @State private var podswietlony: String?
    @State private var blad: String?

    private var naWykresie: [SeriaHistorii] {
        guard let podswietlony else { return kontenery }
        return kontenery.filter { $0.id == podswietlony }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZakresHistorii(okno: $okno)
            if let blad { BladHistoriiWidok(opis: blad) }
            if !kontenery.isEmpty || host != nil {
                WykresHistorii(serie: naWykresie, warstwowy: true, linia: host, wysokosc: 240)
                Text("Warstwy: kontenery · przerywana linia: RAM całego hosta. Kliknij wiersz, żeby zostawić jeden kontener.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Kontener"); Text("średnio"); Text("szczyt"); Text("przydział")
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(kontenery) { s in
                        GridRow {
                            Text(s.nazwa)
                            Text(FormatHistorii.wartosc(s.srednia, .bajty))
                            Text(FormatHistorii.wartosc(s.szczyt, .bajty))
                            Text(FormatHistorii.wartosc(przydzialy[s.id], .bajty))
                        }
                        .font(.caption.monospacedDigit())
                        .background(podswietlony == s.id ? Color.accentColor.opacity(0.15) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { podswietlony = podswietlony == s.id ? nil : s.id }
                    }
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
        let zakres = okno
        let rrd = await model.historiaWezla(zakres)
        let g = await model.historiaRamKontenerow(zakres)
        guard !Task.isCancelled, zakres == okno else { return }
        switch rrd {
        case .success(let w): host = HistoriaParsers.ramHosta(w); blad = nil
        case .failure(let e): blad = e.opis
        }
        kontenery = HistoriaParsers.ramKontenerow(g)
        przydzialy = Dictionary(g.compactMap { x in HistoriaParsers.przydzial(x.wiersze).map { ("ct\(x.vmid)", $0) } },
                                uniquingKeysWith: { a, _ in a })
    }
}

/// Temperatura jednego dysku. Talerzy nie zbieramy — zbieracz nie ma dla nich pliku.
struct HistoriaDyskuWidok: View {
    @Environment(AppModel.self) private var model
    var disk: Disk
    @State private var okno: OknoRRD = .hour
    @State private var seria: SeriaHistorii?
    @State private var stan: StanZbieracza?
    @State private var blad: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZakresHistorii(okno: $okno)
            if let stan, stan != .dziala { BrakZbieracza(stan: stan) { Task { await odswiez() } } }
            if let blad { BladHistoriiWidok(opis: blad) }
            UwagaTalerze()
            if let seria {
                WykresHistorii(serie: [seria])
                PodsumowanieSerii(seria: seria)
                // Bez `OstatniOdczyt`: talerz ma dziury z założenia (śpi), a ostrzeżenie
                // „zbieracz stoi?” po 5 minutach ciszy kłamałoby przy każdym śnie.
            } else if stan == .dziala {
                Text("Dla tego dysku nie ma historii temperatury. Albo to dysk talerzowy, który od instalacji zbieracza jeszcze nie pracował — odczytujemy go tylko wtedy, gdy sam pracuje, żeby go nie budzić — albo dysk nie podaje temperatury.")
                    .font(.callout).foregroundStyle(.secondary)
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
            seria = h.flatMap { HistoriaParsers.seriaDysku(serial: disk.serial, w: $0) }
                .map { var s = $0; s.nazwa = disk.model ?? disk.name; return s }
            blad = nil
        case .failure(let e):
            blad = e.opis
        }
    }
}
