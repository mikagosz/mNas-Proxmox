import SwiftUI

/// Pierścień z wartością w środku (obciążenie, % zajętości itp.). Animuje zmianę.
struct RingGauge: View {
    var fraction: Double            // 0…1
    var title: String               // duży tekst w środku
    var caption: LocalizedStringKey             // podpis pod tytułem
    var tint: Color = .accentColor
    var diameter: CGFloat = 92
    var lineWidth: CGFloat = 9

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: clamped)
            VStack(spacing: 1) {
                Text(title)
                    .font(.title3.bold().monospacedDigit())
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        // Pierścień jest czystą grafiką — bez tego VoiceOver przeczytałby dwa luźne
        // napisy („43%", „Użycie") bez informacji, czego dotyczą i że tworzą jedną całość.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(title)
    }
}

/// Mini-wykres liniowy z historii wartości (np. obciążenie / zużycie CPU w czasie).
struct Sparkline: View {
    var points: [Double]
    var tint: Color = .accentColor
    var upperBound: Double? = nil     // stała skala osi Y (np. 100 dla CPU %)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            if points.count > 1 {
                let maxV = max(upperBound ?? (points.max() ?? 1), 0.001)
                let stepX = w / CGFloat(points.count - 1)
                let path = Path { p in
                    for (i, v) in points.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = h * (1 - CGFloat(v / maxV))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                let fill = Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    for (i, v) in points.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = h * (1 - CGFloat(v / maxV))
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                fill.fill(
                    LinearGradient(colors: [tint.opacity(0.25), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
                path.stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else {
                Rectangle().fill(.clear)
            }
        }
        .frame(height: 44)
        // Wykres narysowany ścieżką jest dla VoiceOvera niewidoczny w całości.
        // Zamiast czytać kształt, podajemy to, co z niego wynika: ile pomiarów i ostatnia
        // wartość — czyli dokładnie to, po co użytkownik na ten wykres patrzy.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wykres w czasie")
        .accessibilityValue(
            points.isEmpty
                ? "brak pomiarów"
                : "\(points.count) pomiarów, ostatni \(Int((points.last ?? 0).rounded()))"
        )
    }
}

// MARK: - Donut wielosegmentowy (RAM, CPU)

/// Jeden wycinek donuta.
///
/// `id` to etykieta, nie `UUID()`. Przy losowej tożsamości nowe `id` powstawało przy
/// każdym wyliczeniu `body`, więc `.animation(value: arc.end)` nigdy nie porównywało
/// dwóch stanów tego samego łuku i animacja pierścienia w praktyce nie działała.
struct DonutSegment: Identifiable {
    var value: Double
    var color: Color
    var label: String

    var id: String { label }
}

/// Pierścień złożony z kilku kolorowych segmentów proporcjonalnych do wartości.
/// Opcjonalny tekst w środku (dla CPU „NN%" + „Avg Usage").
struct DonutChart: View {
    var segments: [DonutSegment]
    var centerTitle: String? = nil
    var centerCaption: LocalizedStringKey? = nil
    var diameter: CGFloat = 140
    var lineWidth: CGFloat = 24

    private var total: Double { max(segments.map(\.value).reduce(0, +), 0.0001) }

    private struct Arc: Identifiable { let id: String; var start: Double; var end: Double; var color: Color }

    private var arcs: [Arc] {
        var acc = 0.0
        return segments.map { s in
            let start = acc / total
            acc += max(s.value, 0)
            return Arc(id: s.id, start: start, end: acc / total, color: s.color)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)   // tło pierścienia
            ForEach(arcs) { arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: arc.end)
            }
            if let centerTitle {
                VStack(spacing: 1) {
                    Text(centerTitle)
                        .font(.title2.bold().monospacedDigit())
                        .contentTransition(.numericText())
                    if let centerCaption {
                        Text(centerCaption).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: diameter, height: diameter)
        // Segmenty to łuki — VoiceOver nie ma z czego odczytać podziału. Wyliczamy go
        // słowami: etykieta segmentu plus jego udział procentowy, w kolejności rysowania.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(centerCaption ?? "Podział")
        .accessibilityValue(
            segments
                .map { String(localized: "\($0.label) \(Int((max($0.value, 0) / total * 100).rounded())) procent") }
                .joined(separator: ", ")
        )
    }
}

// MARK: - Gauge półkole (pamięć masowa)

/// Łuk 270° z wartością w środku (jak „Usage" w TrueNAS).
///
/// Kropka na końcu postępu **usunięta 2026-08-16** (polecenie [U]): przy zerowym
/// wypełnieniu wisiała samotnie na początku łuku i wyglądała jak usterka, a przy
/// wypełnionym niczego nie dodawała — koniec łuku i tak jest zaokrąglony.
struct ArcGauge: View {
    var fraction: Double            // 0…1
    var centerTitle: String
    var centerCaption: LocalizedStringKey? = nil
    var tint: Color = .accentColor
    var diameter: CGFloat = 150
    var lineWidth: CGFloat = 14

    private let sweep = 0.75        // 270° z przerwą u dołu
    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: sweep * clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeInOut(duration: 0.5), value: clamped)
            VStack(spacing: 1) {
                Text(centerTitle).font(.title2.bold().monospacedDigit())
                if let centerCaption {
                    Text(centerCaption).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(centerCaption ?? "Zajętość")
        .accessibilityValue("\(centerTitle), \(Int((clamped * 100).rounded())) procent")
    }
}

// MARK: - Słupki temperatur per rdzeń

/// Słupki zużycia (%) dla każdego rdzenia CPU.
///
/// Parametry rozmiaru istnieją po to, żeby te same słupki weszły na mały kafel
/// (144 pt) — tam nie mieszczą się podpisy, ale sam wykres owszem.
struct CoreUsageBars: View {
    var values: [Double]              // 0…100
    var barWidth: CGFloat = 20
    var barSpacing: CGFloat = 8
    var maxBarHeight: CGFloat = 64
    var showLabels = true

    private func color(_ v: Double) -> Color { v >= 85 ? .red : (v >= 60 ? .orange : .accentColor) }
    private func height(_ v: Double) -> CGFloat { max(3, min(maxBarHeight, CGFloat(v / 100) * maxBarHeight)) }

    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                VStack(spacing: showLabels ? 4 : 2) {
                    if showLabels {
                        Text("\(Int(v.rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(color(v))
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(v).gradient)
                        .frame(width: barWidth, height: height(v))
                        .animation(.easeInOut(duration: 0.5), value: v)
                    if showLabels {
                        Text("R\(i)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // Każdy słupek osobno: VoiceOver przechodzi rdzeń po rdzeniu, zamiast
                // czytać ciąg samych liczb bez przypisania („3%, 4%, 2%…").
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rdzeń \(i)")
                .accessibilityValue("\(Int(v.rounded())) procent")
            }
        }
        .frame(height: showLabels ? maxBarHeight + 28 : maxBarHeight, alignment: .bottom)
    }
}

/// Ikona wentylatora kręcąca się z prędkością zależną od RPM (0 = stoi).
///
/// Kąt **narasta** zamiast wracać do zera. Wcześniej każda zmiana RPM — czyli co 5 s,
/// przy każdym odczycie — zerowała kąt i startowała animację od nowa, więc ikona skakała
/// zamiast kręcić się płynnie. Dodatkowo restartujemy animację tylko przy realnej zmianie
/// prędkości, a nie przy drgnięciu odczytu o kilka obrotów.
struct SpinningFan: View {
    var rpm: Double
    @State private var angle = 0.0

    /// Poniżej tej różnicy RPM traktujemy jako „to samo tempo".
    private let meaningfulChange = 60.0

    var body: some View {
        Image(systemName: "fanblades.fill")
            .font(.title2)
            .rotationEffect(.degrees(angle))
            // Animacja obrotu nie niesie żadnej informacji dla VoiceOvera — liczbę obrotów
            // trzeba podać wprost. „stoi" zamiast „0 obrotów", bo to jest realny stan sprzętu.
            .accessibilityLabel("Wentylator")
            .accessibilityValue(rpm > 0 ? "\(Int(rpm.rounded())) obrotów na minutę" : "stoi")
            .onAppear { start() }
            .onChange(of: rpm) { old, new in
                guard (old > 0) != (new > 0) || abs(new - old) >= meaningfulChange else { return }
                start()
            }
    }

    private func start() {
        guard rpm > 0 else {
            // Wentylator stanął — zatrzymujemy obrót tam, gdzie właśnie jest.
            withAnimation(.linear(duration: 0)) { angle = angle.truncatingRemainder(dividingBy: 360) }
            return
        }
        withAnimation(.linear(duration: max(0.3, 1500 / rpm)).repeatForever(autoreverses: false)) {
            angle += 360
        }
    }
}

/// Słupki temperatury dla każdego rdzenia CPU (magenta/pomarańcz/czerwień wg progu).
struct CoreTempBars: View {
    var temps: [Double]
    var maxTemp: Double = 90
    var barWidth: CGFloat = 20
    var barSpacing: CGFloat = 8
    var maxBarHeight: CGFloat = 64
    var showLabels = true

    private func color(_ t: Double) -> Color { t >= 70 ? .red : (t >= 55 ? .orange : .green) }
    private func height(_ t: Double) -> CGFloat { max(4, min(maxBarHeight, CGFloat(t / maxTemp) * maxBarHeight)) }

    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(Array(temps.enumerated()), id: \.offset) { i, t in
                VStack(spacing: showLabels ? 4 : 2) {
                    if showLabels {
                        Text("\(Int(t.rounded()))°")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(color(t))
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color(t).gradient)
                        .frame(width: barWidth, height: height(t))
                        .animation(.easeInOut(duration: 0.5), value: t)
                    if showLabels {
                        Text("R\(i)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rdzeń \(i)")
                .accessibilityValue("\(Int(t.rounded())) stopni")
            }
        }
        .frame(height: showLabels ? maxBarHeight + 28 : maxBarHeight, alignment: .bottom)
    }
}
