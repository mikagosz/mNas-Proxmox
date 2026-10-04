import SwiftUI

// MARK: - Wspólne elementy paneli

/// Rama panelu: nagłówek z ikoną + krzyżyk + przewijana zawartość.
struct PanelScaffold<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.title3.bold())
                    .foregroundStyle(tint)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            ThinScrollView {
                VStack(alignment: .leading, spacing: 14) { content() }
                    .padding(16)
            }
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 460, idealHeight: 560)
        .background(.background)
        // Arkusz to osobna hierarchia — ustawienie z `RootView` samo tu nie zejdzie.
        // `.never`, nie `.hidden` — powód przy tym samym modyfikatorze w `ContentView`.
        .scrollIndicators(.never)
    }
}

/// Blok wyjścia terminala (monospaced, przewijany, do zaznaczenia).
struct MonoOutput: View {
    var text: String
    var minHeight: CGFloat = 120
    var maxHeight: CGFloat = 280

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "—" : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Podtytuł sekcji wewnątrz panelu.
struct PanelSection<Content: View>: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let systemImage {
                Label(title, systemImage: systemImage).font(.subheadline.bold())
            } else {
                Text(title).font(.subheadline.bold())
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - CPU

struct CPUPanel: View {
    @State private var zakladka: ZakladkaPanelu = .teraz
    @Environment(AppModel.self) private var model
    @State private var procs = ""
    @State private var loading = false

    var body: some View {
        PanelScaffold(title: "Procesor", systemImage: "cpu", tint: .blue) {
            PrzelacznikZakladki(zakladka: $zakladka)
            if zakladka == .teraz {
                HStack(spacing: 20) {
                    if let u = model.cpuUsagePercent {
                        DonutChart(
                            segments: [DonutSegment(value: u, color: u > 85 ? .red : (u > 60 ? .orange : .blue), label: "u"),
                                       DonutSegment(value: max(0, 100 - u), color: .clear, label: "f")],
                            centerTitle: "\(Int(u.rounded()))%", centerCaption: "Użycie",
                            diameter: 110, lineWidth: 12)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.systemInfo?.model ?? "—").font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        kv("Rdzenie", model.systemInfo?.cores.map(String.init) ?? "—")
                        kv("Obciążenie (1/5/15 min)", model.systemInfo?.loadavg?.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " / ") ?? "—")
                        kv("Uptime", Format.uptime(model.systemInfo?.uptimeSeconds))
                        if let t = model.cpu.packageTemp { kv("Temperatura pakietu", "\(Int(t.rounded())) °C") }
                    }
                    Spacer()
                }

                if !model.cpu.perCoreUsage.isEmpty {
                    PanelSection(title: "Zużycie rdzeni") { CoreUsageBars(values: model.cpu.perCoreUsage) }
                }
                if !model.cpu.perCoreTemp.isEmpty {
                    PanelSection(title: "Temperatury rdzeni") { CoreTempBars(temps: model.cpu.perCoreTemp) }
                }

                PanelSection(title: "Najbardziej obciążające procesy", systemImage: "list.bullet.rectangle") {
                    MonoOutput(text: procs)
                    Button { Task { await load() } } label: { Label(String(localized: "Odśwież listę"), systemImage: "arrow.clockwise") }
                        .disabled(loading)
                }
            } else {
                HistoriaCPUWidok()
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        procs = await model.topProcesses(by: "cpu")
        loading = false
    }
    private func kv(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(minLength: 10); Text(v).fontWeight(.medium) }.font(.caption)
    }
}

// MARK: - RAM

struct MemoryPanel: View {
    @State private var zakladka: ZakladkaPanelu = .teraz
    @Environment(AppModel.self) private var model
    @State private var procs = ""

    private let cFree = Color.green, cZFS = Color.teal, cSvc = Color.orange

