import SwiftUI

/// Okno historii transferów — „co się działo wtedy”.
///
/// Kafel „Transfery” odpowiada na *ile płynie teraz* i pokazuje ostatnią godzinę;
/// to okno sięga dalej — do doby, tygodnia, miesiąca i roku wstecz. Jedno i drugie
/// czyta **to samo** źródło (`AppModel.zbierzStrumienie`), więc nie ma jak się rozjechać.
///
/// > [!info] Skąd bierze się głębia
/// > RRD Proxmoksa trzyma pięć okien i wszystkie zmierzone 2026-08-29:
/// > godzina (60 próbek co minutę), doba (1440 co minutę), tydzień (336 co pół godziny),
/// > miesiąc (1440 co pół godziny), rok (1440 co sześć godzin). Poprzednie źródło —
/// > licznik ruchu na hoście — trzymało siedem dni i zostało skasowane.
///
/// > [!danger] 🔴 Na „która maszyna w domu ciągnie" to okno nie odpowiada
/// > Odpowiadał na to zbieracz `conntrack` (Etap 2 planu), skasowany razem z licznikiem
/// > 2026-08-29. RRD zna ruch **kontenera**, nie zna adresu klienta. Widok mówi to
/// > wprost w sekcji „Jak to czytać”, zamiast pokazywać połowę prawdy jako całość.
struct PanelTransferow: View {
    @Environment(AppModel.self) private var model

    @State private var okno: OknoRRD = .hour
    @State private var strumienie: [Strumien] = []
    @State private var laduje = false
    @State private var blad: String?

    private var lacze: Strumien? {
        strumienie.first { if case .lacze = $0.rodzaj { return true }; return false }
    }
    private var aktywne: [Strumien] { TransferyParsers.aktywne(strumienie) }

    var body: some View {
        PanelScaffold(title: "Transfery — historia", systemImage: "chart.xyaxis.line", tint: .mint) {
            Picker("Okno", selection: $okno) {
                ForEach(OknoRRD.allCases) { o in Text(o.etykieta).tag(o) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(laduje)

            if laduje {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Czytam RRD z Proxmoksa…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let blad {
                Label(blad, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lacze, !lacze.punkty.isEmpty {
                PanelSection(title: "Całe łącze") {
                    // Łącze rysujemy osobno i pierwsze, bo to jest mianownik wszystkiego
                    // niżej: Proxmox sumuje do niego wyłącznie karty fizyczne.
                    wykres(lacze, skala: lacze.szczytNaSekunde)
                    HStack(spacing: 12) {
                        Text("szczyt \(Format.predkosc(lacze.szczytNaSekunde))")
                        Text("średnio \(Format.predkosc(lacze.sredniaNaSekunde))")
                        Text("razem \(Format.bytes(lacze.razemBajtow))")
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            if !aktywne.isEmpty {
                PanelSection(title: "Równoległe strumienie") {
                    // O to w całym tym widoku chodzi: zobaczyć, czy dwa mechanizmy
                    // chodziły **jednocześnie** i jak dzieliły łącze. Dlatego wykresy
                    // stoją jeden pod drugim, na wspólnej osi czasu i wspólnej skali.
                    let skala = TransferyParsers.wspolnaSkala(aktywne)
                    ForEach(aktywne) { s in wykres(s, skala: skala) }
                }
            }

            if !strumienie.isEmpty {
                PanelSection(title: "Sumy w oknie") {
                    ForEach(strumienie) { s in wierszSumy(s) }
                }
            }

            if !laduje && strumienie.allSatisfy(\.punkty.isEmpty) && blad == nil {
                Text("RRD nie ma pomiarów w tym oknie — serwer mógł jeszcze wtedy nie zbierać danych.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PanelSection(title: "Jak to czytać") {
                wskazowka("Strzałki są z punktu widzenia tego, co stoi w nazwie — „w górę” znaczy, że dane wyszły z niego.")
                wskazowka("„\(lacze?.kto ?? String(localized: "Węzeł"))” to całe łącze: Proxmox liczy tam wyłącznie karty fizyczne, więc mostki i kontenery nie wchodzą do tej sumy dwa razy.")
                wskazowka("Rozdzielczość w tym oknie to \(okno.opisRozdzielczosci) — krótkie szarpnięcie rozmyje się w średniej kubełka.")
                wskazowka("Który kontener przesyłał — widać. Która maszyna w domu się z nim łączyła — nie: RRD nie zna adresu klienta.")
            }
        }
        .task(id: okno) { await wczytaj() }
    }

    @ViewBuilder private func wykres(_ s: Strumien, skala: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(s.kto).font(.caption.weight(.semibold))
                Text(s.rodzaj.opis).font(.caption2).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text("szczyt \(Format.predkosc(s.szczytNaSekunde))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Sparkline(points: s.punkty.map(\.razemNaSekunde), tint: .mint, upperBound: skala)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
        }
    }

    private func wierszSumy(_ s: Strumien) -> some View {
        HStack(spacing: 8) {
            Text(s.kto).font(.caption.weight(.medium)).frame(width: 130, alignment: .leading)
                .lineLimit(1)
            Label(Format.bytes(s.odNiegoBajtow), systemImage: "arrow.up")
                .font(.caption2.monospacedDigit()).frame(width: 100, alignment: .leading)
            Label(Format.bytes(s.doNiegoBajtow), systemImage: "arrow.down")
                .font(.caption2.monospacedDigit()).frame(width: 100, alignment: .leading)
            if let u = TransferyParsers.udzial(s, wLaczu: lacze), !czyLacze(s) {
                Text(String(localized: "\(Int((u * 100).rounded()))% łącza"))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func czyLacze(_ s: Strumien) -> Bool {
        if case .lacze = s.rodzaj { return true }
        return false
    }

    private func wskazowka(_ tekst: LocalizedStringKey) -> some View {
        Label(tekst, systemImage: "info.circle")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Wczytywanie

    private func wczytaj() async {
        laduje = true
        blad = nil
        defer { laduje = false }

        switch await model.zbierzStrumienie(okno: okno) {
        case .success(let nowe):
            strumienie = nowe
        case .failure(let powod):
            strumienie = []
            blad = powod.opis
        }
    }
}
