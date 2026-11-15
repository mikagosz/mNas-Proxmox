import SwiftUI

// Okno „Maszyny i kontenery” — od 1.2.49. Zgłoszenie 2026-11-14: kliknięcie w kafel
// ma otworzyć okno ze wszystkimi postawionymi gośćmi, z którego da się je włączać,
// wyłączać i restartować. Do tej pory start/stop był tylko w menu kontekstowym wiersza
// w kaflu, a restartu nie było wcale.
//
// Każda akcja idzie przez potwierdzenie — to zmiana stanu serwera, nie podgląd.

/// Wszyscy goście węzła — stan, zużycie, start / zatrzymanie / restart.
struct OknoGosci: View {
    @Environment(AppModel.self) private var model
    @State private var szukaj = ""
    @State private var akcja: (gosc: Guest, akcja: Guest.Akcja)?
    /// Goście, którym właśnie zmieniamy start z serwerem — przełącznik czeka na serwer.
    @State private var zmieniaStart: Set<Int> = []
    /// Błąd ostatniej akcji — w tym oknie, bo okno główne może być zamknięte (wzór: `OknoUslug`).
    @State private var bladAkcji: String?

    private var widoczne: [Guest] {
        model.guests
            .filter {
                szukaj.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(szukaj)
                    || String($0.vmid).contains(szukaj)
            }
            .sorted { $0.vmid < $1.vmid }
    }

