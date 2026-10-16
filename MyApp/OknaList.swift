import SwiftUI

// Okna z pełną listą dla kafli, które pokazują tylko początek: Zdarzenia i Usługi
// (od 1.2.16). Zgłoszenie 2026-10-04: Przebiegi mają „swoje okno duże, fajne,
// gdzie można szukać i sprawdzać”, a Zdarzenia nie mają żadnego; w średnim kaflu
// Usług widać pierwsze kilka, a „+18 więcej” nie dawało się otworzyć.

/// Pełny rejestr zdarzeń z wyszukiwaniem i filtrem.
struct OknoZdarzen: View {
    @Environment(AppModel.self) private var model
    @State private var szukaj = ""
    @State private var tylkoAlarmy = false
    @State private var zrodlo: Przebieg.Zrodlo?
    @State private var potwierdzCzyszczenie = false

    private var widoczne: [Zdarzenie] {
        model.rejestr.zdarzenia.filter { z in
            (!tylkoAlarmy || z.stan.alarmujacy)
                && (zrodlo == nil || z.zrodlo == zrodlo)
                && (szukaj.isEmpty
                    || z.nazwa.localizedCaseInsensitiveContains(szukaj)
                    || (z.opis ?? "").localizedCaseInsensitiveContains(szukaj))
        }
    }

    private var zrodla: [Przebieg.Zrodlo] {
        var w: [Przebieg.Zrodlo] = []
        for z in model.rejestr.zdarzenia where !w.contains(z.zrodlo) { w.append(z.zrodlo) }
        return w
    }

    var body: some View {
        VStack(spacing: 0) {
            NaglowekOkna(tytul: "Zdarzenia", ikona: "list.bullet.rectangle", kolor: .purple)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Szukaj w nazwie i opisie", text: $szukaj)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Picker("Źródło", selection: $zrodlo) {
                        Text("Wszystkie").tag(Przebieg.Zrodlo?.none)
                        ForEach(zrodla, id: \.self) { Text($0.opis).tag(Przebieg.Zrodlo?.some($0)) }
                    }
                    .frame(maxWidth: 220)
                    Toggle("Tylko błędy i cisza", isOn: $tylkoAlarmy)
                    Spacer()
                    Text("\(widoczne.count) z \(model.rejestr.zdarzenia.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if widoczne.isEmpty {
                    Text(model.rejestr.zdarzenia.isEmpty
                         ? "Rejestr jest pusty — kolejne zdarzenie dopisze się samo."
                         : "Nic nie pasuje do filtra.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(widoczne) { wiersz($0) }
                }
                HStack {
                    Spacer()
                    // Ten sam przycisk co w dużym kaflu — rejestr czyści się tylko ręcznie.
                    Button("Wyczyść rejestr…") { potwierdzCzyszczenie = true }
                        .disabled(model.rejestr.zdarzenia.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 440)
        .background(.background)
        .navigationTitle("Zdarzenia")
        .zapamietajRozmiarOkna("zdarzenia")
        .confirmationDialog("Wyczyścić cały rejestr zdarzeń?", isPresented: $potwierdzCzyszczenie) {
            Button("Wyczyść", role: .destructive) { model.rejestr.wyczysc() }
        }
    }

    private func wiersz(_ z: Zdarzenie) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(KolorStanu.kolor(z.stan)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(z.nazwa).fontWeight(.medium)
                    Text(z.jednymZdaniem).foregroundStyle(KolorStanu.kolor(z.stan))
                }
                if let o = z.opis {
                    Text(o).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(z.czas.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                Text(z.zrodlo.opis).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Wszystkie usługi węzła — stan, start z systemem, panel usługi po kliknięciu.
struct OknoUslug: View {
    @Environment(AppModel.self) private var model
    @State private var szukaj = ""
    @State private var wybrana: Service?
    @State private var akcja: (usluga: Service, start: Bool)?
    /// Błąd ostatniej akcji — w tym oknie, nie tylko w banerze okna głównego, które może
    /// być zamknięte (audyt SBW 2026-10-04, S-P3-01). Wzór: panel usługi w `Panels.swift`.
    @State private var bladAkcji: String?

    private var widoczne: [Service] {
        model.services.filter {
            szukaj.isEmpty
                || $0.service.localizedCaseInsensitiveContains(szukaj)
                || NazwyUslug.nazwa($0.service).localizedCaseInsensitiveContains(szukaj)
        }
    }

    var body: some View {
        let dziala = model.services.filter { $0.state?.uppercased() == "RUNNING" }.count
        VStack(spacing: 0) {
            NaglowekOkna(tytul: "Usługi", ikona: "gearshape.2", kolor: .indigo)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Szukaj usługi", text: $szukaj)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Spacer()
                    Text("działa \(dziala) z \(model.services.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                List(widoczne) { s in wiersz(s) }
                if let bladAkcji {
                    Label(bladAkcji, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("Kliknij usługę, żeby otworzyć jej panel. Prawy klik: uruchom albo zatrzymaj.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(.background)
        .navigationTitle("Usługi")
        .zapamietajRozmiarOkna("uslugi")
        .sheet(item: $wybrana) { ServicePanel(service: $0, displayName: NazwyUslug.nazwa($0.service)) }
        .alert("Potwierdź", isPresented: Binding(get: { akcja != nil }, set: { if !$0 { akcja = nil } })) {
            if let a = akcja {
                Button(a.start ? "Uruchom" : "Zatrzymaj", role: a.start ? nil : .destructive) {
                    Task { bladAkcji = await model.setService(a.usluga.service, running: a.start) }
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            if let a = akcja {
                Text("\(a.start ? String(localized: "Uruchomić") : String(localized: "Zatrzymać")) usługę \(NazwyUslug.nazwa(a.usluga.service))?")
            }
        }
    }

    private func wiersz(_ s: Service) -> some View {
        let dziala = s.state?.uppercased() == "RUNNING"
        return HStack(spacing: 8) {
            Circle().fill(dziala ? Color.green : Color.secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(NazwyUslug.nazwa(s.service))
                if NazwyUslug.nazwa(s.service) != s.service {
                    Text(s.service).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if s.enable == true {
                Label("startuje z systemem", systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(.yellow)
            }
            Text(dziala ? String(localized: "działa") : (s.state?.lowercased() ?? "—"))
                .font(.caption).foregroundStyle(dziala ? .green : .secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { wybrana = s }
        .contextMenu {
            if dziala {
                Button("Zatrzymaj", role: .destructive) { akcja = (s, false) }
            } else {
                Button("Uruchom") { akcja = (s, true) }
            }
        }
    }
}

/// Nagłówek okna — ten sam wygląd co w `PanelScaffold`, bez przewijania pod spodem.
struct NaglowekOkna: View {
    var tytul: LocalizedStringKey
    var ikona: String
    var kolor: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Label(tytul, systemImage: ikona).font(.title3.bold()).foregroundStyle(kolor)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

/// Kolor stanu zdarzenia — ten sam, co kropka w kaflu Zdarzenia.
enum KolorStanu {
    static func kolor(_ stan: Przebieg.Stan) -> Color {
        switch stan {
        case .trwa:     return .teal
        case .udany:    return .green
        case .bledny:   return .red
        case .cisza:    return .orange
        case .nieznany: return .secondary
        }
    }
}