    var body: some View {
        PanelScaffold(title: "Pamięć RAM", systemImage: "memorychip", tint: .green) {
            PrzelacznikZakladki(zakladka: $zakladka)
            if zakladka == .teraz {
                HStack(spacing: 20) {
                    if model.memory.hasBreakdown {
                        DonutChart(segments: segments(), diameter: 120, lineWidth: 22)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Format.bytes(model.memory.total)).font(.title2.bold())
                        Text("zainstalowane łącznie").font(.caption).foregroundStyle(.secondary)
                        if model.memory.hasBreakdown {
                            legend(cFree, "Wolne", model.memory.free)
                            legend(cZFS, "Cache ZFS (ARC)", model.memory.zfsCache)
                            legend(cSvc, "Aplikacje / usługi", model.memory.services)
                            if let total = model.memory.total, let free = model.memory.free {
                                let used = max(0, total - free)
                                Divider().padding(.vertical, 2)
                                legend(.primary, "W użyciu łącznie", used)
                            }
                        } else {
                            Text("Szczegóły zużycia pojawią się po połączeniu SSH (odczyt /proc/meminfo + ARC).")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
                PanelSection(title: "Procesy zajmujące najwięcej RAM", systemImage: "list.bullet.rectangle") {
                    MonoOutput(text: procs)
                    Button { Task { procs = await model.topProcesses(by: "mem") } } label: {
                        Label("Odśwież listę", systemImage: "arrow.clockwise")
                    }
                }
            } else {
                HistoriaRAMWidok()
            }
        }
        .task { procs = await model.topProcesses(by: "mem") }
    }

    private func segments() -> [DonutSegment] {
        var out: [DonutSegment] = []
        if let f = model.memory.free { out.append(DonutSegment(value: Double(f), color: cFree, label: String(localized: "Wolne"))) }
        if let z = model.memory.zfsCache { out.append(DonutSegment(value: Double(z), color: cZFS, label: String(localized: "ZFS"))) }
        if let s = model.memory.services { out.append(DonutSegment(value: Double(s), color: cSvc, label: String(localized: "Usługi"))) }
        return out
    }
    private func legend(_ c: Color, _ l: LocalizedStringKey, _ b: Int64?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 9, height: 9)
            Text(l).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(Format.bytes(b)).font(.caption.monospacedDigit())
        }
    }
}

// MARK: - GPU

struct GPUPanel: View {
    @Environment(AppModel.self) private var model
    @State private var status = ""
    @State private var procs = ""
    @State private var diag = ""
    @State private var busy = false
    @State private var confirmLoadDriver = false