    var body: some View {
        let dziala = model.guests.filter(\.running).count
        VStack(spacing: 0) {
            NaglowekOkna(tytul: "Maszyny i kontenery", ikona: "square.stack.3d.up", kolor: .indigo)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Szukaj po nazwie albo numerze", text: $szukaj)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Spacer()
                    Text("działa \(dziala) z \(model.guests.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.startZSerwerem.isEmpty {
                        Label("z serwerem startuje \(model.startZSerwerem.values.filter { $0 }.count)",
                              systemImage: "bolt.fill")
                            .font(.caption).foregroundStyle(.yellow)
                    }
                }
                if model.guests.isEmpty {
                    Text("Serwer nie zgłasza żadnej maszyny ani kontenera.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Zamiast `List`: tam separator kończy się przy treści i wiersze się zlewały
                    // (2026-11-14). Tu linia idzie przez całą szerokość, a co drugi wiersz ma tło.
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(widoczne.enumerated()), id: \.element.id) { i, g in
                                PodswietlanyWiersz(parzysty: i.isMultiple(of: 2)) { wiersz(g) }
                                Divider()
                            }
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let bladAkcji {
                    Label(bladAkcji, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Text("Zatrzymaj i Restart zamykają system gościa łagodnie — mNas nie odcina zasilania. „Start z serwerem” decyduje, czy gość wstanie sam po restarcie serwera; jego stanu teraz nie zmienia.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 440)
        .background(.background)
        .navigationTitle("Maszyny i kontenery")
        .zapamietajRozmiarOkna("goscie")
        .alert("Potwierdź", isPresented: Binding(get: { akcja != nil }, set: { if !$0 { akcja = nil } })) {
            if let a = akcja {
                Button(a.akcja.przycisk, role: a.akcja == .start ? nil : .destructive) {
                    wykonaj(a.gosc, a.akcja)
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            if let a = akcja { Text(OknoGosci.pytanie(a.gosc, a.akcja)) }
        }
    }

    /// Treść potwierdzenia — wspólna z kaflem na dashboardzie.
    static func pytanie(_ g: Guest, _ a: Guest.Akcja) -> String {
        let co = "\(g.kind.label.lowercased()) \(g.vmid) (\(g.name))"
        switch a {
        case .start:
            return String(localized: "Uruchomić \(co)?")
        case .shutdown:
            return String(localized: "Zatrzymać \(co)? mNas wysyła `shutdown`, czyli łagodne zamknięcie systemu gościa — nie odcina zasilania.")
        case .reboot:
            return String(localized: "Zrestartować \(co)? System gościa zamknie się i wstanie od nowa; to, co w nim chodzi, na chwilę zniknie.")
        }
    }

    private func wykonaj(_ g: Guest, _ a: Guest.Akcja) {
        Task { bladAkcji = await model.guestAction(g, a) }
    }

    private func wiersz(_ g: Guest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: g.kind.symbol)
                .foregroundStyle(g.running ? .green : .secondary)
                .frame(width: 18)
            NumerGoscia(vmid: g.vmid, dziala: g.running)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.name).fontWeight(.medium).lineLimit(1)
                Text(g.kind.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if g.running {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 8) {
                        if let cpu = g.cpuPercent {
                            Text("CPU \(String(format: "%.1f", cpu))%")
                        }
                        if let mem = g.memoryPercent {
                            Text("RAM \(Int(mem.rounded()))%")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    Text("od \(Format.uptime(g.uptimeSeconds))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("zgaszona").font(.caption).foregroundStyle(.secondary)
            }
            startZSerwerem(g)
                .frame(width: 150, alignment: .leading)
            przyciski(g)
                .frame(width: 210, alignment: .trailing)
        }
    }

    /// Przełącznik „Start z serwerem” (`onboot`). Szary i nieaktywny, dopóki mNas nie odczyta stanu.
    @ViewBuilder private func startZSerwerem(_ g: Guest) -> some View {
        let wlaczony = model.startZSerwerem[g.vmid]
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { wlaczony ?? false },
                set: { nowy in
                    zmieniaStart.insert(g.vmid)
                    Task {
                        bladAkcji = await model.ustawStartZSerwerem(g, nowy)
                        zmieniaStart.remove(g.vmid)
                    }
                }
            )) {
                Label("Start z serwerem", systemImage: "bolt.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(wlaczony == true ? .yellow : .secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(wlaczony == nil || zmieniaStart.contains(g.vmid))
            if zmieniaStart.contains(g.vmid) {
                ProgressView().controlSize(.mini)
            } else {
                Text(wlaczony == nil ? String(localized: "sprawdzam…")
                     : wlaczony! ? String(localized: "startuje sam") : String(localized: "nie startuje sam"))
                    .font(.caption)
                    .foregroundStyle(wlaczony == true ? Color.primary : Color.secondary)
            }
        }
        .help("Czy gość wstanie sam po restarcie serwera (ustawienie „onboot” w Proxmoksie).")
    }

    @ViewBuilder private func przyciski(_ g: Guest) -> some View {
        if let trwa = model.akcjeGosci[g.vmid] {
            StanAkcjiGoscia(trwa: trwa)
        } else {
            HStack(spacing: 6) {
                if g.running {
                    przycisk(g, .shutdown)
                    przycisk(g, .reboot)
                } else {
                    przycisk(g, .start)
                }
            }
        }
    }

    private func przycisk(_ g: Guest, _ a: Guest.Akcja) -> some View {
        Button { akcja = (g, a) } label: {
            Label(a.przycisk, systemImage: a.ikona)
        }
        .controlSize(.small)
        .help(OknoGosci.pytanie(g, a))
    }
}

/// Numer gościa (VMID) jako plakietka — wyraźny kolor, cyfry o stałej szerokości.
/// 2026-11-14: szary numer pod nazwą ginął w wierszu. Zgaszony gość ma plakietkę szarą,
/// tak jak ikonkę — kolor mówi to samo co ikonka obok.
struct NumerGoscia: View {
    var vmid: Int
    var dziala = true
    var maly = false

    var body: some View {
        Text(verbatim: String(vmid))
            .font((maly ? Font.caption2 : Font.callout).monospacedDigit().weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, maly ? 5 : 7)
            .padding(.vertical, maly ? 1 : 2)
            .background(dziala ? Color.indigo : Color.secondary.opacity(0.55), in: Capsule())
            .accessibilityLabel(Text("numer \(vmid)"))
    }
}

/// Co się dzieje z gościem po kliknięciu: „Zamykanie… 12 s”, potem „Zamknięty po 14 s”.
struct StanAkcjiGoscia: View {
    var trwa: AppModel.TrwajacaAkcjaGoscia
    var maly = false

    var body: some View {
        if let wynik = trwa.wynik {
            Label(wynik, systemImage: trwa.blad ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .font(maly ? .caption2 : .caption.weight(.medium))
                .foregroundStyle(trwa.blad ? .red : .green)
        } else {
            TimelineView(.periodic(from: trwa.od, by: 1)) { kontekst in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(maly ? 0.6 : 1)
                    Text("\(trwa.akcja.wToku) \(Int(kontekst.date.timeIntervalSince(trwa.od))) s")
                        .font((maly ? Font.caption2 : Font.caption).monospacedDigit().weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Wiersz listy z tłem co drugi raz i podświetleniem pod kursorem (2026-11-14).
private struct PodswietlanyWiersz<Tresc: View>: View {
    var parzysty: Bool
    @ViewBuilder var tresc: Tresc
    @State private var podKursorem = false

    var body: some View {
        tresc
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(tlo)
            .contentShape(Rectangle())
            .onHover { podKursorem = $0 }
            .animation(.easeOut(duration: 0.12), value: podKursorem)
    }

    private var tlo: Color {
        if podKursorem { return Color.accentColor.opacity(0.14) }
        return parzysty ? .clear : Color.primary.opacity(0.04)
    }
}
