import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Formatowanie wartości do wyświetlenia.
/// Co program mówi o sobie — czytane z pakietu, w którym faktycznie chodzi.
///
/// > [!important] Numeru NIE wpisujemy w kod
/// > Ręcznie wpisana wersja przeżywa build, który opisywała, i od tej chwili po cichu
/// > kłamie. `Bundle.main` mówi prawdę o tym, co się właśnie uruchomiło — także wtedy,
/// > gdy ktoś odpali starszą kopię z DerivedData obok nowej z Aplikacji.
///
/// `nil`, gdy kluczy nie ma: wtedy wiersz **znika**, zamiast pokazywać pustkę albo „—".
/// Zgłoszenie 2026-09-04: *„nigdzie nie ma informacji jaka jest aktualna wersja
/// programu"*.
enum Wersja {
    static var pelna: String? {
        let info = Bundle.main.infoDictionary
        guard let v = info?["CFBundleShortVersionString"] as? String,
              let b = info?["CFBundleVersion"] as? String else { return nil }
        return String(localized: "mNas \(v) (build \(b))")
    }

    /// Sam numer, bez nazwy i builda — do ciasnych miejsc, jak stopka panelu.
    static var krotka: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" }
    }
}

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    /// Krótka forma na małe kafle: „83,5 GB" zamiast pełnego opisu.
    static func shortBytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useGB, .useTB, .useMB]
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: value)
    }

    /// Prędkość w bajtach na sekundę → „12,4 MB/s".
    ///
    /// Poniżej kilobajta piszemy wprost `0 B/s`: `ByteCountFormatter` daje wtedy
    /// „Zero bajtów", co w kolumnie liczb wygląda na awarię formatowania.
    static func predkosc(_ bajtowNaSekunde: Double) -> String {
        guard bajtowNaSekunde >= 1024 else { return "0 B/s" }
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(bajtowNaSekunde)) + "/s"
    }

    static func uptime(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Pierwsza litera wielka — same dane serwera bywają całe małymi literami (np. „pve").
    static func titled(_ s: String?) -> String {
        guard let s, let f = s.first else { return "—" }
        return f.uppercased() + s.dropFirst()
    }
}

private struct ServiceAction: Identifiable {
    let id = UUID()
    let service: Service
    let start: Bool
}

/// Oczekujące potwierdzenie startu/stopu maszyny albo kontenera.
private struct GuestAction: Identifiable {
    let id = UUID()
    let guest: Guest
    let start: Bool
}

struct DashboardView: View {

    /// Tryb rysowania.
    ///
    /// > [!important] 🔴 Kafel w panelu paska menu to **ten sam widok**, nie jego kopia
    /// > Zgłoszenie po teście 1.0.39: *„chcę móc dodać 1:1 kafelek z pełnego ekranu"*.
    /// > Tryb `.panel` rysuje jedno `tileContent` i nic poza nim — bez siatki, nagłówka,
    /// > trybu układania i **bez arkuszy**: panel ma 340 × 400 pt i nie ma gdzie ich
    /// > otworzyć, a znika przy utracie skupienia. Kliknięcie w kafel w panelu nic więc
    /// > nie otwiera; od tego jest przycisk „Otwórz okno".
    enum Tryb: Equatable { case okno, panel }

    var tryb: Tryb = .okno
    /// Kafel do narysowania w trybie `.panel`.
    var kafelPanelu: DashTileID?
    /// Rozmiar tego kafla — `.large` na całą stronę, `.medium` na pół.
    var rozmiarPanelu: TileSize = .large

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showGPUSetup = false
    @State private var pendingService: ServiceAction?
    @State private var pendingGuest: GuestAction?
    @State private var confirmReboot = false

    // Panele funkcyjne — każdy kafelek po kliknięciu otwiera realne sterowanie/dane.
    @State private var showGPUPanel = false
    @State private var showFans = false
    @State private var showTerminal = false
    @State private var showOstrzezeniaDyskow = false
    @State private var selectedService: Service?

    // Układ siatki — kolejność, rozmiary i ukryte kafle ustawia user, zapisane trwale.
    // Trzyma go **model**, nie ten widok — uzasadnienie przy `AppModel.layout`.
    private var layout: DashboardLayout { model.layout }
    @State private var editingLayout = false
    /// Kafel trzymany w tej chwili palcem — sąsiedzi rozstępują się przed nim na żywo.
    @State private var draggingTile: DashTileID?

    // Kolory RAM (jak w TrueNAS)
    private let cFree = Color.green
    private let cZFS  = Color.purple
    private let cSvc  = Color.orange

    /// Alerty do pokazania: bez odrzuconych przez serwer i bez wyczyszczonych ręcznie.
    private var activeAlerts: [Alert] {
        model.alerts.filter { !($0.dismissed ?? false) && !layout.isAlertDismissed($0.id) }
    }

    /// Kafle, które mają co pokazać. Pusty kafel zajmowałby miejsce w siatce, więc
    /// znika sam — wraca w chwili, gdy dane się pojawią.
    private var visibleTiles: [DashTileID] {
        layout.order.filter { id in
            guard !layout.isHidden(id) else { return false }
            switch id {
            case .guests:    return !model.guests.isEmpty
            case .coreUsage: return !model.cpu.perCoreUsage.isEmpty
            case .coreTemp:  return !model.cpu.perCoreTemp.isEmpty
            case .gpu:       return model.gpu.name != nil || model.gpu.utilization != nil
            case .storage:   return !model.diskUsage.isEmpty
            case .disks:     return !model.disks.isEmpty
            case .services:  return !model.services.isEmpty
            case .tools:     return !model.webServices.isEmpty || model.discoveringServices
            case .alerts:    return !activeAlerts.isEmpty || layout.dismissedAlertCount > 0
            // Serwer bez RAPL (starsze AMD, maszyna wirtualna) nie ma czego pokazać.
            case .power:     return model.power.packageWatts != nil || model.power.gpuWatts != nil
            // Zanim cokolwiek się zgłosi, kafel nie ma czego pokazać — wraca sam,
            // gdy przyjdzie pierwsze zadanie, monitor Kumy albo wpis nocnej kopii.
            case .przebiegi: return !model.przebiegi.isEmpty
            // Miejsce pokazujemy dopiero, gdy serwer poda choć jeden punkt montowania
            // pod `/mnt` — pusty kafel z samym nagłówkiem nikomu nic nie mówi.
            case .miejsce:   return !model.udzialy.isEmpty
            // Pusty rejestr znaczy „nic się jeszcze nie wydarzyło przy włączonej apce" —
            // kafel wraca sam przy pierwszej zmianie stanu.
            //
            // 🔴 Ale rejestr wyczyszczony **ręcznie** to co innego niż nigdy niezapełniony:
            // kafel zostaje, bo inaczej przycisk „Wyczyść rejestr" kasował z ekranu sam
            // siebie. Zgłoszenie 2026-08-23, patrz `RejestrZdarzen.wyczyszczonoKiedy`.
            case .zdarzenia: return !model.rejestr.zdarzenia.isEmpty
                                  || model.rejestr.wyczyszczonoKiedy != nil
            // Kafel stoi także wtedy, gdy licznik na hoście milczy — bo „nie ma danych"
            // jest informacją, a pusty dashboard nią nie jest.
            case .transfery: return !model.strumienie.isEmpty || model.transferyZywe
                                    || !model.kopie.isEmpty || !model.przeplywyDyskow.isEmpty
            // Bez SSH nie ma czego czytać; brak narzędzia na serwerze to też informacja
            // (kafel proponuje instalację w oknie).
            case .aktualizacje: return model.aktualizacje != nil
            default:         return true
            }
        }
    }

    @ViewBuilder var body: some View {
        if tryb == .panel {
            panelKafla
        } else {
            oknoZArkuszami
        }
    }

    /// Jeden kafel na potrzeby panelu paska menu. Chrome kafla (tło, ramka, wypełnienie)
    /// robi `tile` w środku `tileContent`, więc tutaj zostaje samo rozciągnięcie do ramki,
    /// którą dał panel.
    ///
    /// > [!danger] 🔴 Tu NIE wolno owinąć kafla w `ThinScrollView`
    /// > Do 1.2.0 właśnie tak było — i to jedna linijka odpowiadała za zgłoszenie
    /// > z 2026-09-04: *„miejsce powinno być na sztywno i informacje przesuwać się
    /// > w oknie, a nie że ja przesuwam okno"*.
    /// >
    /// > Mechanizm: `ScrollView` proponuje dziecku **nieskończoną** wysokość. Kafle mają
    /// > własne `ThinScrollView` wokół list (Miejsce, Dyski, Usługi, Przebiegi…), ale
    /// > przy nieskończonej propozycji ich treść **zawsze się mieści**, więc wewnętrzne
    /// > przewijanie nigdy się nie włączało. Przewijał się cały kafel razem z nagłówkiem,
    /// > a lista jechała za ekran.
    /// >
    /// > Kafel dostaje teraz twardą ramkę strony. Wysokość jest skończona, listy
    /// > przewijają się w swoich miejscach, a nagłówek kafla stoi.
    @ViewBuilder private var panelKafla: some View {
        if let kafelPanelu {
            tileContent(kafelPanelu, rozmiarPanelu)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // 🔴 Margines liczy się razem z wypełnieniem kafla (4 pt).
                // Zgłoszenie 2026-09-04: *„informacje wchodzą na ramki okna"* —
                // przy panelu 340 pt szerokości długie wiersze („Intel(R) Core(TM)
                // i5-8500T CPU @ 2.10GHz", „0.8–3.5 GHz") dochodziły do samej krawędzi.
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var oknoZArkuszami: some View {
        pelnyDashboard
        .sheet(isPresented: $showGPUSetup) { GPUSetupView() }
        .sheet(isPresented: $showGPUPanel) { GPUPanel() }
        .sheet(isPresented: $showFans) { FanPanel() }
        .sheet(isPresented: $showTerminal) { TerminalPanel() }
        .sheet(isPresented: $showOstrzezeniaDyskow) { PanelOstrzezenDyskow() }
        .sheet(item: $selectedService) { ServicePanel(service: $0, displayName: serviceName($0.service)) }
        .alert("Potwierdź", isPresented: Binding(
            get: { pendingService != nil },
            set: { if !$0 { pendingService = nil } }
        ), presenting: pendingService) { act in
            Button(act.start ? "Uruchom" : "Zatrzymaj", role: act.start ? nil : .destructive) {
                Task { await model.setService(act.service.service, running: act.start) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { act in
            Text("\(act.start ? String(localized: "Uruchomić") : String(localized: "Zatrzymać")) usługę \(serviceName(act.service.service))?")
        }
        .alert("Potwierdź", isPresented: Binding(
            get: { pendingGuest != nil },
            set: { if !$0 { pendingGuest = nil } }
        ), presenting: pendingGuest) { act in
            Button(act.start ? "Uruchom" : "Zatrzymaj", role: act.start ? nil : .destructive) {
                Task { await model.setGuest(act.guest, running: act.start) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: { act in
            let what = "\(act.guest.kind.label.lowercased()) \(act.guest.vmid) (\(act.guest.name))"
            Text(act.start
                 ? "Uruchomić \(what)?"
                 : "Zatrzymać \(what)? mNas wysyła `shutdown`, czyli łagodne zamknięcie systemu gościa — nie odcina zasilania.")
        }
        .alert("Restart węzła", isPresented: $confirmReboot) {
            Button("Restart", role: .destructive) { Task { await model.rebootServer() } }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Zrestartować węzeł \(model.nodeName ?? model.host)? Zgaszone zostaną też WSZYSTKIE maszyny i kontenery, a połączenie zerwie się na czas restartu.")
        }
    }

    // MARK: - Zerwane połączenie

    /// Jawny komunikat, że liczby na kafelkach są zamrożone i apka właśnie wraca.
    /// Bez tego dashboard po zerwaniu wyglądał identycznie jak działający.
    private var reconnectBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Połączenie z serwerem zerwane — wracam sam.")
                    .font(.callout.weight(.semibold))
                Text(reconnectDetail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Rozłącz") { Task { await model.disconnect() } }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.45), lineWidth: 0.5))
    }

    private var reconnectDetail: String {
        var parts: [String] = []
        if model.reconnectAttempt > 0 {
            parts.append(String(localized: "Próba \(model.reconnectAttempt), odstęp \(model.reconnectDelay) s."))
        }
        parts.append(String(localized: "Kafelki pokazują dane \(freshnessText)."))
        return parts.joined(separator: " ")
    }

    /// „sprzed 12 s" / „z 14:32:07" — żeby było widać, jak stare są liczby na ekranie.
    private var freshnessText: String {
        guard let last = model.lastSuccessfulRefresh else { return String(localized: "sprzed połączenia") }
        let age = Int(Date().timeIntervalSince(last))
        if age < 90 { return String(localized: "sprzed \(max(age, 0)) s") }
        return String(localized: "z \(Self.clock.string(from: last))")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Nagłówek

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.titled(model.systemInfo?.hostname) == "—" ? model.host : Format.titled(model.systemInfo?.hostname))
                    .font(.title2.bold())
                if let version = model.systemInfo?.version {
                    Text(version).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // 🔴 Wiersz wyżej pokazuje wersję **Proxmoksa** (`systemInfo.version`), nie
            // programu — i dokładnie to mogło mylić. Wersja mNasa stoi osobno i jest
            // podpisana nazwą, żeby nie dało się wziąć jednej za drugą.
            if let v = Wersja.krotka {
                Text("mNas \(v)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(Wersja.pelna ?? v)
            }
            if let last = model.lastSuccessfulRefresh {
                Text("Odświeżono \(Self.clock.string(from: last))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Kiedy dane ostatnio faktycznie przyszły z serwera")
            }
            Button {
                showTerminal = true
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .tint(.primary)
            .help("Pełny dostęp do powłoki roota serwera — bez ograniczeń")

            Button {
                showGPUSetup = true
            } label: {
                Label("SSH", systemImage: model.gpuSSHEnabled ? "checkmark.circle.fill" : "terminal")
            }
            .help(model.gpuSSHEnabled ? "SSH aktywny — konfiguruj ponownie" : "Skonfiguruj dostęp SSH")
            Button {
                openWebPanel()
            } label: {
                Label("Panel", systemImage: "safari")
            }
            .help("Otwórz panel web Proxmoksa w przeglądarce")

            Toggle("Auto", isOn: Binding(
                get: { model.autoRefresh },
                set: { model.setAutoRefresh($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                confirmReboot = true
            } label: {
                Label("Restart", systemImage: "arrow.clockwise.circle")
            }
            .help("Zrestartuj serwer (z potwierdzeniem)")
            Button(role: .destructive) {
                Task { await model.disconnect() }
            } label: {
                Label("Rozłącz", systemImage: "power")
            }
            IkonaInstrukcji()
                .labelStyle(.iconOnly)
            PrzyciskUstawien()
                .labelStyle(.iconOnly)
        }
    }

    private var pelnyDashboard: some View {
        ThinScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if model.status == .reconnecting {
                    reconnectBanner
                } else if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                if let blad = model.bladAkcji {
                    HStack(alignment: .top, spacing: 8) {
                        Label(blad, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.bladAkcji = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Zamknij komunikat")
                    }
                    .padding(10)
                    .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }

                editBar
                if editingLayout { editHints }

                gridSection
            }
            .padding(16)
        }
    }

    // MARK: - Pasek trybu edycji układu

    private var editBar: some View {
        HStack(spacing: 8) {
            Label("Panel", systemImage: "square.grid.2x2")
                .font(.headline)
            Spacer()
            if editingLayout {
                if layout.hasLockedTiles {
                    Button("Odblokuj wszystkie") { withAnimation(.snappy) { layout.unlockAll() } }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.orange)
                        .help("Zdejmij kłódki ze wszystkich kafli naraz")
                }
                if layout.hasPinnedTiles {
                    Button("Ściśnij") { withAnimation(.snappy) { layout.repack() } }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Ułóż kafle ciasno, bez dziur. Kafle pod kłódką zostają na miejscu.")
                }
                Button("Resetuj układ") { layout.reset() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button {
                editingLayout.toggle()
            } label: {
                Label(editingLayout ? "Gotowe" : "Edytuj układ",
                      systemImage: editingLayout ? "checkmark" : "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder private var editHints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Przeciągnij kafel w dowolną kratkę — także w puste pole, dziury zostają. Przycisk rozmiaru przełącza Mały → Średni → Duży, oczko chowa kafel.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Kłódka przygważdża kafel do jego pola: nie da się go złapać i **nie ustąpi** miejsca innym. Upuszczenie czegoś na zablokowane pole nie dochodzi do skutku, zamiast przepychać kafle dalej.")
                .font(.caption2).foregroundStyle(.secondary)
            if !layout.hidden.isEmpty {
                HStack(spacing: 6) {
                    Text("Schowane:").font(.caption2).foregroundStyle(.secondary)
                    ForEach(layout.hidden, id: \.self) { id in
                        Button {
                            layout.show(id)
                        } label: {
                            Label(id.title, systemImage: "eye")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    // MARK: - Siatka

    /// Siatka razem z obsługą upuszczania. Delegat wisi na całości, żeby dało się
    /// upuścić kafel także w puste pole — a nie tylko na inny kafel.
    private var gridSection: some View {
        let tiles = visibleTiles
        let placements = layout.resolvedPositions(tiles)
        return TileGrid(extraRows: editingLayout ? 2 : 0) {
            ForEach(tiles, id: \.self) { id in
                renderTile(id, placements[id] ?? GridPos(col: 0, row: 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        // Liczbę kolumn zna tylko widok — model potrzebuje jej do liczenia kratek.
        //
        // 🔴 Utrwalanie pozycji siedzi **tutaj**, a nie w `.task`, bo `firstFree` liczy
        // z `columns`. Zapisanie układu przed zmierzeniem szerokości okna zamroziłoby go
        // na domyślnych czterech kolumnach — niezależnie od tego, jak szerokie jest okno.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            layout.ustawKolumny(Int((width + TileGeometry.gap) / (TileGeometry.cell + TileGeometry.gap)))
            layout.utrwalPozycje(tiles)
        }
        // Kafle pojawiają się pojedynczo, w miarę jak dane napływają z serwera. Każdy nowy
        // dostaje miejsce i **od razu je zapamiętuje** — inaczej przy następnym starcie
        // byłby układany od zera i przesuwał wszystko, co stoi za nim.
        .onChange(of: tiles) { _, nowe in
            layout.utrwalPozycje(nowe)
        }
        .onDrop(of: [.text],
                delegate: GridDropDelegate(layout: layout, tiles: tiles, dragging: $draggingTile))
    }

    // MARK: - Router kafli + sterowanie w trybie edycji

    @ViewBuilder private func renderTile(_ id: DashTileID, _ pos: GridPos) -> some View {
        let size = layout.size(id)
        let base = tileContent(id, size)
            .tileFrame(size)
            .overlay(alignment: .topTrailing) {
                if editingLayout { editControls(id, size) }
            }

        Group {
            if editingLayout && !layout.isLocked(id) {
                base
                    // Przeciągany kafel blednie, żeby było widać, który jest „w ręce".
                    .opacity(draggingTile == id ? 0.35 : 1)
                    .onDrag {
                        draggingTile = id
                        return NSItemProvider(object: id.rawValue as NSString)
                    }
            } else {
                // Bez `onDrag`: kafel pod kłódką nie daje się nawet złapać. Sama obwódka
                // nie wystarczy — uchwyt, który pozwala złapać i nic nie robi, czyta się
                // jak zacięcie programu, a nie jak blokada.
                base
            }
        }
        .overlay {
            if editingLayout && layout.isLocked(id) {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.orange, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .tilePlacement(pos, size)
    }

    @ViewBuilder private func tileContent(_ id: DashTileID, _ size: TileSize) -> some View {
        switch id {
        case .cpu:        cpuTile(size)
        case .ram:        memoryTile(size)
        case .guests:     guestsTile(size)
        case .cpuHistory: cpuRecentTile(size)
        case .coreUsage:  coreUsageTile(size)
        case .coreTemp:   coreTempTile(size)
        case .gpu:        gpuTile(size)
        case .fans:       fansTile(size)
        case .storage:    storageTile(size)
        case .disks:      disksTile(size)
        case .services:   servicesTile(size)
        case .alerts:     alertsTile(size)
        case .tools:      toolsTile(size)
        case .power:      powerTile(size)
        case .przebiegi:  przebiegiTile(size)
        case .miejsce:    miejsceTile(size)
        case .zdarzenia:  zdarzeniaTile(size)
        case .transfery:  transferyTile(size)
        case .aktualizacje: aktualizacjeTile(size)
        }
    }

    private func editControls(_ id: DashTileID, _ size: TileSize) -> some View {
        let zablokowany = layout.isLocked(id)
        return HStack(spacing: 4) {
            Button { layout.cycleSize(id) } label: {
                Text(size.label).font(.caption2.weight(.bold))
            }
            .help("Zmień rozmiar kafla")
            // Kłódka — kafel zostaje na swoim polu i nie ustępuje przy przeciąganiu
            // innych. Zgłoszenie 2026-08-23. Patrz `DashboardLayout.place`.
            Button {
                withAnimation(.snappy) { layout.toggleLock(id, among: visibleTiles) }
            } label: {
                Image(systemName: zablokowany ? "lock.fill" : "lock.open")
            }
            .tint(zablokowany ? .orange : nil)
            .help(zablokowany
                  ? "Odblokuj — kafel znów będzie się przesuwał"
                  : "Zablokuj kafel w tym miejscu")
            Button { layout.hide(id) } label: {
                Image(systemName: "eye.slash")
            }
            .help("Schowaj kafel")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.mini)
        .padding(6)
    }

    // MARK: - CPU

    @ViewBuilder private func cpuTile(_ size: TileSize) -> some View {
        let usage = model.cpuUsagePercent
        tile(size) {
            head("CPU", "cpu", .blue, size,
                 trailing: model.cpuUsageApprox ? String(localized: "przybliżone") : nil, chevron: size != .small)
            switch size {
            case .small:
                // Pierścień z procentem wchodzi tu bez problemu — sama liczba
                // marnowała kafel (uwaga 2026-08-17).
                HStack { Spacer(); cpuRing(usage, diameter: 84); Spacer() }
            case .medium:
                HStack(spacing: 12) {
                    cpuRing(usage, diameter: 92)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.systemInfo?.model ?? "—")
                            .font(.caption2.weight(.semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        infoRow("Rdzenie", model.systemInfo?.cores.map(String.init) ?? "—")
                        infoRow("Uptime", Format.uptime(model.systemInfo?.uptimeSeconds))
                        if let t = model.cpu.packageTemp { infoRow("Temperatura", "\(Int(t.rounded()))°C") }
                    }
                }
            case .large:
                HStack(alignment: .top, spacing: wPanelu ? 10 : 12) {
                    cpuRing(usage, diameter: wPanelu ? 74 : 96)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.systemInfo?.model ?? "—")
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        infoRow("Rdzenie / wątki", coresAndThreads)
                        if let d = model.cpuDetails {
                            if let s = d.sockets, s > 1 { infoRow("Gniazda", "\(s)") }
                            if let max = d.maxMHz {
                                infoRow("Taktowanie", clockRange(min: d.minMHz, max: max))
                            }
                            if let l3 = d.l3 { infoRow("Cache L3", l3) }
                            if let l2 = d.l2 { infoRow("Cache L2", l2) }
                            if let arch = d.architecture { infoRow("Architektura", arch) }
                        }
                        if let t = model.cpu.packageTemp { infoRow("Temperatura", "\(Int(t.rounded()))°C") }
                        infoRow("Obciążenie", loadText)
                        infoRow("Uptime", Format.uptime(model.systemInfo?.uptimeSeconds))
                    }
                }
                // Reszta wysokości idzie na rdzenie — wcześniej było tu 150 pt pustki.
                if !model.cpu.perCoreUsage.isEmpty {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        CoreUsageBars(values: model.cpu.perCoreUsage,
                                      barWidth: 14, barSpacing: 5, maxBarHeight: 40)
                        Spacer()
                    }
                }
                hint("Kliknij: procesy, rdzenie, temperatury")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoPaneluTrwalego.id, value: OknoPaneluTrwalego.Cel.cpu) } }
    }

    /// „6 / 6" — rdzenie fizyczne i wątki. Gdy nie ma jeszcze `lscpu`, zostaje sama
    /// liczba z API, żeby kafel nie świecił myślnikiem przez pierwsze sekundy.
    private var coresAndThreads: String {
        let cores = model.systemInfo?.cores ?? model.cpuDetails.flatMap { d in
            guard let c = d.coresPerSocket, let s = d.sockets else { return nil }
            return c * s
        }
        guard let threads = model.cpuDetails?.threads else {
            return cores.map(String.init) ?? "—"
        }
        guard let cores else { return String(localized: "\(threads) wątk.") }
        return "\(cores) / \(threads)"
    }

    /// „0,42 · 0,38 · 0,31" — trzy okna średniej z `loadavg`.
    private var loadText: String {
        guard let load = model.systemInfo?.loadavg, !load.isEmpty else { return "—" }
        return load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " · ")
    }

    private func clockRange(min: Double?, max: Double) -> String {
        let top = String(format: "%.1f GHz", max / 1000)
        guard let min, min > 0 else { return top }
        return String(format: "%.1f–", min / 1000) + top
    }

    /// Pierścień użycia CPU — jeden kod na trzy rozmiary, bo różni je tylko średnica.
    private func cpuRing(_ usage: Double?, diameter: CGFloat) -> some View {
        let line = max(9, diameter * 0.12)
        return Group {
            if let u = usage {
                DonutChart(
                    segments: [
                        DonutSegment(value: u, color: usageColor(u, base: .blue), label: "used"),
                        DonutSegment(value: max(0, 100 - u), color: .clear, label: "free")
                    ],
                    centerTitle: "\(Int(u.rounded()))%",
                    centerCaption: "Użycie",
                    diameter: diameter, lineWidth: line
                )
            } else {
                DonutChart(segments: [DonutSegment(value: 1, color: Color.gray.opacity(0.3), label: "?")],
                           centerTitle: "—", centerCaption: "Użycie",
                           diameter: diameter, lineWidth: line)
            }
        }
    }

    // MARK: - RAM

    @ViewBuilder private func memoryTile(_ size: TileSize) -> some View {
        let total = model.memory.total
        tile(size) {
            head("Pamięć RAM", "memorychip", .green, size, chevron: size != .small)
            switch size {
            case .small:
                // Pierścień z rozbiciem zamiast samej liczby — widać od razu,
                // ile pamięci jest zajętej, a nie tylko ile jej kupiono.
                HStack {
                    Spacer()
                    if model.memory.hasBreakdown {
                        DonutChart(segments: memorySegments(),
                                   centerTitle: memNumber(total),
                                   centerCaption: "\(memUnit(total))",
                                   diameter: 84, lineWidth: 12)
                    } else {
                        bigValue("\(memNumber(total)) \(memUnit(total))", "zainstalowane")
                    }
                    Spacer()
                }
            case .medium:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(memNumber(total)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                            Text(memUnit(total)).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.memory.hasBreakdown {
                            legendRow(cFree, "Wolne", model.memory.free)
                            legendRow(cZFS, "Cache ZFS", model.memory.zfsCache)
                            legendRow(cSvc, "Usługi", model.memory.services)
                        } else {
                            Text("zainstalowane łącznie").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.memory.hasBreakdown {
                        DonutChart(segments: memorySegments(), diameter: 96, lineWidth: 16)
                    }
                }
            case .large:
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(memNumber(total)).font(.system(size: 28, weight: .bold)).monospacedDigit()
                            Text(memUnit(total)).font(.callout).foregroundStyle(.secondary)
                        }
                        if model.memory.hasBreakdown {
                            legendRow(cFree, "Wolne", model.memory.free)
                            legendRow(cZFS, "Cache ZFS", model.memory.zfsCache)
                            legendRow(cSvc, "Usługi", model.memory.services)
                        } else {
                            Text("Rozbicie pojawi się po odczycie SSH.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.memory.hasBreakdown {
                        DonutChart(segments: memorySegments(), diameter: 88, lineWidth: 16)
                    }
                }
                if !guestsWithMemory.isEmpty {
                    Divider().padding(.vertical, 1)
                    HStack(spacing: 4) {
                        Text("Przydział maszyn").font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        // Suma przydziałów bywa większa niż fizyczny RAM — Proxmox na to
                        // pozwala (nadsubskrypcja) i wtedy liczba robi się pomarańczowa.
                        Text("\(Format.shortBytes(allocatedToGuests)) z \(Format.shortBytes(total))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(overcommitted ? .orange : .secondary)
                    }
                    ThinScrollView {
                        VStack(spacing: 3) {
                            ForEach(guestsWithMemory) { guestMemoryRow($0) }
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                    hint("Kliknij: procesy zajmujące RAM")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoPaneluTrwalego.id, value: OknoPaneluTrwalego.Cel.ram) } }
    }

    /// Goście z przydzieloną pamięcią — zgaszone też, bo przydział zajmuje pulę
    /// w chwili uruchomienia, a nie dopiero wtedy, gdy zostanie zużyty.
    private var guestsWithMemory: [Guest] {
        model.guests.filter { ($0.memoryTotal ?? 0) > 0 }
    }

    private var allocatedToGuests: Int64 {
        guestsWithMemory.reduce(0) { $0 + ($1.memoryTotal ?? 0) }
    }

    /// Przydzielono maszynom więcej, niż węzeł ma fizycznie.
    private var overcommitted: Bool {
        guard let total = model.memory.total, total > 0 else { return false }
        return allocatedToGuests > total
    }

    /// Wiersz przydziału RAM: ile maszyna dostała i ile z tego naprawdę zajmuje.
    private func guestMemoryRow(_ guest: Guest) -> some View {
        let used = guest.running ? (guest.memoryUsed ?? 0) : 0
        let total = guest.memoryTotal ?? 0
        let frac = total > 0 ? Double(used) / Double(total) : 0
        let tint: Color = frac > 0.9 ? .red : (frac > 0.75 ? .orange : .green)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: guest.kind.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(guest.running ? .green : .secondary)
                Text(guest.name).font(.caption2.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(guest.running
                     ? "\(Format.shortBytes(used)) z \(Format.shortBytes(total))"
                     : "\(Format.shortBytes(total)) · zgaszona")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(guest.running ? tint : Color.secondary.opacity(0.4))
                        .frame(width: max(1, geo.size.width * (guest.running ? frac : 0)))
                }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Maszyny i kontenery
    //
    // Kafel, którego wersja pod TrueNAS-a nie miała. Na serwerze wirtualizacyjnym to
    // najważniejsza informacja na ekranie: ile gości stoi, ile chodzi i który zjada CPU.

    @ViewBuilder private func guestsTile(_ size: TileSize) -> some View {
        let running = model.guests.filter(\.running).count
        tile(size) {
            head("Maszyny i kontenery", "square.stack.3d.up", .indigo, size,
                 trailing: "\(running)/\(model.guests.count)")
            switch size {
            case .small:
                // Liczba + pasek stanu: zielone = chodzi, szare = zgaszone.
                bigValue("\(running)/\(model.guests.count)", "działa",
                         color: running == 0 ? .secondary : .indigo)
                guestStrip
            case .medium:
                guestStrip
                listaKafla(model.guests, wOknie: 3) { guestRow($0, dense: true) }
            case .large:
                ThinScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.guests) { guest in guestRow(guest, dense: false) }
                    }
                }
            }
        }
    }

    /// Pasek stanu gości — jeden słupek na maszynę, zielony = chodzi.
    private var guestStrip: some View {
        HStack(spacing: 3) {
            ForEach(model.guests) { guest in
                RoundedRectangle(cornerRadius: 2)
                    .fill(guest.running ? Color.green : Color.secondary.opacity(0.3))
                    .frame(height: 8)
                    .help("\(guest.vmid) · \(guest.name)")
            }
        }
    }

    private func guestRow(_ guest: Guest, dense: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: guest.kind.symbol)
                .foregroundStyle(guest.running ? .green : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(guest.name).font(.caption.weight(.medium)).lineLimit(1)
                if !dense {
                    Text("\(guest.kind.label) \(guest.vmid)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if guest.running {
                VStack(alignment: .trailing, spacing: 1) {
                    if let cpu = guest.cpuPercent {
                        Text("\(String(format: "%.1f", cpu))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(usageColor(cpu))
                    }
                    if let mem = guest.memoryPercent, !dense {
                        Text("RAM \(Int(mem.rounded()))%")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("zgaszona").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, dense ? 1 : 3)
        .contentShape(Rectangle())
        // Start/stop maszyny to zmiana stanu serwera — zawsze przez potwierdzenie,
        // nigdy jednym kliknięciem w kafel.
        .contextMenu {
            Button(guest.running ? "Zatrzymaj (shutdown)" : "Uruchom") {
                pendingGuest = GuestAction(guest: guest, start: !guest.running)
            }
        }
    }

    // MARK: - Wykres CPU w czasie

    @ViewBuilder private func cpuRecentTile(_ size: TileSize) -> some View {
        let last = model.cpuHistory.last
        tile(size) {
            head("CPU w czasie", DashTileID.cpuHistory.ikona, DashTileID.cpuHistory.kolor, size,
                 trailing: last.map { "\(Int($0.rounded()))%" })
            HStack(alignment: .bottom, spacing: 4) {
                if size == .large {
                    VStack { Text("100"); Spacer(); Text("0") }
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Sparkline(points: model.cpuHistory.isEmpty ? [0, 0] : model.cpuHistory,
                          tint: .blue, upperBound: 100)
                    .frame(height: size == .large ? 190 : (size == .medium ? 76 : 62))
            }
            // Na małym też jest miejsce na jedną linijkę podpisu — bez niej wykres
            // wisiał w próżni i nie było wiadomo, jaka jest skala.
            hint(size == .small
                 ? "\(model.cpuHistory.count) pom. · 0–100%"
                 : "\(model.cpuHistory.count) pomiarów · skala 0–100%")
        }
        // Okno historii (od 1.2.13). Ponowny klik wyciąga to samo okno, nie otwiera drugiego.
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoHistorii.id, value: DashTileID.cpuHistory) } }
    }

    // MARK: - Rdzenie

    @ViewBuilder private func coreUsageTile(_ size: TileSize) -> some View {
        let values = model.cpu.perCoreUsage
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        tile(size) {
            head("Zużycie rdzeni", "cpu", .blue, size, trailing: String(localized: "\(Int(avg.rounded()))% śr."))
            switch size {
            case .small:
                // Sześć wąskich słupków mieści się w 124 pt — sama średnia była
                // stratą kafla (uwaga 2026-08-17).
                HStack {
                    Spacer()
                    CoreUsageBars(values: values, barWidth: 10, barSpacing: 4,
                                  maxBarHeight: 66, showLabels: false)
                    Spacer()
                }
                Text("\(values.count) rdzeni").font(.caption2).foregroundStyle(.secondary)
            case .medium:
                HStack { Spacer(); CoreUsageBars(values: values); Spacer() }
            case .large:
                HStack {
                    Spacer()
                    CoreUsageBars(values: values, barWidth: 26, barSpacing: 10, maxBarHeight: 190)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder private func coreTempTile(_ size: TileSize) -> some View {
        let temps = model.cpu.perCoreTemp
        let maxT = temps.max() ?? 0
        tile(size) {
            head("Temp. rdzeni", DashTileID.coreTemp.ikona, DashTileID.coreTemp.kolor, size,
                 trailing: "max \(Int(maxT.rounded()))°")
            switch size {
            case .small:
                HStack {
                    Spacer()
                    CoreTempBars(temps: temps, barWidth: 10, barSpacing: 4,
                                 maxBarHeight: 66, showLabels: false)
                    Spacer()
                }
                Text("max \(Int(maxT.rounded()))°C z \(temps.count)")
                    .font(.caption2).foregroundStyle(.secondary)
            case .medium:
                HStack { Spacer(); CoreTempBars(temps: temps); Spacer() }
            case .large:
                HStack {
                    Spacer()
                    CoreTempBars(temps: temps, barWidth: 26, barSpacing: 10, maxBarHeight: 190)
                    Spacer()
                }
            }
        }
        // Okno historii (od 1.2.13). Ponowny klik wyciąga to samo okno, nie otwiera drugiego.
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoHistorii.id, value: DashTileID.coreTemp) } }
    }

    // MARK: - Wentylatory

    @ViewBuilder private func fansTile(_ size: TileSize) -> some View {
        tile(size) {
            head("Wentylatory", "fanblades", .mint, size, chevron: size != .small)
            if model.fans.isEmpty {
                if size == .small {
                    bigValue("—", "brak odczytu", color: .secondary)
                } else {
                    // Nie obiecujemy, że „wystarczy lm-sensors": na serwerze testowym (mini PC)
                    // zmierzono 2026-08-17, że układ Super I/O siedzi pod
                    // niestandardowym portem 0x164e, żaden sterownik hwmon tam nie zagląda,
                    // a dostęp do kontrolera EC blokuje Secure Boot. Szczegóły w panelu.
                    Text("Serwer nie wystawia obrotów — w hwmon nie ma ani jednego wejścia fanX. Kliknij: diagnostyka i próba podpięcia modułu.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    // Podpis bierze numer z czujnika (`fanN_input`), nie pozycję w tablicy —
                    // inaczej „Fan 2" w UI nie musiałoby być tym samym wentylatorem co `pwm2`.
                    ForEach(model.fans) { fan in
                        VStack(spacing: 4) {
                            SpinningFan(rpm: fan.rpm)
                                .foregroundStyle(fan.rpm > 0 ? Color.mint : Color.secondary)
                            Text("\(Int(fan.rpm.rounded()))")
                                .font(.callout.monospacedDigit().weight(.medium))
                            if size != .small {
                                Text("RPM · Fan \(fan.index)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if size == .large { hint("Kliknij: ustaw prędkość (PWM)") }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { showFans = true } }
    }

    // MARK: - GPU

    @ViewBuilder private func gpuTile(_ size: TileSize) -> some View {
        tile(size) {
            head("GPU", "display", .purple, size, chevron: size != .small)
            if size == .small {
                if let u = model.gpu.utilization {
                    HStack {
                        Spacer()
                        DonutChart(
                            segments: [
                                DonutSegment(value: u, color: usageColor(u, base: .purple), label: "used"),
                                DonutSegment(value: max(0, 100 - u), color: .clear, label: "free")
                            ],
                            centerTitle: "\(Int(u.rounded()))%",
                            centerCaption: "Użycie",
                            diameter: 84, lineWidth: 10
                        )
                        Spacer()
                    }
                } else {
                    bigValue("—", "brak metryk")
                    Text(model.gpu.name ?? "—")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                if let u = model.gpu.utilization {
                    HStack {
                        Spacer()
                        DonutChart(
                            segments: [
                                DonutSegment(value: u, color: usageColor(u, base: .purple), label: "used"),
                                DonutSegment(value: max(0, 100 - u), color: .clear, label: "free")
                            ],
                            centerTitle: "\(Int(u.rounded()))%",
                            centerCaption: "Użycie",
                            // W panelu pierścień jest mniejszy: 120 pt przy szerokości
                            // 340 pt zabierało miejsce opisom obok i wypychało je na ramkę.
                            diameter: size == .large ? (wPanelu ? 92 : 120) : 84,
                            lineWidth: size == .large ? (wPanelu ? 12 : 14) : 11
                        )
                        Spacer()
                    }
                }
                Text(model.gpu.name ?? "—")
                    .font(.caption.weight(.medium))
                    .lineLimit(size == .large ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: size == .large)
                if size == .large {
                    if let t = model.gpu.temperature {
                        Label("\(Int(t.rounded()))°C", systemImage: "thermometer.medium")
                            .font(.caption).foregroundStyle(gpuTempColor(t))
                    }
                    if let mu = model.gpu.memoryUsed, let mt = model.gpu.memoryTotal, mt > 0 {
                        infoRow("Pamięć GPU", "\(Int(mu)) / \(Int(mt)) MiB")
                    }
                    if let p = model.gpu.powerWatts {
                        infoRow("Pobór", String(format: "%.0f W", p))
                    }
                    Spacer(minLength: 0)
                    if model.gpu.utilization == nil && model.gpu.temperature == nil {
                        Text("Nazwa karty jest — brak metryk. Kliknij, żeby zdiagnozować sterownik NVIDIA.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        hint("Kliknij: procesy na GPU, diagnostyka")
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { showGPUPanel = true } }
    }

    private func gpuTempColor(_ t: Double) -> Color { t >= 80 ? .red : (t >= 65 ? .orange : .green) }

    // MARK: - Pamięć masowa — nośniki fizyczne z zajętością
    //
    // Do 2026-08-19 kafel pokazywał **magazyny Proxmoksa** (`local`, `local-lvm`,
    // `aplikacje`, `multimedia`). To nie to samo co dyski i dawało dwa fałsze naraz: dysk,
    // który nie jest magazynem, nie istniał w programie (na serwerze testowym `/mnt/zasoby`,
    // 822 GB zajęte), a dwa magazyny na jednym NVMe wyglądały jak dwa nośniki.
    // Teraz kafel odpowiada na pytanie, które się przy nim zadaje: **który dysk
    // i w ilu procentach jest zajęty**. Koło pokazuje sumę wszystkich nośników.

    @ViewBuilder private func storageTile(_ size: TileSize) -> some View {
        let noSniki = storageRows
        let sumaZajete = noSniki.reduce(Int64(0)) { $0 + $1.usage.used }
        let sumaCalosc = noSniki.reduce(Int64(0)) { $0 + $1.usage.capacity }
        let frakcja = sumaCalosc > 0 ? Double(sumaZajete) / Double(sumaCalosc) : 0
        tile(size) {
            head("Pamięć masowa", "cylinder.split.1x2", .teal, size, trailing: "\(noSniki.count)")
            switch size {
            case .small:
                HStack {
                    Spacer()
                    ArcGauge(fraction: frakcja,
                             centerTitle: "\(Int((frakcja * 100).rounded()))%",
                             centerCaption: "\(noSniki.count) dysków",
                             tint: arcTint(frakcja),
                             diameter: 86, lineWidth: 9)
                    Spacer()
                }
            case .medium:
                if wPanelu {
                    ThinScrollView {
                        VStack(spacing: 4) {
                            ForEach(noSniki, id: \.key) { storageRow($0) }
                        }
                    }
                } else {
                    VStack(spacing: 4) {
                        ForEach(noSniki.prefix(3), id: \.key) { storageRow($0) }
                    }
                    if noSniki.count > 3 { moreLine(noSniki.count - 3) }
                }
            case .large:
                HStack {
                    Spacer()
                    ArcGauge(fraction: frakcja,
                             centerTitle: "\(Int((frakcja * 100).rounded()))%",
                             centerCaption: "\(Format.shortBytes(sumaZajete)) z \(Format.shortBytes(sumaCalosc))",
                             tint: arcTint(frakcja),
                             diameter: 104, lineWidth: 11)
                    Spacer()
                }
                ThinScrollView {
                    VStack(spacing: 4) {
                        ForEach(noSniki, id: \.key) { storageRow($0) }
                    }
                }
            }
        }
    }

    /// Nośniki do pokazania: wszystkie dyski fizyczne, posortowane po nazwie urządzenia.
    /// Model bierzemy z listy dysków API, żeby wiersz mówił „SSD NVME1000-C", a nie
    /// samo `nvme0n1`.
    private var storageRows: [(key: String, model: String?, usage: DiskUsage)] {
        model.diskUsage
            .sorted { $0.key < $1.key }
            .map { wpis in
                (key: wpis.key,
                 model: model.disks.first { dysk in dysk.name == wpis.key }?.model,
                 usage: wpis.value)
            }
    }

    /// Wiersz nośnika: nazwa, pasek, „zajęte z całości" i procent.
    private func storageRow(_ row: (key: String, model: String?, usage: DiskUsage)) -> some View {
        let u = row.usage
        let frac = u.fraction ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: u.transport == "usb" ? "externaldrive" : "internaldrive")
                    .font(.caption2).foregroundStyle(.teal)
                Text(row.model ?? row.key).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(u.isMeasured ? "\(Int((frac * 100).rounded()))%" : "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(u.isMeasured ? Color.primary : Color.secondary)
            }
            if u.isMeasured {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(arcTint(frac))
                            .frame(width: max(2, geo.size.width * frac))
                    }
                }
                .frame(height: 4)
                Text("\(Format.shortBytes(u.used)) z \(Format.shortBytes(u.capacity)) · \(row.key)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                // Nośnik bez zamontowanego systemu plików — zero bajtów byłoby nieprawdą.
                Text("\(row.key) · niezamontowany")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func arcTint(_ frac: Double) -> Color {
        frac > 0.9 ? .red : (frac > 0.75 ? .orange : .teal)
    }

    // MARK: - Miejsce — udziały i magazyny, liczone z wartości
    //
    // Kafel powstał 2026-08-23 ze zgłoszenia. Przedtem jedyną informacją o miejscu
    // była linijka w kaflu „Przebiegi”:
    //   `/mnt/zasoby 78%,/mnt/wspolny 2% / mnt/multimedia 11%,/mnt/backup 9%`
    // — czyli **treść powiadomienia push**, sklejana przez czujkę na hoście. Tutaj
    // te same cztery liczby biorą się z `df`, a nazwy z konfiguracji serwera.
    //
    // 🔴 `Media` (udział sieciowy) i `media` (magazyn Proxmoksa) to **dwie połówki
    // jednego dysku** i nazywają się prawie tak samo. Dlatego każdy wiersz niesie też
    // rodzaj — bez niego te dwa wiersze są nie do rozróżnienia.

    @ViewBuilder private func miejsceTile(_ size: TileSize) -> some View {
        let lista = model.udzialy
        let pelne = lista.filter(\.przekroczylProg)
        tile(size) {
            head("Miejsce", "externaldrive.connected.to.line.below", .indigo, size,
                 trailing: "\(lista.count)")
            switch size {
            case .small:
                // Najpełniejszy stoi pierwszy — `Miejsce.udzialy` sortuje po procencie.
                if let szczyt = lista.first {
                    bigValue("\(szczyt.procent)%", "\(szczyt.nazwa)",
                             color: tintZajetosci(szczyt.procent))
                    Text("\(Format.shortBytes(szczyt.wolne)) wolnego")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            case .medium:
                listaKafla(lista, wOknie: 3) { udzialRow($0) }
            case .large:
                if pelne.isEmpty {
                    Text(String(localized: "Żaden nie przekracza \(Miejsce.progZajetosci)% — progu ostrzeżenia."))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("\(pelne.count) powyżej \(Miejsce.progZajetosci)%: \(pelne.map(\.nazwa).joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ThinScrollView {
                    VStack(spacing: 4) {
                        ForEach(lista) { udzialRow($0) }
                    }
                }
            }
        }
        // Od 1.2.16: historia zajętości i zapisów na dyski. Zgłoszenie 2026-10-04.
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoHistorii.id, value: DashTileID.miejsce) } }
    }

    /// Wiersz miejsca: nazwa ludzka, rodzaj, pasek i „zajęte z całości".
    ///
    /// Ścieżki `/mnt/…` tu **nie ma** świadomie — użytkownik wybrał 2026-08-23 nazwy udziałów,
    /// czyli to, co widać w Finderze. Ścieżka wraca w podpowiedzi pod kursorem, żeby
    /// dało się ją sprawdzić, gdy naprawdę jest potrzebna.
    private func udzialRow(_ u: Udzial) -> some View {
        let frac = Double(u.procent) / 100
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: ikonaUdzialu(u.rodzaj))
                    .font(.caption2).foregroundStyle(.indigo)
                Text(u.nazwa).font(.caption.weight(.semibold)).lineLimit(1)
                Text(u.rodzaj.etykieta)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(u.procent)%")
                    .font(.caption2.monospacedDigit().weight(u.przekroczylProg ? .bold : .regular))
                    .foregroundStyle(tintZajetosci(u.procent))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tintZajetosci(u.procent))
                        .frame(width: max(2, geo.size.width * frac))
                }
            }
            .frame(height: 4)
            Text("\(Format.shortBytes(u.zajete)) z \(Format.shortBytes(u.calosc)) · \(Format.shortBytes(u.wolne)) wolnego")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
        .help(String(localized: "\(u.sciezka) — próg ostrzeżenia \(Miejsce.progZajetosci)%"))
    }

    /// Ten sam próg co czujka na serwerze (`PROG_PROCENT=90`), plus wcześniejsze
    /// pomarańczowe uprzedzenie — czerwień ma znaczyć „już", nie „zaraz".
    private func tintZajetosci(_ procent: Int) -> Color {
        procent >= Miejsce.progZajetosci ? .red : (procent >= 75 ? .orange : .indigo)
    }

    private func ikonaUdzialu(_ rodzaj: NazwaMontowania.Rodzaj) -> String {
        switch rodzaj {
        case .udzial:  return "externaldrive.connected.to.line.below"
        case .magazyn: return "shippingbox"
        case .katalog: return "folder"
        }
    }

    // MARK: - Zdarzenia — historia, nie stan
    //
    // Kafel powstał 2026-08-23 ze zgłoszenia: *„dostaje ikonka powiadomienia, ale jak
    // otworzę okno to powiadomienie znika i generalnie nie wiem co się dzieje"*.
    //
    // 🔴 To **nie jest** druga lista przebiegów. „Przebiegi" pokazują stan **teraz**,
    // ten kafel — **co się wydarzyło**. Przebieg, który przeszedł przez błąd i wrócił
    // do „udany", w tamtym kaflu wygląda jak taki, który po prostu się udał.

    @ViewBuilder private func zdarzeniaTile(_ size: TileSize) -> some View {
        let lista = model.rejestr.zdarzenia
        let alarmy = lista.filter { $0.stan.alarmujacy }
        tile(size) {
            head("Zdarzenia", "list.bullet.rectangle", .purple, size, trailing: "\(lista.count)")
            switch size {
            case .small:
                if let ostatnie = lista.first {
                    bigValue(Self.godzinaZdarzenia.string(from: ostatnie.czas), "\(ostatnie.nazwa)",
                             color: kolorStanu(ostatnie.stan))
                    Text(ostatnie.jednymZdaniem)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    pustyRejestr
                }
            case .medium:
                if lista.isEmpty {
                    pustyRejestr
                } else {
                    listaKafla(lista, wOknie: 4) { zdarzenieRow($0, pelny: false) }
                }
            case .large:
                if !alarmy.isEmpty {
                    Text("\(alarmy.count) z ostatnich \(lista.count) to błąd albo cisza.")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if lista.isEmpty {
                    pustyRejestr
                } else {
                    ThinScrollView {
                        VStack(spacing: 4) {
                            ForEach(lista) { zdarzenieRow($0, pelny: true) }
                        }
                    }
                }
                // Rejestr czyści się **wyłącznie stąd**. Zgaszenie chmurki przy ikonie
                // znaczy „przeczytane", nie „usunięte" — o to poszło zgłoszenie.
                Button("Wyczyść rejestr") { model.rejestr.wyczysc() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .disabled(editingLayout || lista.isEmpty)
            }
        }
        // Od 1.2.16: okno z pełnym rejestrem, wyszukiwaniem i filtrem — jak Przebiegi.
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoPaneluTrwalego.id, value: OknoPaneluTrwalego.Cel.zdarzenia) } }
    }

    /// Co pokazać, gdy rejestr jest pusty.
    ///
    /// Rozróżnia dwa różne „nic tu nie ma": *jeszcze* nic się nie wydarzyło, a *już*
    /// wyczyszczone ręcznie. Bez tego rozróżnienia świeżo wyczyszczony kafel wyglądałby
    /// jak zepsuty — użytkownik właśnie kliknął przycisk i zobaczyłby pustkę bez wyjaśnienia.
    @ViewBuilder private var pustyRejestr: some View {
        if let kiedy = model.rejestr.wyczyszczonoKiedy {
            Text("Wyczyszczono o \(Self.godzinaZdarzenia.string(from: kiedy)). Kolejne zdarzenie dopisze się samo.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Nic się jeszcze nie wydarzyło przy włączonym programie.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func zdarzenieRow(_ z: Zdarzenie, pelny: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(kolorStanu(z.stan))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(z.nazwa).font(.caption).lineLimit(1)
                Text(pelny && z.opis != nil ? "\(z.jednymZdaniem) · \(z.opis!)" : z.jednymZdaniem)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.godzinaZdarzenia.string(from: z.czas))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                if pelny {
                    Text(z.zrodlo.opis)
                        .font(.caption2).foregroundStyle(.quaternary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .help("\(Self.pelnaData.string(from: z.czas)) · \(z.zrodlo.opis)")
    }

    private func kolorStanu(_ stan: Przebieg.Stan) -> Color {
        switch stan {
        case .trwa:     return .teal
        case .udany:    return .green
        case .bledny:   return .red
        case .cisza:    return .orange
        case .nieznany: return .secondary
        }
    }

    /// Godzina bez daty — rejestr trzyma kilka tygodni, ale w wierszu liczy się „o której".
    /// Pełna data siedzi w podpowiedzi pod kursorem.
    static let godzinaZdarzenia: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let pelnaData: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM, HH:mm:ss"
        f.locale = .current // od 2026-10-04 język systemu (był pl_PL) — tor „mNas po angielsku”
        return f
    }()

    // MARK: - Transfery — co płynie przez łącze i kto to ciągnie
    //
    // Źródło: RRD Proxmoksa, cała interpretacja w `Transfery.swift`. Kafel odpowiada
    // naraz na dwa pytania — **ile płynie teraz** i **co się działo przez ostatnią
    // godzinę** — decyzja 2026-08-29. Powód jest w danych: próbka RRD ma minutę,
    // więc sama liczba nie mówi, czy to szczyt, czy ogon kończącego się transferu.
    //
    // 🔴 Węzeł nie jest jednym ze strumieni — on **jest** łączem (Proxmox sumuje do jego
    // `netin`/`netout` wyłącznie karty fizyczne). Stoi jako mianownik udziału, nie jako
    // wiersz na liście.

    @ViewBuilder private func transferyTile(_ size: TileSize) -> some View {
        let wszystkie = model.strumienie
        let lacze = wszystkie.first { if case .lacze = $0.rodzaj { return true }; return false }
        let aktywne = TransferyParsers.aktywne(wszystkie)
        let teraz = lacze?.bajtyNaSekunde ?? 0
        let przebieg = lacze?.punkty.map(\.razemNaSekunde) ?? []
        tile(size) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.mint)
                Text("Transfery")
                    .font(size == .small ? .caption2.bold() : .subheadline.bold())
                    .foregroundStyle(.mint)
                Spacer(minLength: 0)
                // 🔴 „cisza" nie może stać, gdy trwa kopiowanie dysk→dysk. Dokładnie to
                // zgłosił 2026-09-04: kafel mówił „cisza", a serwer kopiował 90 MB/s.
                Text(etykietaRuchu(aktywne.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(model.kopie.isEmpty ? Color.secondary : Color.mint)
            }

            if !model.transferyZywe {
                // 🔴 „Nie ma odczytu" ≠ „w sieci cisza". Zerwany odczyt wygląda w danych
                // identycznie jak spokojna sieć — ostrzeżenie wprost z planu monitora.
                Label("Proxmox nie oddał historii RRD. To brak odczytu, nie cisza w sieci.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                switch size {
                case .small:
                    bigValue(Format.predkosc(teraz), "przez łącze",
                             color: teraz > 0 ? .mint : .primary)
                    wykresLacza(przebieg, wysokosc: 16)
                case .medium:
                    bigValue(Format.predkosc(teraz), "przez łącze",
                             color: teraz > 0 ? .mint : .primary)
                    wykresLacza(przebieg, wysokosc: 28)
                    podpisWykresu(lacze)
                    listaKafla(aktywne, wOknie: 2) { strumienRow($0, lacze: lacze) }
                    ForEach(model.kopie.prefix(wPanelu ? model.kopie.count : 1)) {
                        kopiaRow($0, zwiezle: !wPanelu)
                    }
                    dyskiPodsumowanie()
                case .large:
                    HStack(spacing: 10) {
                        healthStat("Przez łącze", Format.predkosc(teraz), .mint)
                        healthStat("Szczyt godziny",
                                   Format.predkosc(lacze?.szczytNaSekunde ?? 0), .secondary)
                        healthStat("Strumieni", "\(aktywne.count)",
                                   aktywne.isEmpty ? .secondary : .primary)
                    }
                    wykresLacza(przebieg, wysokosc: 44)
                    podpisWykresu(lacze)
                    if aktywne.isEmpty {
                        Text("Cisza — żaden strumień nie przekracza \(Format.predkosc(TransferyParsers.progCiszyBajtowNaSekunde)).")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ThinScrollView {
                        VStack(spacing: 4) {
                            ForEach(aktywne) { strumienRow($0, lacze: lacze) }
                            if !model.kopie.isEmpty || !TransferyParsers.pracujace(model.przeplywyDyskow).isEmpty {
                                Divider().padding(.vertical, 2)
                                sekcjaDyskow()
                            }
                        }
                    }
                    Button("Pokaż historię…") { openWindow(id: OknoPaneluTrwalego.id, value: OknoPaneluTrwalego.Cel.transfery) }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .disabled(editingLayout)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout && model.transferyZywe { openWindow(id: OknoPaneluTrwalego.id, value: OknoPaneluTrwalego.Cel.transfery) } }
    }

    // MARK: Ruch na dyskach — to, czego łącze nie widzi

    /// Napis w prawym górnym rogu kafla.
    ///
    /// Kolejność jest hierarchią ważności: trwająca kopia bije liczbę strumieni, a ta
    /// bije „ciszę". Sama „cisza" zostaje dopiero wtedy, gdy naprawdę nic się nie dzieje
    /// — ani w sieci, ani na dyskach.
    private func etykietaRuchu(_ aktywnych: Int) -> String {
        if !model.kopie.isEmpty { return String(localized: "kopiuje") }
        if aktywnych > 0 { return "\(aktywnych)" }
        if let psi = model.obciazenieIO, psi >= TransferyParsers.progObciazeniaIO { return String(localized: "dyski") }
        return String(localized: "cisza")
    }

    /// Jedna linijka o dyskach na średnim kaflu — suma, bez rozbicia.
    @ViewBuilder private func dyskiPodsumowanie() -> some View {
        let pracujace = TransferyParsers.pracujace(model.przeplywyDyskow)
        if !pracujace.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive").font(.system(size: 8)).foregroundStyle(.mint)
                Text("dyski")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(Format.predkosc(TransferyParsers.sumaDyskow(pracujace)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.primary)
            }
        } else if model.przeplywyDyskow.isEmpty,
                  let psi = model.obciazenieIO, psi >= TransferyParsers.progObciazeniaIO {
            // Bez SSH nie ma megabajtów — zostaje uczciwy wskaźnik z RRD.
            HStack(spacing: 4) {
                Image(systemName: "internaldrive").font(.system(size: 8)).foregroundStyle(.orange)
                Text(String(localized: "dyski pracują — \(Int(psi))% obciążenia"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// Pełna sekcja na dużym kaflu: trwające kopie, potem dyski, które realnie pracują.
    @ViewBuilder private func sekcjaDyskow() -> some View {
        let pracujace = TransferyParsers.pracujace(model.przeplywyDyskow)

        HStack(spacing: 4) {
            Image(systemName: "internaldrive.fill").font(.system(size: 9)).foregroundStyle(.mint)
            Text("Na dyskach — poza łączem")
                .font(.caption2.bold()).foregroundStyle(.mint)
            Spacer(minLength: 0)
        }

        ForEach(model.kopie) { kopiaRow($0, zwiezle: false) }

        ForEach(pracujace) { d in
            HStack(spacing: 6) {
                Text(d.nazwa)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Text("↓ \(Format.predkosc(d.odczytNaSekunde))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text("↑ \(Format.predkosc(d.zapisNaSekunde))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }

        if model.przeplywyDyskow.isEmpty {
            if let psi = model.obciazenieIO {
                Text(psi >= TransferyParsers.progObciazeniaIO
                     ? String(localized: "Dyski pracują — \(Int(psi))% obciążenia I/O. Megabajtów nie podam: to wymaga SSH.")
                     : String(localized: "Dyski spokojne — \(Int(psi))% obciążenia I/O."))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Bez SSH nie widać ruchu na dyskach — RRD Proxmoksa go nie raportuje.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Jedna trwająca kopia: skąd dokąd, ile przeszło, ile zostało.
    @ViewBuilder private func kopiaRow(_ k: KopiaWToku, zwiezle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 8)).foregroundStyle(.mint)
                Text(k.skrot).font(.caption2.bold()).lineLimit(1)
                Spacer(minLength: 0)
                if let p = k.postep {
                    Text("\(Int(p * 100))%")
                        .font(.caption2.monospacedDigit().bold()).foregroundStyle(.mint)
                }
            }

            if let p = k.postep {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(.mint)
                    .frame(height: 3)
            }

            if !zwiezle {
                HStack(spacing: 6) {
                    // „Ile skopiował" i „ile zostało" — dokładnie to, o co prosił użytkownik.
                    Text("\(Format.shortBytes(k.zapisano)) z \(Format.shortBytes(k.calosc))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if let zostalo = k.zostaloBajtow {
                        Text("· zostało \(Format.shortBytes(zostalo))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text("\(k.narzedzie) · \(Format.predkosc(k.sredniaNaSekunde)) średnio")
                        .font(.caption2).foregroundStyle(.tertiary)
                    if let sekundy = k.szacowaneSekundy {
                        Text("· ~\(Format.uptime(sekundy)) do końca")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .help("\(k.zrodlo) → \(k.cel)\nPID \(k.pid), trwa \(Format.uptime(k.sekundTrwa))")
    }

    /// Przebieg łącza w ostatniej godzinie — sześćdziesiąt gotowych prędkości z RRD.
    /// Skala jest własna (szczyt okna), bo łącze rysujemy samo, bez porównania z innymi.
    @ViewBuilder private func wykresLacza(_ punkty: [Double], wysokosc: CGFloat) -> some View {
        if punkty.count > 1 {
            Sparkline(points: punkty, tint: .mint)
                .frame(height: wysokosc)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.3)))
        }
    }

    /// Podpis mówi wprost, **jak stare** są te dane. Przy próbce co minutę „teraz" bez
    /// tego dopisku znaczyłoby coś innego dla programu i coś innego dla patrzącego.
    @ViewBuilder private func podpisWykresu(_ lacze: Strumien?) -> some View {
        if let ostatnia = lacze?.teraz?.czas {
            Text("ostatnia godzina · próbka co minutę · pomiar \(Self.godzinaZdarzenia.string(from: ostatnia))")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    /// Wiersz strumienia: kto, pasek udziału w łączu, ile w każdą stronę.
    ///
    /// Strzałki są **z punktu widzenia tego, co stoi w „kto"** i RRD podaje je już tak —
    /// `netin` to „do niego". 🔴 Nie odwracaj tego dla kontenerów: odwracanie było
    /// potrzebne przy licznikach `veth` z punktu widzenia hosta i razem z nimi odeszło.
    private func strumienRow(_ s: Strumien, lacze: Strumien?) -> some View {
        let udzial = TransferyParsers.udzial(s, wLaczu: lacze)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: ikonaStrumienia(s.rodzaj))
                    .font(.caption2).foregroundStyle(.mint)
                Text(s.kto).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Format.predkosc(s.bajtyNaSekunde))
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            if let udzial {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color.mint)
                            .frame(width: max(2, geo.size.width * udzial))
                    }
                }
                .frame(height: 4)
            }
            HStack(spacing: 6) {
                Label(Format.predkosc(s.odNiegoNaSekunde), systemImage: "arrow.up")
                Label(Format.predkosc(s.doNiegoNaSekunde), systemImage: "arrow.down")
                if let udzial {
                    Text(String(localized: "· \(Int((udzial * 100).rounded()))% łącza"))
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
        .help("\(s.zrodlo) · \(s.rodzaj.opis) · okno \(Int(s.sekundObjete / 60)) min")
    }

    private func ikonaStrumienia(_ rodzaj: Strumien.Rodzaj) -> String {
        switch rodzaj {
        case .kontener: return "shippingbox"
        case .maszyna:  return "desktopcomputer"
        case .lacze:    return "cable.connector"
        }
    }

    // MARK: - Pobór mocy (RAPL)
    //
    // Kafel mówi „procesor", a nie „komputer", i to jest świadome. Zasilacz
    // mini PC nie ma telemetrii — brak IPMI, `sensors` nie podaje ani watów,
    // ani amperów (zmierzone 2026-08-19). RAPL pokazuje pobór procesora: rdzenie,
    // część nierdzeniową i kontroler pamięci. To realny pomiar, tylko węższy niż
    // gniazdko — i lepiej to napisać na kaflu, niż podpisać liczbę „zasilacz".

    @ViewBuilder private func powerTile(_ size: TileSize) -> some View {
        let p = model.power
        let total = p.measuredWatts
        tile(size) {
            head("Pobór mocy", DashTileID.power.ikona, DashTileID.power.kolor, size,
                 trailing: total.map { String(format: "%.1f W", $0) })
            switch size {
            case .small:
                bigValue(p.packageWatts.map { String(format: "%.1f", $0) } ?? "—",
                         p.gpuWatts == nil ? "W · procesor" : "W · procesor (+GPU)",
                         color: .yellow)
            case .medium, .large:
                VStack(alignment: .leading, spacing: 3) {
                    if let pkg = p.packageWatts {
                        powerRow("Procesor (pakiet)", pkg, .yellow)
                    }
                    if let gpu = p.gpuWatts {
                        powerRow("GPU", gpu, .green)
                    }
                    ForEach(p.domains.sorted(by: { $0.key < $1.key }), id: \.key) { name, w in
                        powerRow("\(domainLabel(name))", w, .secondary)
                    }
                    if size == .large {
                        Text("Pomiar RAPL — pobór procesora, nie całego komputera. Zasilacz w tym sprzęcie nie udostępnia odczytu.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
        }
        // Okno historii (od 1.2.13). Ponowny klik wyciąga to samo okno, nie otwiera drugiego.
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoHistorii.id, value: DashTileID.power) } }
    }

    // MARK: - Przebiegi — mechanizmy, które się uruchamiają i kończą
    //
    // Jeden moduł z listą w środku, jak Alerty i Usługi — nie kafel na przebieg.
    // Ta sama treść jest w panelu spod ikony w pasku menu (`PasekMenu.swift`); tam
    // pod ręką, tutaj razem z resztą stanu serwera.
    //
    // 🔴 Postęp jest liczony w **kontenerach**, nie w procentach, i to nie jest
    // uproszczenie: log `vzdump` dla LXC nie zawiera ani jednej linii z procentem
    // (zmierzone 2026-08-20). Patrz `PrzebiegiParsers.vzdumpPostep`.

    @ViewBuilder private func przebiegiTile(_ size: TileSize) -> some View {
        let lista = model.przebiegi
        let trwajace = lista.filter { $0.stan == .trwa }
        let uwaga = lista.filter { ($0.stan.alarmujacy || $0.przekroczylCzas) && $0.stan != .trwa }
        // Duży kafel pokazuje **wszystkie** przebiegi, nie osiem.
        //
        // 🔴 Limit 8 był tu z czasów, gdy w panelu paska menu przewijał się cały kafel
        // i długa lista wyjeżdżała za ekran. Od 1.2.1 kafel stoi w ramce strony, a lista
        // ma własne przewijanie — obcinanie zabierałoby dostęp do reszty, nie ratowało
        // układu. Ta sama zmiana co przy Dyskach i Miejscu, zgłoszenie 2026-09-04.
        let ile = size == .large ? lista.count : (size == .medium ? 3 : 0)

        tile(size) {
            head("Przebiegi", DashTileID.przebiegi.ikona, DashTileID.przebiegi.kolor, size,
                 trailing: trwajace.isEmpty ? String(localized: "w spoczynku") : String(localized: "\(trwajace.count) w toku"))
            switch size {
            case .small:
                if let pierwszy = trwajace.first {
                    bigValue(pierwszy.postepOpis ?? "…",
                             "\(PrzebiegFormat.tempo(pierwszy) ?? pierwszy.faza ?? String(localized: "trwa"))",
                             color: .teal)
                    if let ulamek = pierwszy.postepUlamek {
                        PasekPostepu(ulamek: ulamek, kolor: .teal)
                    }
                } else if !uwaga.isEmpty {
                    bigValue("\(uwaga.count)", "wymaga uwagi", color: .orange)
                } else {
                    bigValue("✓", "wszystko przeszło", color: .green)
                }
            case .medium, .large:
                let doPokazania = Array((trwajace + uwaga + lista.filter {
                    $0.stan != .trwa && !$0.stan.alarmujacy && !$0.przekroczylCzas
                }).prefix(ile))
                ThinScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(doPokazania) { p in przebiegRow(p, pelny: size == .large) }
                    }
                }
                if lista.count > doPokazania.count { moreLine(lista.count - doPokazania.count) }
                // Ten sam przycisk co w panelu spod ikony (`PasekMenu.swift`) — decyzja
                // 2026-08-23: „w tym małym okienku **oraz** na głównym w kafelku z tymi info".
                // Gasi czerwień na ikonie; wiersze wyżej i wpisy w „Zdarzeniach" zostają.
                if !model.alarmyDoOdhaczenia.isEmpty {
                    Button("Oznacz alert jako przeczytany") { model.potwierdzAlerty() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(editingLayout)
                        .help("Gasi czerwoną ikonę w pasku menu i liczbę obok niej. Wpis w „Zdarzeniach” zostaje, a kolejna awaria zapali je od nowa.")
                }
                if size == .large {
                    Text("Kopie chodzą zwykle w nocy, gdy Mac śpi — wtedy ten kafel nie powiadomi o błędzie.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Okno historii (od 1.2.13). Ponowny klik wyciąga to samo okno, nie otwiera drugiego.
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoHistorii.id, value: DashTileID.przebiegi) } }
    }

    // MARK: Aktualizacje serwera (pve-update-check, od 1.2.30)

    @ViewBuilder private func aktualizacjeTile(_ size: TileSize) -> some View {
        let odczyt = model.aktualizacje
        // Najpilniejsze na górze; „tylko wersja główna” to maszyny aktualne — liczą się osobno.
        let maszyny = (odczyt?.stan?.doAktualizacji ?? []).sorted { $0.pilnosc > $1.pilnosc }
        let doZrobienia = maszyny.filter { $0.pilnosc >= .aktualizacje }
        let bezp = maszyny.reduce(0) { $0 + $1.bezpieczenstwo }
        let bledy = (odczyt?.stan?.maszyny ?? []).filter { !$0.bledy.isEmpty }
        let kolor: Color = !bledy.isEmpty || bezp > 0 ? .orange : (doZrobienia.isEmpty ? .blue : .yellow)
        let kiedy = AktualizacjeParsers.data(odczyt?.stan?.sprawdzono)
            .map { String(localized: "sprawdzono \($0.formatted(date: .omitted, time: .shortened))") }

        tile(size) {
            head("Aktualizacje", DashTileID.aktualizacje.ikona, DashTileID.aktualizacje.kolor, size, trailing: kiedy)
            if case .brak = odczyt?.narzedzie {
                bigValue("—", "narzędzie nie jest zainstalowane", color: .secondary)
            } else if model.aktualizacjaTrwa {
                let p = odczyt?.postep
                VStack(alignment: .leading, spacing: 4) {
                    Spacer(minLength: 0)
                    Text(p?.trwa == true ? "\(p?.postep ?? 0)%" : "…")
                        .font(.system(size: size == .small ? 22 : 26, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.green)
                    Text(p?.trwa == true ? (p?.etap ?? String(localized: "trwa")) : String(localized: "sprawdzanie lub start…"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(size == .small ? 1 : 2)
                    PasekPostepu(ulamek: p?.trwa == true ? p!.ulamek : 0.02, kolor: .green)
                }
            } else if size == .small || doZrobienia.isEmpty {
                bigValue(doZrobienia.isEmpty ? "✓" : "\(doZrobienia.count)",
                         doZrobienia.isEmpty ? "wszystko aktualne" : (bezp > 0 ? "maszyn, \(bezp) poprawek bezp." : "maszyn z aktualizacjami"),
                         color: kolor)
            } else {
                ThinScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(maszyny.prefix(size == .large ? 40 : 4))) { m in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(OknoAktualizacji.kolor(m))
                                    .frame(width: 7, height: 7).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.etykieta).font(.caption.bold()).lineLimit(1)
                                    Text(OknoAktualizacji.opis(m)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                // Wiersz na całą szerokość — bez tego lista (i jej pasek) kończyła się w połowie kafla.
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                if size != .large && maszyny.count > 4 { moreLine(maszyny.count - 4) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoAktualizacji.id) } }
    }

    private func przebiegRow(_ p: Przebieg, pelny: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(kolorPrzebiegu(p))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.nazwa).font(.caption).lineLimit(1)
                if let ulamek = p.postepUlamek, p.stan == .trwa {
                    PasekPostepu(ulamek: ulamek, kolor: kolorPrzebiegu(p))
                }
                if pelny, let dopisek = opisPrzebiegu(p) {
                    Text(dopisek).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(PrzebiegFormat.czas(p))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func kolorPrzebiegu(_ p: Przebieg) -> Color {
        if p.przekroczylCzas { return .orange }
        switch p.stan {
        case .trwa:     return .teal
        case .udany:    return .green
        case .bledny:   return .red
        case .cisza:    return .orange
        case .nieznany: return .secondary
        }
    }

    private func opisPrzebiegu(_ p: Przebieg) -> String? {
        var czesci: [String] = []
        if p.przekroczylCzas { czesci.append(String(localized: "trwa nietypowo długo")) }
        if let postep = p.postepOpis { czesci.append(postep) }
        if let faza = p.faza { czesci.append(faza) }
        if let opis = p.opis { czesci.append(opis) }
        if let tempo = PrzebiegFormat.tempo(p) { czesci.append(tempo) }
        if czesci.isEmpty { czesci.append(p.zrodlo.opis) }
        return czesci.joined(separator: " · ")
    }

    private func powerRow(_ label: LocalizedStringKey, _ watts: Double, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label).font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            Text(String(format: "%.1f W", watts))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }

    /// Nazwy domen RAPL są techniczne (`core`, `uncore`, `dram`) — tłumaczymy je na to,
    /// czym w praktyce są, bo „uncore" nikomu nic nie mówi.
    private func domainLabel(_ raw: String) -> String {
        switch raw {
        case "core":   return String(localized: "└ rdzenie")
        case "uncore": return String(localized: "└ grafika i magistrale")
        case "dram":   return String(localized: "└ kontroler pamięci")
        default:       return "└ \(raw)"
        }
    }

    // MARK: - Dyski — kondycja i lista w jednym module
    //
    // Wcześniej były to dwie rzeczy: osobny kafel „Kondycja dysków" z czterema
    // statystykami i osobny kafel na każdy dysk. Przy jednym dysku NVMe znaczyło to
    // pół ekranu na cztery liczby liczone z jednego pomiaru. Teraz: nagłówek ze stanem,
    // statystyki tylko w dużym kaflu i lista dysków, z której klik otwiera pełne SMART.

    @ViewBuilder private func disksTile(_ size: TileSize) -> some View {
        let temps = model.temperatures.values.map { $0 }
        // Ostrzeżenie nie jest już „któryś dysk przekroczył 55 °C" — to lista wpisów
        // z nazwą nośnika, wskaźnikiem, wartością, progiem i godziną pomiaru.
        // Zgłoszenie 2026-08-23: „ZERO INFORMACJI O TYM CO SIE DZIEJE".
        let ostrzezenia = OstrzezeniaDyskow.zbierz(disks: model.disks,
                                                   temperatures: model.temperatures,
                                                   czas: model.lastSuccessfulRefresh ?? Date())
        let ok = ostrzezenia.isEmpty
        let powazne = ostrzezenia.contains { $0.poziom == .powazne }
        let maxT = temps.max()
        tile(size) {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive").foregroundStyle(.cyan)
                Text("Dyski")
                    .font(size == .small ? .caption2.bold() : .subheadline.bold())
                    .foregroundStyle(.cyan)
                // Trójkąt jest **przyciskiem**, nie ozdobą: użytkownik wybrał 2026-08-23, żeby
                // kliknięcie w ostrzeżenie otwierało okno z pełną treścią.
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(ok ? .green : (powazne ? .red : .orange))
                Spacer(minLength: 0)
                Text("\(model.disks.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            switch size {
            case .small:
                if let pierwsze = ostrzezenia.first {
                    // W małym kaflu nie mieści się zdanie, ale mieści się to, czego
                    // brakowało najbardziej: **który** nośnik i **ile**.
                    bigValue(pierwsze.wartosc, "\(pierwsze.nosnik)",
                             color: pierwsze.poziom == .powazne ? .red : .orange)
                    Text("\(pierwsze.wskaznik) · próg \(pierwsze.prog)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    // Przy jednym dysku (tak jest na serwerze testowym) nazwa mówi więcej niż słowo
                    // „najcieplejszy" — pokazujemy konkretny nośnik, nie superlatyw.
                    bigValue(maxT.map { "\(Int($0.rounded()))°" } ?? "—",
                             model.disks.count == 1
                                ? "\(model.disks[0].name)"
                                : "najcieplejszy z \(model.disks.count)",
                             color: .primary)
                    if let first = model.disks.first, model.disks.count == 1 {
                        Text(Format.shortBytes(first.size?.value))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            case .medium:
                if let pierwsze = ostrzezenia.first {
                    wierszOstrzezenia(pierwsze, pozostale: ostrzezenia.count - 1)
                }
                listaKafla(model.disks, wOknie: ostrzezenia.isEmpty ? 3 : 2) { diskRow($0) }
            case .large:
                if let pierwsze = ostrzezenia.first {
                    wierszOstrzezenia(pierwsze, pozostale: ostrzezenia.count - 1)
                }
                if temps.isEmpty {
                    Text("Serwer nie zwrócił temperatur przez API. Kliknij dysk, żeby zobaczyć pełne SMART przez SSH.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        healthStat("Ostrzeżenia", "\(ostrzezenia.count)",
                                   ok ? .green : (powazne ? .red : .orange))
                        healthStat("Najwyższa", "\(Int((temps.max() ?? 0).rounded())) °C", .primary)
                        healthStat("Średnia",
                                   String(format: "%.0f °C", temps.reduce(0, +) / Double(temps.count)),
                                   .primary)
                    }
                }
                ThinScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.disks) { diskRow($0) }
                    }
                }
            }
        }
        // Od 1.2.14: klik w kafel (poza wierszem dysku i ostrzeżeniem, które mają własne
        // okna) otwiera temperatury wszystkich dysków. Zgłoszenie 2026-10-04: „klikam
        // po całym kafelku, nic nie dostaję” — historia była tylko w panelu jednego dysku.
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoHistorii.id, value: DashTileID.disks) } }
    }

    /// Linijka ostrzeżenia w kaflu „Dyski" — klikalna, otwiera okno z pełną treścią.
    ///
    /// Trzyma **tę samą** treść, co nagłówek okna: nośnik, wskaźnik, wartość, próg.
    /// Godzina zostaje w oknie, bo w kaflu nie ma na nią szerokości.
    private func wierszOstrzezenia(_ o: OstrzezenieDysku, pozostale: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: o.poziom == .powazne ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(o.poziom == .powazne ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(o.jednymZdaniem)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if pozostale > 0 {
                    Text("i \(pozostale) innych")  // odmiana w katalogu tekstów (warianty liczby mnogiej)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill((o.poziom == .powazne ? Color.red : Color.orange).opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { showOstrzezeniaDyskow = true } }
        .help("Kliknij, żeby zobaczyć, co dokładnie się dzieje")
    }

    private func diskRow(_ disk: Disk) -> some View {
        let temp = model.temperatures[disk.name]
        let tempColor: Color = {
            guard let t = temp else { return .secondary }
            return t >= 55 ? .red : (t >= 45 ? .orange : .green)
        }()
        return HStack(spacing: 8) {
            Image(systemName: disk.type == "SSD" ? "memorychip" : "internaldrive")
                .font(.caption)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(disk.model ?? disk.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(disk.name) · \(Format.shortBytes(disk.size?.value))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let temp {
                Text("\(Int(temp.rounded()))°")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tempColor)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoPaneluTrwalego.id, value: OknoPaneluTrwalego.Cel.dysk(disk.name)) } }
    }

    private func healthStat(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Usługi — jeden moduł zamiast kafla na usługę

    @ViewBuilder private func servicesTile(_ size: TileSize) -> some View {
        let running = model.services.filter { $0.state?.uppercased() == "RUNNING" }.count
        tile(size) {
            head("Usługi", "gearshape.2", .indigo, size, trailing: "\(running)/\(model.services.count)")
            switch size {
            case .small:
                bigValue("\(running)/\(model.services.count)", "działa", color: .indigo)
                // Pasek stanu wszystkich usług — jedno spojrzenie mówi, czy któraś leży.
                HStack(spacing: 2) {
                    ForEach(model.services) { service in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(service.state?.uppercased() == "RUNNING"
                                  ? Color.green : Color.secondary.opacity(0.35))
                            .frame(height: 8)
                            .help(serviceName(service.service))
                    }
                }
            case .medium:
                listaKafla(model.services, wOknie: 5) { serviceRow($0) }
            case .large:
                ThinScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.services) { serviceRow($0) }
                    }
                }
            }
        }
        // Od 1.2.16: klik w kafel poza wierszem otwiera okno ze wszystkimi usługami.
        // Zgłoszenie 2026-10-04: w średnim kaflu „+18 więcej” nie dawało się rozwinąć.
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { openWindow(id: OknoPaneluTrwalego.id, value: OknoPaneluTrwalego.Cel.uslugi) } }
    }

    private func serviceRow(_ service: Service) -> some View {
        let running = (service.state?.uppercased() == "RUNNING")
        return HStack(spacing: 6) {
            Circle()
                .fill(running ? .green : .secondary)
                .frame(width: 6, height: 6)
            Text(serviceName(service.service))
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            if service.enable == true {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .help("Startuje z systemem")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { if !editingLayout { selectedService = service } }
        .contextMenu {
            if running {
                Button("Zatrzymaj \(serviceName(service.service))", role: .destructive) {
                    pendingService = ServiceAction(service: service, start: false)
                }
            } else {
                Button("Uruchom \(serviceName(service.service))") {
                    pendingService = ServiceAction(service: service, start: true)
                }
            }
        }
    }

    /// Czytelne nazwy usług węzła. Proxmox zwraca nazwy jednostek systemd, po których
    /// bez znajomości środka nie widać, co wolno zatrzymać, a co ubije panel web.
    private func serviceName(_ raw: String) -> String { NazwyUslug.nazwa(raw) }

    // MARK: - Alerty — jeden moduł, z czyszczeniem

    @ViewBuilder private func alertsTile(_ size: TileSize) -> some View {
        let alerts = activeAlerts
        tile(size) {
            HStack(spacing: 4) {
                Image(systemName: "bell.badge").foregroundStyle(.orange)
                Text("Alerty")
                    .font(size == .small ? .caption2.bold() : .subheadline.bold())
                    .foregroundStyle(.orange)
                Spacer(minLength: 0)
                if size != .small {
                    if !alerts.isEmpty {
                        Button("Wyczyść") { layout.dismissAlerts(alerts.map(\.id)) }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Schowaj wszystkie alerty — nie wrócą po odświeżeniu")
                    }
                    if layout.dismissedAlertCount > 0 {
                        Button {
                            layout.restoreDismissedAlerts()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Przywróć \(layout.dismissedAlertCount) wyczyszczonych")
                    }
                }
                Text("\(alerts.count)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            switch size {
            case .small:
                bigValue("\(alerts.count)", alerts.isEmpty ? "czysto" : "do sprawdzenia",
                         color: alerts.isEmpty ? .green : .orange)
                // Najświeższy alert w skrócie — sama liczba nie mówi, czy to drobiazg,
                // czy coś, po co trzeba wstać od biurka.
                if let newest = alerts.first {
                    Text(newest.formatted ?? "—")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .medium:
                if alerts.isEmpty {
                    emptyAlerts
                } else {
                    listaKafla(alerts, wOknie: 2) { alertRow($0, dense: true) }
                }
            case .large:
                if alerts.isEmpty {
                    emptyAlerts
                } else {
                    ThinScrollView {
                        VStack(spacing: 4) {
                            ForEach(alerts) { alertRow($0, dense: false) }
                        }
                    }
                }
            }
        }
    }

    private var emptyAlerts: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(layout.dismissedAlertCount > 0
                 ? "Wyczyszczone (\(layout.dismissedAlertCount))"
                 : "Brak alertów")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Wiersz alertu. Odstępy celowo ciasne — lista alertów ma się mieścić w kaflu,
    /// a nie zajmować ekran na trzy pozycje (uwaga użytkownika 2026-08-16).
    private func alertRow(_ alert: Alert, dense: Bool) -> some View {
        let level = alert.level?.uppercased() ?? "INFO"
        let color: Color = level == "CRITICAL" ? .red : (level == "WARNING" ? .orange : .secondary)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: level == "INFO" ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(color)
            Text(alert.formatted ?? "—")
                .font(.caption2)
                .lineLimit(dense ? 2 : 4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button {
                layout.dismissAlert(alert.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Wyczyść ten alert")
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Narzędzia w kontenerach (wykryte, nie wpisane w kod)

    @ViewBuilder private func toolsTile(_ size: TileSize) -> some View {
        tile(size) {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3.fill").foregroundStyle(.purple)
                Text("Narzędzia")
                    .font(size == .small ? .caption2.bold() : .subheadline.bold())
                    .foregroundStyle(.purple)
                Spacer(minLength: 0)
                if model.discoveringServices {
                    ProgressView().controlSize(.mini)
                } else if size != .small {
                    Button {
                        Task { await model.discoverWebServices() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Szukaj ponownie w kontenerach")
                }
            }
            if size == .small {
                bigValue("\(model.webServices.count)", "znalezione", color: .purple)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.webServices.prefix(2)) { service in
                        Text(service.label)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                ThinScrollView {
                    VStack(spacing: 3) {
                        ForEach(model.webServices) { toolRow($0) }
                    }
                }
            }
        }
    }

    /// Adres jest pokazany jawnie pod nazwą, bo to on jest odpowiedzią na pytanie
    /// „pod czym to stoi", zadawane częściej niż samo otwarcie panelu.
    private func toolRow(_ service: DiscoveredService) -> some View {
        let known = service.toolName != nil
        return HStack(spacing: 6) {
            Image(systemName: known ? "app.badge.checkmark" : "questionmark.app")
                .font(.caption2)
                .foregroundStyle(known ? Color.purple : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(service.label).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(service.address):\(service.port)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Image(systemName: "arrow.up.forward.square")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !editingLayout, let url = service.url else { return }
            NSWorkspace.shared.open(url)
        }
        .help(service.url?.absoluteString ?? "—")
        .contextMenu {
            Button("Kopiuj adres") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(service.url?.absoluteString ?? "", forType: .string)
            }
        }
    }

    // MARK: - Akcje

    /// Otwiera panel web węzła. Wersja pod TrueNAS-a miała tu przycisk „Pliki" (udział
    /// SMB) — Proxmox domyślnie żadnego udziału nie wystawia, więc przycisk prowadziłby
    /// do okna logowania, które nigdy nie zadziała.
    private func openWebPanel() {
        guard let url = URL(string: "https://\(model.host):\(ProxmoxClient.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - RAM: rozbicie i formatowanie liczby/jednostki osobno

    private func memorySegments() -> [DonutSegment] {
        var out: [DonutSegment] = []
        if let f = model.memory.free { out.append(DonutSegment(value: Double(f), color: cFree, label: String(localized: "Wolne"))) }
        if let z = model.memory.zfsCache { out.append(DonutSegment(value: Double(z), color: cZFS, label: String(localized: "Cache ZFS"))) }
        if let s = model.memory.services { out.append(DonutSegment(value: Double(s), color: cSvc, label: String(localized: "Usługi"))) }
        return out
    }

    private func memNumber(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let gib = Double(bytes) / 1_073_741_824
        return String(format: gib >= 10 ? "%.1f" : "%.2f", gib)
    }

    private func memUnit(_ bytes: Int64?) -> String {
        (bytes ?? 0) > 0 ? "GiB" : ""
    }

    private func usageColor(_ usage: Double, base: Color = .accentColor) -> Color {
        usage > 85 ? .red : (usage > 60 ? .orange : base)
    }

    // MARK: - Elementy pomocnicze

    private func legendRow(_ color: Color, _ label: LocalizedStringKey, _ bytes: Int64?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(Format.shortBytes(bytes)).font(.caption2.monospacedDigit())
        }
    }

    /// Nagłówek kafla — na małym rozmiarze mniejszą czcionką i bez strzałki,
    /// bo tam liczy się każdy punkt wysokości.
    private func head(_ title: LocalizedStringKey, _ systemImage: String, _ tint: Color, _ size: TileSize,
                      trailing: String? = nil, chevron: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(title)
                .font(size == .small ? .caption2.bold() : .subheadline.bold())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if let trailing, size != .small {
                Text(trailing)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Jedna duża liczba — treść małego kafla, gdzie na nic więcej nie ma miejsca.
    private func bigValue(_ text: String, _ caption: LocalizedStringKey, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moreLine(_ count: Int) -> some View {
        Text("+ \(count) więcej")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).lineLimit(1)
        }
        .font(.caption2)
    }

    /// Kafel: spójne tło, ramka i **stały** rozmiar z siatki. Treść, która by się nie
    /// zmieściła, jest przycinana — kafel nigdy nie rozpycha wiersza siatki.
    /// Czy rysujemy się w panelu paska menu.
    private var wPanelu: Bool { tryb == .panel }

    /// Ile pozycji listy pokazać na średnim kaflu.
    ///
    /// > [!info] W oknie tniemy, w panelu nie
    /// > W oknie średni kafel ma 300×144 pt i stoi obok innych — obcięcie do trzech
    /// > pozycji plus „+N więcej" jest tam właściwe, bo pełna lista jest o jedno
    /// > kliknięcie dalej, w wariancie dużym. W panelu paska menu takiego przejścia
    /// > nie ma: „+4 więcej" niczego nie otwiera, więc reszta listy była **niedostępna**.
    /// > Zgłoszenie 2026-09-04: *„ruszam oknem nie widząc żadnych więcej informacji
    /// > prócz pierwszych trzech"*.
    private func ilePokazac(_ wOknie: Int, z ilu: Int) -> Int {
        wPanelu ? ilu : wOknie
    }

    /// Lista na średnim kaflu: w panelu przewijalna i pełna, w oknie ucięta z „+N więcej".
    ///
    /// Przewijanie **tylko w panelu**: w oknie średni kafel jest niski i zagnieżdżony
    /// scroll łapałby kółko myszy w miejscu, gdzie użytkownik przewija całą siatkę kafli.
    @ViewBuilder private func listaKafla<T: Identifiable, C: View>(
        _ wszystkie: [T], wOknie: Int, @ViewBuilder wiersz: @escaping (T) -> C
    ) -> some View {
        if wPanelu {
            ThinScrollView {
                VStack(spacing: 4) { ForEach(wszystkie) { wiersz($0) } }
            }
        } else {
            VStack(spacing: 4) { ForEach(wszystkie.prefix(wOknie)) { wiersz($0) } }
            if wszystkie.count > wOknie { moreLine(wszystkie.count - wOknie) }
        }
    }

    /// Ramka kafla.
    ///
    /// > [!important] W panelu paska menu kafel NIE ma własnego tła ani obramowania
    /// > Zgłoszenie 2026-09-04: *„zamiast w okno wstawiać okna to wstaw po prostu
    /// > informacje z kafelka"*. Panel sam jest już okienkiem z tłem i zaokrągleniem —
    /// > kafel dokładał do tego drugie, więc treść siedziała w ramce wewnątrz ramki,
    /// > z podwójnym marginesem. W oknie chrome zostaje: tam kafle leżą obok siebie
    /// > na wspólnym tle i to ramka mówi, gdzie kończy się jeden, a zaczyna drugi.
    /// >
    /// > Przy okazji odzyskujemy wysokość: 12 pt wypełnienia z każdej strony plus
    /// > obramowanie to na panelu 400 pt zauważalna część miejsca na dane.
    private func tile<Content: View>(_ size: TileSize,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: size == .small ? 4 : 6) {
            content()
        }
        .padding(wPanelu ? 4 : (size == .small ? 10 : 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if !wPanelu {
                RoundedRectangle(cornerRadius: 12).fill(.background.secondary)
            }
        }
        .overlay {
            if !wPanelu {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: wPanelu ? 0 : 12))
    }
}

/// Czytelne nazwy usług węzła — wspólne dla kafla Usługi i okna Usług (od 1.2.16).
enum NazwyUslug {
    static func nazwa(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pveproxy":          return String(localized: "Panel web · API (pveproxy)")
        case "pvedaemon":         return String(localized: "Demon zarządzania (pvedaemon)")
        case "pvestatd":          return String(localized: "Zbieranie statystyk (pvestatd)")
        case "pve-cluster":       return String(localized: "Baza konfiguracji klastra (pmxcfs)")
        case "pve-firewall":      return String(localized: "Zapora sieciowa")
        case "pvescheduler":      return String(localized: "Harmonogram · backupy i replikacja")
        case "pvefw-logger":      return String(localized: "Log zapory")
        case "spiceproxy":        return String(localized: "Konsola SPICE")
        case "corosync":          return String(localized: "Komunikacja klastra (corosync)")
        case "ceph":              return String(localized: "Ceph · magazyn rozproszony")
        case "sshd", "ssh":       return String(localized: "SSH · zdalny terminal")
        case "chrony":            return String(localized: "Czas · chrony")
        case "systemd-timesyncd": return String(localized: "Czas · systemd-timesyncd")
        case "postfix":           return String(localized: "Poczta · powiadomienia")
        case "cron":              return String(localized: "Zaplanowane zadania")
        case "ksmtuned":          return String(localized: "Współdzielenie pamięci (KSM)")
        case "smartd", "smart":   return String(localized: "S.M.A.R.T. · kontrola dysków")
        case "zfs-zed":           return String(localized: "ZFS · demon zdarzeń")
        case "smbd", "smb", "cifs": return String(localized: "SMB · udziały Windows/Finder")
        case "nfs", "nfs-server": return String(localized: "NFS · udziały Unix")
        default:                  return raw
        }
    }
}