    var body: some View {
        PanelScaffold(title: "GPU", systemImage: "display", tint: .green) {
            Text(model.gpu.name ?? "—").font(.callout.weight(.semibold))
            if let u = model.gpu.utilization {
                HStack(spacing: 16) {
                    DonutChart(segments: [DonutSegment(value: u, color: .green, label: "u"),
                                          DonutSegment(value: max(0, 100 - u), color: .clear, label: "f")],
                               centerTitle: "\(Int(u.rounded()))%", centerCaption: "Użycie",
                               diameter: 100, lineWidth: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        if let t = model.gpu.temperature { kv("Temperatura", "\(Int(t.rounded())) °C") }
                        if let p = model.gpu.powerWatts { kv("Pobór", String(format: "%.0f W", p)) }
                        if let mu = model.gpu.memoryUsed, let mt = model.gpu.memoryTotal {
                            kv("Pamięć", "\(Int(mu)) / \(Int(mt)) MiB")
                        }
                    }
                    Spacer()
                }
            }

            PanelSection(title: "nvidia-smi", systemImage: "terminal") {
                MonoOutput(text: status)
                HStack {
                    Button { Task { status = await model.gpuFullStatus() } } label: { Label(String(localized: "Odśwież"), systemImage: "arrow.clockwise") }
                    Button { Task { procs = await model.gpuProcesses() } } label: { Label(String(localized: "Procesy na GPU"), systemImage: "list.number") }
                }
                if !procs.isEmpty { MonoOutput(text: procs, minHeight: 60, maxHeight: 140) }
            }

            PanelSection(title: "Sterownik — diagnoza i naprawa", systemImage: "wrench.and.screwdriver") {
                Text("Gdy nvidia-smi pisze błąd komunikacji ze sterownikiem, tu sprawdzisz czemu i spróbujesz podpiąć moduł.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { Task { busy = true; diag = await model.gpuDriverDiagnostics(); busy = false } } label: {
                        Label("Diagnoza", systemImage: "stethoscope")
                    }
                    Button { confirmLoadDriver = true } label: {
                        Label("Spróbuj podpiąć sterownik", systemImage: "bolt.horizontal")
                    }
                    .tint(.orange)
                    .disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if !diag.isEmpty {
                    if let plain = model.interpretDriverError(diag) {
                        Label(plain, systemImage: "info.circle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("Szczegóły techniczne") {
                        MonoOutput(text: diag)
                    }
                    .font(.caption)
                }
            }
        }
        .task { status = await model.gpuFullStatus() }
        // Konwencja projektu: akcje modyfikujące serwer zawsze z potwierdzeniem.
        // `modprobe -r nouveau; modprobe nvidia` jako root wykonywało się jednym kliknięciem.
        .alert("Podpiąć sterownik NVIDIA?", isPresented: $confirmLoadDriver) {
            Button("Spróbuj", role: .destructive) {
                Task { busy = true; diag = await model.gpuTryLoadDriver(); status = await model.gpuFullStatus(); busy = false }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Na serwerze zostanie wyładowany moduł nouveau i załadowany nvidia (jako root). Jeśli z GPU korzysta w tej chwili konsola albo maszyna wirtualna, obraz może mrugnąć lub zniknąć.")
        }
    }
    private func kv(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(minLength: 10); Text(v).fontWeight(.medium) }.font(.caption)
    }
}

// MARK: - Kondycja dysku (SMART)

struct DiskHealthView: View {
    @State private var zakladka: ZakladkaPanelu = .teraz
    @Environment(AppModel.self) private var model
    let disk: Disk
    @State private var result: DiskHealthResult?
    @State private var loading = true
    @State private var message = ""
    /// `true` = test długi, `false` = krótki, `nil` = brak pytania. Konwencja projektu:
    /// akcje na serwerze z potwierdzeniem — `smartctl -t` szło jednym kliknięciem
    /// (audyt SBW 2026-09-24, E3-S-P2-01).
    @State private var testDoPotwierdzenia: Bool?

