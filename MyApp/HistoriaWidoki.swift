import SwiftUI
import Charts

// Wspólne klocki okien i zakładek historii (spec: Historia-wykresy-projekt-2026-10-04, część 3).

enum FormatHistorii {
    static func wartosc(_ v: Double?, _ j: JednostkaHistorii) -> String {
        guard let v else { return "—" }
        switch j {
        case .stopnie: return String(localized: "\(Int(v.rounded())) °C")
        case .waty:    return v.formatted(.number.precision(.fractionLength(1))) + " W"
        case .procent: return String(localized: "\(Int(v.rounded()))%")
        case .bajty:   return Format.bytes(Int64(v))
        case .liczba:  return v.formatted(.number.precision(.fractionLength(2)))
        // Prędkości w MB/s, nie w megabitach — megabity brzmią nierealnie.
        case .przeplyw: return Format.bytes(Int64(v)) + "/s"
        }
    }
}

/// Przełącznik zakresu — te same etykiety co w oknie Transferów.
struct ZakresHistorii: View {
    @Binding var okno: OknoRRD

    var body: some View {
        Picker("Zakres", selection: $okno) {
            ForEach(OknoRRD.allCases) { o in Text(o.etykieta).tag(o) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Jeden wykres na każdą historię. Dziura w danych przerywa linię (`HistoriaParsers.odcinki`);
/// po najechaniu kreska z godziną i wartościami wszystkich serii w tym punkcie.
struct WykresHistorii: View {
    var serie: [SeriaHistorii]
    var warstwowy = false
    /// Druga warstwa informacji nad wykresem warstwowym — np. RAM całego hosta.
    var linia: SeriaHistorii? = nil
    var wysokosc: CGFloat = 180
    /// Kolory serii w kolejności `serie` — kolor kafla, z którego otwarto okno (od 1.2.14).
    /// `nil` = domyślna paleta systemu (dyski, RAM: każda seria ma mieć inny kolor).
    /// Krótsza lista niż serii — ostatni kolor powtarza się dla reszty.
    var kolory: [Color]? = nil
    @State private var wybrany: Date?

    var body: some View {
        Chart {
            ForEach(serie) { s in
                ForEach(Array(HistoriaParsers.odcinki(s, warstwowy: warstwowy).enumerated()), id: \.offset) { i, odc in
                    ForEach(odc, id: \.czas) { p in
                        if warstwowy {
                            AreaMark(x: .value("Czas", p.czas),
                                     y: .value("Wartość", p.wartosc ?? 0),
                                     stacking: .standard)
                                .foregroundStyle(by: .value("Seria", s.nazwa))
                        } else {
                            LineMark(x: .value("Czas", p.czas),
                                     y: .value("Wartość", p.naWykresie ?? 0),
                                     series: .value("Odcinek", "\(s.id)#\(i)"))
                                .foregroundStyle(by: .value("Seria", s.nazwa))
                        }
                    }
                }
            }
            if let linia {
                ForEach(Array(HistoriaParsers.odcinki(linia, warstwowy: false).enumerated()), id: \.offset) { i, odc in
                    ForEach(odc, id: \.czas) { p in
                        LineMark(x: .value("Czas", p.czas),
                                 y: .value("Wartość", p.naWykresie ?? 0),
                                 series: .value("Odcinek", "linia#\(i)"))
                            .foregroundStyle(Color.primary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
            }
            if let wybrany {
                RuleMark(x: .value("Czas", wybrany))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        dymek(wybrany)
                    }
            }
        }
        .modifier(SkalaKolorowWykresu(nazwy: serie.map(\.nazwa), kolory: kolory))
        .chartXSelection(value: $wybrany)
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(FormatHistorii.wartosc(d, jednostka)) }
                }
            }
        }
        .frame(height: wysokosc)
    }

    private var jednostka: JednostkaHistorii { serie.first?.jednostka ?? linia?.jednostka ?? .procent }

    @ViewBuilder private func dymek(_ czas: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(czas.formatted(date: .abbreviated, time: .shortened)).font(.caption2.bold())
            ForEach(serie + (linia.map { [$0] } ?? [])) { s in
                let p = s.punkty.min { abs($0.czas.timeIntervalSince(czas)) < abs($1.czas.timeIntervalSince(czas)) }
                // Warstwy pokazują średnią (z niej są narysowane), linie — to, co widać na wykresie.
                let w = warstwowy && s.id != linia?.id ? p?.wartosc : p?.naWykresie
                Text("\(s.nazwa): \(FormatHistorii.wartosc(w, s.jednostka))")
                    .font(.caption2.monospacedDigit())
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(radius: 2))
    }
}

/// Przypina kolory do nazw serii. Bez listy kolorów zostaje paleta systemu.
private struct SkalaKolorowWykresu: ViewModifier {
    var nazwy: [String]
    var kolory: [Color]?

    func body(content: Content) -> some View {
        if let kolory, let ostatni = kolory.last, !nazwy.isEmpty {
            content.chartForegroundStyleScale(
                domain: nazwy,
                range: nazwy.indices.map { $0 < kolory.count ? kolory[$0] : ostatni })
        } else {
            content
        }
    }
}

/// Średnia i szczyt — linijka pod wykresem.
struct PodsumowanieSerii: View {
    var seria: SeriaHistorii

    var body: some View {
        HStack(spacing: 12) {
            Text(seria.nazwa).fontWeight(.medium)
            Text("średnio \(FormatHistorii.wartosc(seria.srednia, seria.jednostka))")
            Text("szczyt \(FormatHistorii.wartosc(seria.szczyt, seria.jednostka))")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// Brak zbieracza albo stara wersja — przycisk z pytaniem (konwencja projektu: akcje
/// na serwerze z potwierdzeniem, audyt SBW 2026-09-24).
struct BrakZbieracza: View {
    @Environment(AppModel.self) private var model
    var stan: StanZbieracza
    var poInstalacji: () -> Void
    @State private var pytanie = false
    @State private var trwa = false
    @State private var blad: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stan == .brak
                 ? "Serwer nie zbiera jeszcze historii temperatur i poboru mocy."
                 : "Na serwerze jest starsza wersja zbieracza historii.")
                .font(.callout)
            HStack {
                Button(stan == .brak ? "Zainstaluj zbieranie historii" : "Zaktualizuj zbieranie historii") {
                    pytanie = true
                }
                .disabled(trwa)
                if trwa { ProgressView().controlSize(.small) }
            }
            if let blad {
                Text(blad).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        .confirmationDialog("Zainstalować na serwerze zbieracz historii?", isPresented: $pytanie) {
            Button("Zainstaluj") {
                Task {
                    trwa = true
                    switch await model.zainstalujZbieracz() {
                    case .success: blad = nil; poInstalacji()
                    case .failure(let e): blad = e.opis
                    }
                    trwa = false
                }
            }
        } message: {
            Text("mNas doinstaluje pakiet rrdtool, wgra skrypt /usr/local/bin/mnas-historia i timer systemd co minutę. Dyski talerzowe są odczytywane tylko wtedy, gdy same pracują — zbieracz ich nie budzi.")
        }
    }
}

/// Komunikat błędu odczytu — ten sam wygląd we wszystkich widokach historii.
struct BladHistoriiWidok: View {
    var opis: String
    var body: some View {
        Label(opis, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