    var body: some View {
        PanelScaffold(title: "\(disk.model ?? disk.name)", systemImage: "internaldrive", tint: .cyan) {
            PrzelacznikZakladki(zakladka: $zakladka)
            if zakladka == .teraz {
                Text("\(disk.name) · \(disk.type ?? "—") · \(Format.bytes(disk.size?.value))")
                    .font(.caption).foregroundStyle(.secondary)

                if loading && result == nil {
                    HStack { ProgressView().controlSize(.small); Text("Odczyt SMART…").font(.caption).foregroundStyle(.secondary) }
                }

                if let r = result {
                    if !r.ok {
                        Label(r.rawError ?? String(localized: "Nie udało się odczytać SMART."), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: (r.passed ?? true) ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .font(.title).foregroundStyle((r.passed ?? true) ? .green : .red)
                            VStack(alignment: .leading) {
                                Text((r.passed == false) ? "SMART: FAILED" : "SMART: PASSED")
                                    .font(.headline).foregroundStyle((r.passed ?? true) ? .green : .red)
                                if let st = r.selfTestStatus { Text(st).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        HStack(spacing: 24) {
                            if let t = r.temperature {
                                stat("Temperatura", "\(Int(t.rounded())) °C", t >= 55 ? .red : (t >= 45 ? .orange : .green))
                            } else {
                                // Brak czujnika to fakt o dysku, nie usterka odczytu — pusty
                                // slot wyglądał jak coś, co się nie doczytało.
                                stat("Temperatura", String(localized: "brak czujnika"), .secondary)
                            }
                            if let h = r.powerOnHours { stat("Godziny pracy", "\(h) h", .primary) }
                            if let s = r.serial { stat("Nr seryjny", s, .secondary) }
                        }

                        let krytyczne = r.attributes.filter(\.critical)
                        let pozostale = r.attributes.filter { !$0.critical }

                        if !krytyczne.isEmpty {
                            PanelSection(title: "Wskaźniki krytyczne") {
                                ForEach(krytyczne) { attributeRow($0) }
                            }
                        }
                        if !pozostale.isEmpty {
                            PanelSection(title: "Pozostałe wskaźniki") {
                                ForEach(pozostale) { attributeRow($0) }
                            }
                        }
                        if r.attributes.isEmpty {
                            Text("Dysk nie udostępnia tablicy wskaźników SMART — werdykt wyżej to wszystko, co podaje.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.blue)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                PanelSection(title: "Testy dysku", systemImage: "waveform.path.ecg") {
                    HStack {
                        Button { Task { await load() } } label: { Label(String(localized: "Odśwież kondycję"), systemImage: "arrow.clockwise") }
                        Button { testDoPotwierdzenia = false } label: { Label(String(localized: "Test krótki"), systemImage: "bolt") }
                        Button { testDoPotwierdzenia = true } label: { Label(String(localized: "Test długi"), systemImage: "hourglass") }.tint(.orange)
                    }
                }
            } else {
                HistoriaDyskuWidok(disk: disk)
            }
        }
        .task { await load() }
        .alert(testDoPotwierdzenia == true ? "Uruchomić długi test SMART?" : "Uruchomić krótki test SMART?",
               isPresented: Binding(get: { testDoPotwierdzenia != nil },
                                    set: { if !$0 { testDoPotwierdzenia = nil } }),
               presenting: testDoPotwierdzenia) { dlugi in
            Button(dlugi ? "Uruchom długi" : "Uruchom krótki") {
                Task { message = await model.startSelfTest(disk.name, long: dlugi) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { dlugi in
            Text(dlugi
                 ? "Na serwerze ruszy `smartctl -t long` na \(disk.name) (jako root). Na dysku talerzowym to godziny pracy — dysk nie zaśnie, dopóki test trwa."
                 : "Na serwerze ruszy `smartctl -t short` na \(disk.name) (jako root). Trwa kilka minut i budzi dysk, jeśli spał.")
        }
    }

    /// Jeden wiersz wskaźnika SMART. Wskaźniki informacyjne dostają szarą kropkę:
    /// zielona przy „Cykle zasilania: 3835" sugerowałaby ocenę, której nie wydajemy.
    @ViewBuilder private func attributeRow(_ a: SmartAttribute) -> some View {
        HStack {
            Circle()
                .fill(a.critical ? color(a.severity) : Color.secondary.opacity(0.35))
                .frame(width: 9, height: 9)
            Text(a.name).font(.caption)
            Spacer()
            Text(a.value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(a.critical ? color(a.severity) : Color.primary)
        }
    }

    private func load() async {
        loading = true
        result = await model.diskHealth(disk.name)
        loading = false
    }
    private func color(_ s: SmartAttribute.Severity) -> Color {
        switch s { case .ok: return .green; case .warn: return .orange; case .crit: return .red }
    }
    private func stat(_ k: LocalizedStringKey, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.callout.weight(.semibold)).foregroundStyle(c).lineLimit(1)
        }
    }
}

// MARK: - Usługa

struct ServicePanel: View {
    @Environment(AppModel.self) private var model
    let service: Service
    let displayName: String
    @State private var working = false
    @State private var pending: Operation?
    /// Błąd ostatniej operacji — tutaj, bo baner dashboardu leży pod tym panelem.
    @State private var bladAkcji: String?

    /// Ta sama operacja wywoływana z menu kontekstowego dashboardu przechodzi przez
    /// potwierdzenie — tutaj wykonywała się jednym kliknięciem. Konwencja projektu mówi
    /// wprost: akcje modyfikujące serwer zawsze z potwierdzeniem w UI.
    private enum Operation: String, Identifiable {
        case start, stop, restart
        var id: String { rawValue }

        var title: String {
            switch self {
            case .start:   return String(localized: "Uruchomić usługę?")
            case .stop:    return String(localized: "Zatrzymać usługę?")
            case .restart: return String(localized: "Zrestartować usługę?")
            }
        }
        var button: String {
            switch self {
            case .start:   return String(localized: "Uruchom")
            case .stop:    return String(localized: "Zatrzymaj")
            case .restart: return String(localized: "Restart")
            }
        }
        var isDestructive: Bool { self != .start }
    }

    private var running: Bool { service.state?.uppercased() == "RUNNING" }

    var body: some View {
        PanelScaffold(title: "\(displayName)", systemImage: "gearshape.2", tint: .indigo) {
            HStack(spacing: 10) {
                Circle().fill(running ? .green : .secondary).frame(width: 12, height: 12)
                Text(running ? "Działa" : "Zatrzymana").font(.headline).foregroundStyle(running ? .green : .secondary)
                if service.enable == true {
                    Label("startuje z systemem", systemImage: "bolt.fill").font(.caption).foregroundStyle(.yellow)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            HStack {
                Button { pending = .start } label: { Label(String(localized: "Uruchom"), systemImage: "play.fill") }
                    .disabled(running || working).tint(.green)
                Button { pending = .stop } label: { Label(String(localized: "Zatrzymaj"), systemImage: "stop.fill") }
                    .disabled(!running || working).tint(.red)
                Button { pending = .restart } label: { Label(String(localized: "Restart"), systemImage: "arrow.clockwise") }
                    .disabled(working).tint(.orange)
            }
            if let bladAkcji {
                Label(bladAkcji, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("Wewnętrzna nazwa usługi: \(service.service)").font(.caption2).foregroundStyle(.secondary)
        }
        .alert(pending?.title ?? "Potwierdź", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), presenting: pending) { op in
            Button(op.button, role: op.isDestructive ? .destructive : nil) { perform(op) }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("\(displayName) na serwerze. Klienci korzystający z tej usługi (udziały, sesje) stracą połączenie.")
        }
    }

    private func perform(_ op: Operation) {
        Task {
            working = true
            switch op {
            case .start:   bladAkcji = await model.setService(service.service, running: true)
            case .stop:    bladAkcji = await model.setService(service.service, running: false)
            case .restart: bladAkcji = await model.restartService(service.service)
            }
            working = false
        }
    }
}

// MARK: - Wentylatory / czujniki (lm-sensors + PWM)

struct FanPanel: View {
    @Environment(AppModel.self) private var model
    @State private var sensors = ""
    @State private var channels: [PWMChannel] = []
    @State private var loadOut = ""
    @State private var detectOut = ""
    @State private var busy = false
    @State private var detecting = false
    /// `modprobe it87` i `modprobe it87 force_id=0x8622` szły jednym kliknięciem —
    /// moduł zostaje w jądrze hiperwizora do restartu. Audyt SBW 2026-09-24, E3-S-P2-01.
    @State private var potwierdzModul = false
    /// Zmiana czekająca na potwierdzenie trybu ręcznego (raz na sesję, nie przy każdym ruchu).
    @State private var pendingManual: (path: String, value: Int)?
    @State private var confirmManual = false
    @State private var pwmMessage = ""

    private var fanCount: Int { model.fans.count }

    var body: some View {
        PanelScaffold(title: "Wentylatory i czujniki", systemImage: "fanblades", tint: .mint) {
            HStack(spacing: 8) {
                Image(systemName: fanCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(fanCount > 0 ? .green : .orange)
                Text(fanCount > 0 ? "Wykryto \(fanCount) wentylator(y)." : "Wentylatory jeszcze niewidoczne — moduł czujników się nie podpiął.")
                    .font(.callout.weight(.medium))
            }

            if fanCount == 0 {
                HStack {
                    // Dwa różne działania miały do 2026-08-17 tę samą etykietę „Wykryj
                    // czujniki" — nie dało się z UI poznać, który przycisk co robi.
                    Button { potwierdzModul = true } label: {
                        Label("Podłącz moduł", systemImage: "bolt.badge.automatic")
                    }
                    .tint(.orange).disabled(busy)
                    .help("Próbuje wczytać sterownik czujników (modprobe) na serwerze")
                    Button { Task { detecting = true; detectOut = await model.sensorsDetect(); detecting = false } } label: {
                        Label("Skanuj układy", systemImage: "magnifyingglass")
                    }
                    .disabled(detecting)
                    .help("Uruchamia sensors-detect — przeszukuje magistrale w poszukiwaniu układu czujników")
                    if busy || detecting { ProgressView().controlSize(.small) }
                }

                if !loadOut.isEmpty {
                    if let plain = model.interpretDriverError(loadOut) {
                        Label(plain, systemImage: "info.circle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("Szczegóły techniczne (próba załadowania)") {
                        MonoOutput(text: loadOut, minHeight: 80, maxHeight: 180)
                    }
                    .font(.caption)
                }
                if !detectOut.isEmpty {
                    DisclosureGroup("Wynik sensors-detect") {
                        MonoOutput(text: detectOut, minHeight: 100, maxHeight: 240)
                    }
                    .font(.caption)
                }
            } else {
                Button { Task { busy = true; await reload(); busy = false } } label: { Label(String(localized: "Odśwież"), systemImage: "arrow.clockwise") }
                    .disabled(busy)
            }

            if !channels.isEmpty {
                PanelSection(title: "Sterowanie PWM", systemImage: "slider.horizontal.3") {
                    Text("Suwak zaczyna się od \(PWM.minimum)/255 — poniżej tego progu wentylator staje, a układ jest już w trybie ręcznym i sam obrotów nie podniesie. Przy zamknięciu apki mNas przywraca automat na kanałach, które sam ruszył.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach($channels) { $ch in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(ch.shortName)
                                    .font(.caption.monospaced())
                                if model.manualPWMPaths.contains(ch.path) {
                                    Text("tryb ręczny")
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.orange.opacity(0.2), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Text("\(Int(ch.value))/255 · \(Int(ch.value / 255 * 100))%")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            HStack {
                                Slider(value: $ch.value,
                                       in: Double(PWM.minimum)...Double(PWM.maximum),
                                       onEditingChanged: { editing in
                                    guard !editing else { return }
                                    apply(path: ch.path, value: Int(ch.value))
                                })
                                Button("Auto") { let p = ch.path; Task { pwmMessage = await model.setPWMAuto(path: p); await reload() } }
                                    .controlSize(.small)
                            }
                        }
                    }

                    if !pwmMessage.isEmpty {
                        Text(pwmMessage).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            DisclosureGroup {
                MonoOutput(text: sensors)
            } label: {
                Label("Surowy odczyt sensors", systemImage: "thermometer")
                    .font(.subheadline.bold())
            }
        }
        .task { await reload() }
        .alert("Wczytać sterownik czujników?", isPresented: $potwierdzModul) {
            Button("Wczytaj", role: .destructive) {
                Task { busy = true; loadOut = await model.loadSensorsModule(); await reload(); busy = false }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Na serwerze zostaną wykonane po kolei `modprobe it87` i `modprobe it87 force_id=0x8622` (jako root) — drugie wymusza rozpoznanie układu jako ITE 8622. Moduł zostaje w jądrze do restartu serwera.")
        }
        // Potwierdzenie raz na sesję, nie przy każdym ruchu suwaka — chodzi o to, żeby
        // użytkownik świadomie wyłączył automatykę układu, a nie żeby go męczyć.
        .alert("Przejść w tryb ręczny?", isPresented: $confirmManual) {
            Button("Ustaw ręcznie", role: .destructive) {
                model.pwmManualConfirmed = true
                if let p = pendingManual { send(path: p.path, value: p.value) }
                pendingManual = nil
            }
            Button("Anuluj", role: .cancel) { pendingManual = nil; Task { await reload() } }
        } message: {
            Text("Zapis wartości PWM ustawia pwmX_enable = 1, czyli układ przestaje sam regulować obroty — nie podniesie ich przy wzroście temperatury. mNas przywróci tryb automatyczny przy rozłączeniu i przy zamknięciu aplikacji.")
        }
    }

    /// Pierwsza zmiana w sesji przechodzi przez potwierdzenie, kolejne już nie.
    private func apply(path: String, value: Int) {
        guard model.pwmManualConfirmed else {
            pendingManual = (path, value)
            confirmManual = true
            return
        }
        send(path: path, value: value)
    }

    private func send(path: String, value: Int) {
        Task { pwmMessage = await model.setPWM(path: path, value: value) }
    }

    private func reload() async {
        sensors = await model.sensorsRaw()
        // Kanał ustawiony wcześniej poniżej progu (np. ręcznie na serwerze) podciągamy
        // do minimum suwaka, żeby uchwyt i liczba obok niego pokazywały to samo.
        // Na serwer nic nie leci — zapis dzieje się dopiero, gdy user ruszy suwakiem.
        channels = await model.pwmChannels().map { ch in
            var ch = ch
            ch.value = max(ch.value, Double(PWM.minimum))
            return ch
        }
    }
}

// MARK: - Terminal (dowolna komenda — pełny dostęp)

struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @State private var command = ""
    @State private var output = String(localized: "Wpisz komendę i naciśnij Enter. To realna powłoka roota na serwerze — bez ograniczeń.")
    @State private var useSudo = true
    @State private var running = false
    @State private var history: [String] = []
    @State private var fixingSudo = false

    var body: some View {
        PanelScaffold(title: "Terminal serwera", systemImage: "terminal", tint: .primary) {
            Text("Pełny dostęp: cokolwiek zrobisz z powłoki roota, zrobisz stąd. \(model.sshUser)@\(model.host)")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    Task { fixingSudo = true; output = await model.checkRootShell(); fixingSudo = false }
                } label: {
                    Label("Sprawdź dostęp roota", systemImage: "bolt.shield")
                }
                .disabled(fixingSudo)
                if fixingSudo { ProgressView().controlSize(.small) }
                Text("Na Proxmoksie mNas loguje się przez SSH bezpośrednio rootem — sudo nie jest potrzebne.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Image(systemName: "chevron.right").foregroundStyle(.green)
                TextField("np. zpool status  ·  sensors  ·  systemctl status", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { run() }
                Toggle("sudo", isOn: $useSudo).toggleStyle(.switch).controlSize(.mini).fixedSize()
                Button { run() } label: { Label(String(localized: "Uruchom"), systemImage: "play.fill") }
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || running)
                if running { ProgressView().controlSize(.small) }
            }

            MonoOutput(text: output, minHeight: 220, maxHeight: 460)

            if !history.isEmpty {
                PanelSection(title: "Ostatnie komendy") {
                    ForEach(Array(history.prefix(8).enumerated()), id: \.offset) { _, h in
                        Button { command = h } label: {
                            Text(h).font(.caption.monospaced()).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }

            // Skróty do częstych akcji
            PanelSection(title: "Szybkie akcje") {
                WrapButtons(items: [
                    ("Miejsce na dyskach", "df -h"),
                    ("Kto zalogowany", "who"),
                    ("Obciążenie", "uptime"),
                    ("Procesy TOP", "ps -eo pid,%cpu,%mem,comm --sort=-%cpu | head"),
                    ("Magazyny", "pvesm status"),
                    ("Maszyny i kontenery", "qm list; pct list"),
                    ("Interfejsy sieci", "ip -br a"),
                    ("Temperatury", "sensors"),
                    ("Log jądra (koniec)", "dmesg | tail -n 30"),
                ]) { cmd in command = cmd; run() }
            }
        }
    }

    private func run() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        running = true
        if history.first != cmd { history.insert(cmd, at: 0) }
        Task {
            let r = await model.runCommand(cmd, sudo: useSudo)
            output = "$ \(useSudo ? "sudo " : "")\(cmd)\n\n" + r
            running = false
        }
    }
}

/// Zawijany rząd przycisków-skrótów.
private struct WrapButtons: View {
    let items: [(LocalizedStringKey, String)]  // etykieta tłumaczona, polecenie nie
    let action: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { action(item.1) } label: {
                    Text(item.0).font(.caption).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}
