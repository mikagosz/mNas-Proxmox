import SwiftUI
import Observation
import Network
import os

/// Stan całej aplikacji: połączenie z serwerem i pobrane dane.
///
/// Model trzyma **stan** i orkiestruje. Budowanie komend powłoki jest w `ServerCommands`,
/// zamiana tekstu z serwera na struktury w `StatsParsers` — obie te warstwy nie znają
/// SwiftUI i dają się testować bez serwera.
@MainActor
@Observable
final class AppModel {

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        /// Połączenie padło, apka sama wraca. Dashboard zostaje na ekranie z jawnym
        /// banerem — przerzucanie użytkownika na ekran łączenia przy każdym blipie sieci
        /// kasowałoby otwarte panele i tryb edycji układu.
        case reconnecting
        case failed(String)

        /// Czy pokazujemy dashboard (dane są, choćby zamrożone), czy ekran łączenia.
        var showsDashboard: Bool { self == .connected || self == .reconnecting }
    }

    /// Rozbieżność odcisku certyfikatu serwera — UI oferuje wtedy jawne „zaufaj nowemu".
    struct CertificateChange: Equatable {
        var host: String
        var expected: String
        var received: String
    }

    /// Adres węzła. **Puste przy pierwszym uruchomieniu** — konkretny adres LAN nie ma
    /// prawa być wartością domyślną w kodzie: to opis prywatnej sieci użytkownika, który
    /// pojechałby razem ze źródłami i z binarką. Po pierwszym udanym połączeniu adres
    /// wraca z Keychaina (`init()` niżej), więc wpisuje się go raz.
    var host: String = ""
    /// Pełny identyfikator tokenu API: `użytkownik@realm!nazwa`.
    /// W wersji pod TrueNAS-a była tu sama nazwa konta — Proxmox uwierzytelnia tokenem,
    /// a nie parą konto+klucz, więc całość tożsamości siedzi w tym jednym polu.
    ///
    /// Też puste z tego samego powodu: wpisana wartość mówiła wprost, jakim kontem
    /// i jakim tokenem loguje się właściciel programu. Format podpowiada pole w oknie.
    var username: String = ""
    var status: Status = .disconnected

    var systemInfo: SystemInfo?
    var guests: [Guest] = []        // maszyny wirtualne i kontenery LXC
    /// Narzędzia wykryte w kontenerach (Uptime Kuma, AdGuard, Vaultwarden…) — adresy
    /// wykryte, nie wpisane w kod.
    var webServices: [DiscoveredService] = []
    /// Trwa wykrywanie narzędzi (potrafi zająć kilkanaście sekund przy wielu kontenerach).
    var discoveringServices = false
    /// Sygnatura zestawu **działających kontenerów** z ostatniego udanego wykrycia.
    /// Gdy przestaje się zgadzać z bieżącą, narzędzia lecą jeszcze raz — bez tego
    /// lista zmieniała się dopiero po ponownym połączeniu albo po kliknięciu
    /// „Szukaj ponownie" (skasowany kontener wisiał na ekranie w nieskończoność).
    private var lastDiscoveryKey = ""
    var disks: [Disk] = []
    /// Zajętość nośników fizycznych (`lsblk` + `df`), kluczowana nazwą urządzenia
    /// (`sda`, `nvme0n1`). Uzupełnia magazyny Proxmoksa, które nie pokazują dysków
    /// spoza swojej konfiguracji — patrz `DiskUsage`.
    var diskUsage: [String: DiskUsage] = [:]
    /// Pobór mocy z liczników RAPL. Dotyczy procesora, nie całego komputera.
    var power = PowerStats()
    /// Poprzednia próbka liczników energii — waty biorą się z różnicy między turami.
    private var prevRAPL: RAPLSample?
    /// Zmierzone temperatury dysków, kluczowane **stabilnie**: serialem, gdy dysk go
    /// podaje, a nazwą urządzenia dopiero w ostateczności.
    ///
    /// 🔴 Litery `sd*` przydziela jądro w kolejności wykrywania i przy dyskach na USB
    /// **przetasowują się po każdym restarcie serwera**. Na serwerze testowym NONAME S100 był
    /// kolejno `sdd`, `sdc` i `sdb`. Mapa kluczowana literą pokazywała po restarcie
    /// pomiar jednego dysku przy drugim — i wyglądało to jak „dysk nagle zaczął podawać
    /// temperaturę", choć była to stara liczba po poprzednim lokatorze tej litery.
    /// Serial nie wędruje.
    private(set) var temperaturyDyskow: [String: Double] = [:]

    /// Werdykt SMART każdego dysku, kluczowany **tak samo stabilnie** co temperatury.
    ///
    /// Od 2026-09-11 kondycja nie przychodzi już z `disks/list` — to zapytanie chodzi
    /// z `skipsmart=1`, bo bez tego budziło talerzowe dyski co 5 s i nie pozwalało im
    /// zasnąć nigdy. Źródłem jest ta sama ścieżka SSH co temperatury, z `-n standby`,
    /// więc **śpiący dysk nie jest budzony** i po prostu nie ma go w tej mapie.
    private(set) var kondycjeDyskow: [String: String] = [:]

    /// Widok dla interfejsu: klucz to **bieżąca** nazwa urządzenia (`sdb`, `nvme0n1`).
    /// Składany z aktualnej listy dysków, więc litera po restarcie sama trafia
    /// do właściwego nośnika, a dysk, którego już nie ma, znika z wyniku.
    var temperatures: [String: Double] {
        var out: [String: Double] = [:]
        for d in disks {
            if let t = temperaturyDyskow[Self.kluczTemperatury(d)] { out[d.name] = t }
        }
        return out
    }

    /// Klucz mapy temperatur — serial dysku, gdy go podaje, inaczej nazwa urządzenia.
    /// Mostki USB potrafią nie przepuścić serialu i wtedy zostaje litera; to gorsze,
    /// ale nadal działa, dopóki zestaw dysków się nie zmienia.
    static func kluczTemperatury(_ disk: Disk) -> String {
        let serial = disk.serial?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return serial.isEmpty ? disk.name : serial
    }
    /// Miejsce na udziałach i magazynach pod `/mnt` — nazwa, zajęte, całość, procent.
    /// Liczone z `@@DF`, nie przepisywane z komunikatu czujki. Patrz `Miejsce.swift`.
    var udzialy: [Udzial] = []
    /// Mapa „ścieżka na hoście → nazwa" — czytana raz na połączenie, jak `cpuDetails`.
    private var nazwyMontowan: [String: NazwaMontowania] = [:]
    /// Strumienie transferu z RRD Proxmoksa — „co teraz płynie i jak dzieli się łącze".
    /// Pierwszy wiersz to węzeł, czyli całe łącze. Patrz `Transfery.swift`.
    var strumienie: [Strumien] = []

    /// Ruch na dyskach hosta — z SSH, bo RRD węzła nie zna `diskread`/`diskwrite`.
    /// Pusta lista przy wyłączonym SSH; wtedy kafel spada na `obciazenieIO`.
    var przeplywyDyskow: [PrzeplywDysku] = []

    /// Ciśnienie I/O z RRD węzła, w procentach. Zapasowy sygnał „dyski pracują",
    /// gdy nie ma SSH. `nil` znaczy „nie wiem", nie „zero".
    var obciazenieIO: Double?

    /// Trwające kopiowania na hoście. Pusta lista przy wyłączonym SSH.
    var kopie: [KopiaWToku] = []
    /// Czy RRD w ogóle oddał dane. `false` znaczy „nie ma odczytu", a to jest inna
    /// informacja niż „w sieci cisza" — bez tego rozróżnienia zerwany odczyt wygląda
    /// dokładnie jak spokojna sieć (ostrzeżenie wprost z planu monitora).
    var transferyZywe = false
    /// Historia zdarzeń — co się stało, kiedy i jak poszło. Przeżywa zgaszenie chmurki
    /// **i** restart programu. Patrz `Zdarzenia.swift`.
    let rejestr = RejestrZdarzen()
    /// Alarmy odhaczone przez użytkownika — „wiem o tym, zgaś czerwień". Patrz
    /// `PotwierdzoneAlerty.swift`; odhaczenie dotyczy jednego wystąpienia, nie mechanizmu.
    let potwierdzone = PotwierdzoneAlerty()
    /// Układ kafli — kolejność, rozmiary, pozycje na siatce i kłódki.
    ///
    /// 🔴 Stoi **w modelu, nie w `@State` widoku**, i to jest część naprawy z 2026-08-23:
    /// dwa egzemplarze biłyby się o te same klucze `UserDefaults`, każdy trzymając własną
    /// kopię w pamięci i nadpisując zapis drugiego. Model powstaje raz na uruchomienie
    /// programu, więc egzemplarz jest dokładnie jeden.
    let layout = DashboardLayout()
    var alerts: [Alert] = []
    var services: [Service] = []
    var cpu = CPUStats()             // zużycie i temperatury CPU (SSH: /proc/stat + sensors)
    var cpuDetails: CPUDetails?      // wątki, cache, gniazda — raz na połączenie (SSH: lscpu)
    var memory = MemoryStats()       // RAM: /proc/meminfo + ARC
    var gpu = GPUStats()             // GPU: nazwa (z API) + statystyki (nvidia-smi)
    var fans: [FanReading] = []      // obroty wentylatorów, z zachowanym numerem czujnika
    var cpuHistory: [Double] = []    // historia zużycia CPU % pod wykres liniowy
    /// Mechanizmy, które się uruchamiają i kończą — zadania serwera, nocna kopia
    /// z tego Maca, monitory push w Uptime Kumie. Zbierane w `Przebiegi.swift`.
    var przebiegi: [Przebieg] = []
    /// Przebiegi, które się domknęły, a użytkownik jeszcze na nie nie patrzył — liczba w chmurce
    /// przy ikonie w pasku menu. Czyszczone otwarciem panelu, nie upływem czasu.
    private(set) var nieodczytane: Set<String> = []
    var lastError: String?

    /// Kiedy dane ostatnio faktycznie przyszły z serwera. Bez tego zamrożony dashboard
    /// wygląda dokładnie tak samo jak działający.
    var lastSuccessfulRefresh: Date?

    /// Ustawione, gdy certyfikat serwera nie zgadza się z przypiętym.
    var certificateChange: CertificateChange?

    private var prevCPUJiffies: [String: CPUJiffies] = [:]   // do delty CPU%

    // SSH: realne komendy roota (nvidia-smi itd.). Włączane po udanym teście.
    var gpuSSHEnabled: Bool = UserDefaults.standard.bool(forKey: "mNas.gpuSSH") {
        // Zapis tylko przy realnej zmianie — inaczej każdy pierwszy udany odczyt po starcie
        // apki pisał do UserDefaults tę samą wartość.
        didSet {
            guard oldValue != gpuSSHEnabled else { return }
            UserDefaults.standard.set(gpuSSHEnabled, forKey: "mNas.gpuSSH")
        }
    }
    var gpuSSHError: String?

    private var client: ProxmoxClient?
    private var localNetworkBrowser: NWBrowser?
    private var refreshTask: Task<Void, Never>?
    var autoRefresh = true

    // Auto-próba SSH: klucz jest w Application Support, więc próbujemy sami.
    // Po serii błędów zwalniamy tempo, żeby nie spowalniać odświeżania.
    private var sshFailures = 0
    private var lastSSHAttempt = Date.distantPast

    /// Temperatury dysków chodzą wolniej niż reszta: `smartctl` na kilku dyskach kosztuje
    /// sekundy, a temperatura talerza nie skacze w rytm pięciosekundowego odświeżania.
    private var lastDiskTempRead = Date.distantPast
    private static let diskTempInterval: TimeInterval = 60

    /// Zapas na wypadek **wyłączonego SSH**: wtedy kondycja nie ma innego źródła niż API,
    /// a pełne `disks/list` budzi wszystkie talerze. Pół godziny to kompromis — rzadko
    /// dość, żeby dysk zdążył się wyspać, często dość, żeby `FAILED` nie wisiał dobę.
    /// Przy włączonym SSH ten licznik w ogóle nie wchodzi w grę.
    private var lastPelnySmartRead = Date.distantPast
    private static let pelnySmartInterval: TimeInterval = 30 * 60

    // MARK: Odstępy odpytywania REST — po co one są

    /// 🔴 **mNas ma być oknem pokazującym stan, nie odpytywaczem.** Polecenie
    /// 2026-09-11, dosłownie: *„to ma działać jak okno pokazujące informacje, a nie że
    /// będzie budzić i pytać wszystko co chwila — nie taki był zamysł całej aplikacji"*.
    ///
    /// Do tego dnia **każda** tura odświeżania (co 5 s) wołała cztery osobne ścieżki API:
    /// `status`, `disks/list`, `cluster/resources`, `services`, plus zadania. Zmierzone
    /// w logu `pveproxy`: ~100 tysięcy żądań na dobę do serwera, który stoi w domowej
    /// szafce i przez większość czasu nikt na niego nie patrzy.
    ///
    /// Teraz każda rzecz ma odstęp dobrany do tego, **jak szybko naprawdę się zmienia**:
    ///
    /// | Co | Odstęp | Dlaczego tyle |
    /// |---|---|---|
    /// | obciążenie węzła (CPU, RAM) | każda tura | to jedyna rzecz, która ma być „na żywo" |
    /// | maszyny i kontenery | 30 s | stan gościa zmienia się przy starcie/stopie, nie co sekundę |
    /// | nieudane zadania | 30 s | alarm spóźniony o pół minuty to nadal alarm |
    /// | usługi systemd | 60 s | jednostki nie wstają i nie padają co chwilę |
    /// | lista dysków | 10 min | model, rozmiar i serial **nie zmieniają się w ogóle** |
    ///
    /// Nie zmniejszaj tych wartości „żeby było świeżej". Świeżość kosztuje tu pracę
    /// serwera, a nie tylko ruch sieciowy.
    private var lastGuestsRead = Date.distantPast
    private var lastServicesRead = Date.distantPast
    private var lastAlertsRead = Date.distantPast
    private var lastDisksRead = Date.distantPast
    private static let guestsInterval: TimeInterval = 30
    private static let servicesInterval: TimeInterval = 60
    private static let alertsInterval: TimeInterval = 30
    private static let disksInterval: TimeInterval = 10 * 60

    /// Odstęp głównej pętli. Gdy **nie ma otwartego okna**, program siedzi w pasku menu
    /// i nikt nie patrzy na kafle — wtedy wystarczy pilnować alarmów raz na minutę.
    private static let odstepZOknem: TimeInterval = 5
    private static let odstepBezOkna: TimeInterval = 60

    /// Czy minął odstęp — i jeśli tak, od razu odnotowuje bieżący czas.
    private func minelo(_ ostatni: inout Date, _ odstep: TimeInterval) -> Bool {
        guard Date().timeIntervalSince(ostatni) >= odstep else { return false }
        ostatni = Date()
        return true
    }

    /// Ruch na dyskach czytamy rzadziej niż resztę statystyk, bo samo polecenie
    /// **trwa sekundę** — tyle dzieli dwie próbki `/proc/diskstats`. Dziesięć sekund
    /// wystarcza, żeby człowiek zobaczył trwające kopiowanie, i nie robi z odczytu
    /// dodatkowego obciążenia.
    private var lastDiskIORead = Date.distantPast
    private static let diskIOInterval: TimeInterval = 10

    // MARK: Przebiegi (mechanizmy, które się uruchamiają i kończą)

    /// Wolniejsze kanały przebiegów. Zadania z API pytamy co turę — to jedno lekkie
    /// żądanie i to ono łapie moment startu. Reszta chodzi rzadziej: `pct exec` do Kumy
    /// kosztuje sekundy (ta sama zasada co przy wykrywaniu narzędzi).
    private var lastKumaRead = Date.distantPast
    private var lastMechanizmyRead = Date.distantPast
    /// Czy od połączenia przyszła choć jedna udana lista z hosta i z Kumy. Dopiero wtedy
    /// lista przebiegów jest pełna i wolno po niej przycinać odhaczenia alarmów.
    private var mechanizmyWczytane = false
    private var kumaWczytana = false
    private var lastTransferyRead = Date.distantPast
    private var lastVzdumpRead = Date.distantPast
    private var lastZadaniaRead = Date.distantPast
    private static let zadaniaInterval: TimeInterval = 15
    private static let kumaInterval: TimeInterval = 60
    /// Zadania hosta zmieniają się przy zmianie crona, nie co turę — ale dziennik
    /// dopisuje się po każdym przebiegu, więc czytamy co minutę, jak Kumę.
    private static let mechanizmyInterval: TimeInterval = 60
    /// Licznik na hoście próbkuje co ~10 s, więc częstsze czytanie nie przyniosłoby
    /// nowych danych — przyniosłoby tylko ruch, który ten monitor ma mierzyć.
    /// Raz na minutę — RRD i tak nie ma nic nowego częściej, bo krok próbki to 60 s
    /// (zmierzone 2026-08-29). Częstsze pytanie to sam ruch, bez nowej informacji.
    private static let transferyInterval: TimeInterval = 60

    /// Ten sam odczyt, gdy **nikt nie patrzy** — bez otwartego okna kafel transferów
    /// nie jest widoczny, a jedno odświeżenie to **jedenaście** osobnych żądań `rrddata`
    /// (węzeł + każdy kontener; Proxmox nie ma odczytu zbiorczego). Zmierzone 2026-09-11:
    /// to była największa pozycja w ruchu apki, ~38% wszystkich żądań.
    ///
    /// 🔴 **Nie zjeżdżaj z 60 s przy otwartym oknie.** Krok próbki RRD to 60 s, więc
    /// rzadsze pytanie **gubi próbki** i kafel zaczyna kłamać o tym, co przepłynęło —
    /// a nie tylko „odświeża się wolniej".
    private static let transferyIntervalBezOkna: TimeInterval = 5 * 60
    private static let vzdumpInterval: TimeInterval = 120

    // Powrót po zerwaniu połączenia.
    private var reconnectTask: Task<Void, Never>?
    private static let reconnectDelays = [5, 10, 30, 60]     // sekundy
    /// Numer bieżącej próby powrotu (0 = nie próbujemy).
    private(set) var reconnectAttempt = 0
    /// Odstęp, po którym poleci bieżąca próba — do pokazania w banerze.
    private(set) var reconnectDelay = 0
    /// Klucz API bieżącej sesji. Trzymany tylko w pamięci, żeby dało się wrócić po
    /// zerwaniu także wtedy, gdy użytkownik nie kazał zapamiętać klucza na stałe.
    private var sessionKey: String?

    // Sterowanie PWM.
    /// Kanały, które przestawiła w tryb ręczny **ta** sesja aplikacji. Tylko dla nich
    /// przywracamy automat — bezwarunkowe przywracanie skasowałoby konfigurację, którą
    /// użytkownik ustawił świadomie wcześniej (np. własnym `fancontrol` na serwerze).
    private(set) var manualPWMPaths: Set<String> = []
    /// Czy użytkownik potwierdził w tej sesji przejście wentylatorów w tryb ręczny.
    var pwmManualConfirmed = false
    var hasManualPWM: Bool { !manualPWMPaths.isEmpty }

    /// Konto do SSH — **nie to samo** co identyfikator tokenu API.
    ///
    /// Token wygląda `root@pam!mnas`; SSH potrzebuje samego `root`. Wyciągamy część przed
    /// `@`, więc jedno pole w interfejsie obsługuje oba kanały i nie da się ich rozjechać.
    var sshUser: String {
        let head = username.split(separator: "@").first.map(String.init) ?? username
        return head.isEmpty ? "root" : head
    }

    private var commands: ServerCommands { ServerCommands(host: host, user: sshUser) }

    init() {
        if let savedHost = Keychain.loadHost() { host = savedHost }
        if let savedUser = Keychain.loadUsername() { username = savedUser }
    }

    var hasSavedKey: Bool { Keychain.loadAPIKey() != nil }

    /// Procent użycia CPU do pokazania: dokładny z SSH, a gdy go nie ma — przybliżony
    /// z obciążenia (loadavg / rdzenie). Nigdy nie pokazujemy surowego „0.30".
    var cpuUsagePercent: Double? {
        if let u = cpu.averageUsage { return u }
        if let load = systemInfo?.loadavg?.first, let cores = systemInfo?.cores, cores > 0 {
            return min(100, max(0, load / Double(cores) * 100))
        }
        return nil
    }

    /// Czy `cpuUsagePercent` jest przybliżony (brak dokładnego pomiaru z SSH).
    var cpuUsageApprox: Bool { cpu.averageUsage == nil }

    // MARK: - Łączenie

    func connectUsingSavedKey() async {
        guard let key = Keychain.loadAPIKey() else {
            status = .failed(String(localized: "Brak zapisanego klucza API."))
            return
        }
        await connect(apiKey: key, saveKey: false)
    }

    func connect(apiKey rawKey: String, saveKey: Bool) async {
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelReconnect()
        status = .connecting
        lastError = nil
        certificateChange = nil

        // Bonjour „budzi" systemowy prompt zgody na Sieć lokalną.
        // Połączenie do samego adresu IP tego promptu nie wywołuje — Bonjour tak.
        requestLocalNetworkAccess()

        let client = ProxmoxClient(host: host)
        self.client = client
        do {
            // REST jest bezstanowy — jeden strzał sprawdza token i wykrywa węzeł.
            try await client.connect(tokenID: username, secret: apiKey)
            nodeName = await client.node
            if saveKey { Keychain.saveAPIKey(apiKey) }
            sessionKey = apiKey
            Keychain.saveHost(host)
            Keychain.saveUsername(username)
            status = .connected
            await refresh()
            startAutoRefresh()
        } catch {
            noteCertificateProblem(error)
            Log.connection.error("Błąd połączenia: \(String(describing: error), privacy: .public)")
            status = .failed(friendly(error))
            await client.disconnect()
            self.client = nil
        }
    }

    /// Nazwa węzła wykryta po połączeniu (np. `pve`) — do pokazania w nagłówku.
    private(set) var nodeName: String?

    func disconnect() async {
        cancelReconnect()
        stopAutoRefresh()
        // Zanim zerwiemy kanał: oddaj wentylatory układowi. Inaczej kanały przestawione
        // suwakiem zostają w trybie ręcznym, a układ przestaje regulować obroty.
        //
        // Tylko przy żywym połączeniu: gdy rozłączamy się z banera „wracam sam", serwer
        // i tak nie odpowiada, a każda próba kończyłaby się limitem czasu — apka stałaby
        // wtedy w miejscu na przycisku „Rozłącz".
        if status == .connected {
            await restorePWMAuto()
        } else if hasManualPWM {
            Log.ssh.error("Rozłączenie przy martwym kanale — kanały PWM zostają w trybie ręcznym")
            manualPWMPaths.removeAll()
        }
        await client?.disconnect()
        client = nil
        sessionKey = nil
        nodeName = nil
        systemInfo = nil
        guests = []
        disks = []
        temperaturyDyskow = [:]
        kondycjeDyskow = [:]
        udzialy = []
        strumienie = []
        transferyZywe = false
        przeplywyDyskow = []
        obciazenieIO = nil
        kopie = []
        // Nazwy też idą z połączeniem — po podpięciu innego serwera stara mapa
        // podstawiłaby cudze nazwy pod te same ścieżki.
        nazwyMontowan = [:]
        alerts = []
        services = []
        cpu = CPUStats()
        memory = MemoryStats()
        gpu = GPUStats()
        fans = []
        cpuHistory = []
        prevCPUJiffies = [:]
        // Przebiegi serwera i Kumy idą razem z połączeniem. Kopia z **tego Maca** zostaje:
        // ona nie zależy od serwera i po rozłączeniu nadal jest prawdziwa.
        przebiegiTrwajace = []
        przebiegiZakonczone = []
        przebiegiKumy = []
        przebiegiHosta = []
        poprzednieStany = [:]
        nieodczytane = []
        lastKumaRead = .distantPast
        lastMechanizmyRead = .distantPast
        lastAktualizacjeRead = .distantPast
        aktualizacje = nil
        zleconoAktualizacje = nil
        bladAktualizacji = nil
        mechanizmyWczytane = false
        kumaWczytana = false
        lastTransferyRead = .distantPast
        lastVzdumpRead = .distantPast
        zlozPrzebiegi()
        lastError = nil
        lastSuccessfulRefresh = nil
        pwmManualConfirmed = false
        status = .disconnected
    }

    func forgetSavedKey() {
        Keychain.deleteAPIKey()
        sessionKey = nil
    }

    /// Uruchamia przeglądarkę Bonjour, żeby macOS pokazał okno zgody „Sieć lokalna".
    /// Samo łączenie do adresu IP tego okna nie wywołuje — rozgłoszenie mDNS/Bonjour tak.
    func requestLocalNetworkAccess() {
        guard localNetworkBrowser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        browser.stateUpdateHandler = { state in
            Log.connection.debug("Bonjour (prompt Sieci lokalnej): \(String(describing: state), privacy: .public)")
        }
        browser.start(queue: .main)
        localNetworkBrowser = browser
    }

    // MARK: - Certyfikat serwera

    private func noteCertificateProblem(_ error: Error) {
        guard let ce = error as? ProxmoxClient.ClientError,
              case .certificateMismatch(let expected, let received) = ce else { return }
        certificateChange = CertificateChange(host: host, expected: expected, received: received)
    }

    /// Zatwierdza nowy certyfikat serwera i łączy się jeszcze raz.
    ///
    /// Ta ścieżka musi istnieć: bez niej przypięcie certyfikatu (P1-02) zamieniłoby lukę
    /// w blokadę — po reinstalacji TrueNAS-a albo wymianie certyfikatu apka przestałaby się
    /// łączyć bez żadnego wyjścia. Decyzja jest świadoma i należy do użytkownika, dlatego
    /// UI pokazuje przy niej oba odciski.
    func trustNewCertificate() async {
        guard let change = certificateChange else { return }
        CertificatePin.store(change.received, for: change.host)
        certificateChange = nil
        Log.certificate.notice("Użytkownik zatwierdził nowy certyfikat \(change.host, privacy: .public)")
        if let key = sessionKey ?? Keychain.loadAPIKey() {
            await connect(apiKey: key, saveKey: false)
        } else {
            status = .disconnected
        }
    }

    // MARK: - Odświeżanie danych

    func refresh() async {
        guard let client, status == .connected else { return }
        do {
            // Trzy niezależne żądania REST równolegle — szeregowo dawałyby trzy pełne
            // czasy podróży w każdej turze odświeżania (co 5 s).
            // Obciążenie węzła — jedyna rzecz wołana w KAŻDEJ turze. To ona ma być
            // „na żywo"; czyta `/proc` na serwerze i nie dotyka żadnego dysku.
            let node = try await client.nodeSnapshot()
            systemInfo = node.info
            applyAPIMeasurements(node)

            // Lista dysków raz na 10 minut: model, rozmiar i serial się nie zmieniają.
            // Pusta lista = serwer jeszcze wstawał (zaraz po restarcie hosta) — ponów po 30 s,
            // nie po 10 min — kafel Dyski długo czekał na pierwszy odczyt (2026-10-16).
            if minelo(&lastDisksRead, disks.isEmpty ? 30 : Self.disksInterval) {
                // Pełny SMART z API **tylko** gdy SSH jest wyłączony i minęło pół godziny —
                // każde takie zapytanie budzi talerzowe dyski. Przy działającym SSH kondycja
                // idzie ścieżką `-n standby`, która ich nie rusza.
                let pelnySmart = !gpuSSHEnabled
                    && Date().timeIntervalSince(lastPelnySmartRead) >= Self.pelnySmartInterval
                if pelnySmart { lastPelnySmartRead = Date() }
                disks = try await client.disks(skipSmart: !pelnySmart)
                if pelnySmart { Self.zbierzKondycje(z: disks, do: &kondycjeDyskow) }
            }
            // Przy `skipsmart=1` API oddaje `health: UNKNOWN`. Nakładamy to, co wiemy
            // ze ścieżki SSH; czego nie wiemy, zostaje `UNKNOWN` — a `OstrzezeniaDyskow`
            // jawnie je pomija, więc śpiący dysk NIE robi fałszywego alarmu.
            // Nakładamy w każdej turze, bo kondycja dochodzi między odczytami listy.
            Self.nalozKondycje(kondycjeDyskow, na: &disks)

            // Reszta jest „miła do posiadania": brak uprawnień tokenu do zadań albo do
            // gości nie może wywalić całego odświeżania, więc każde leci osobno i cicho.
            if minelo(&lastGuestsRead, Self.guestsInterval) {
                guests = (try? await client.guests()) ?? guests
            }
            if minelo(&lastServicesRead, Self.servicesInterval) {
                services = (try? await client.services()) ?? []
            }
            // Nieudany odczyt zostawia poprzednią listę — tak samo jak `guests` wyżej.
            // Ale pusta odpowiedź **serwera** czyści alerty, bo to znaczy „zadania naprawione".
            // Stąd `Optional` po stronie klienta: bez niego jedno potknięcie sieci wyglądało
            // jak „problem sam zniknął", a zachowywanie każdej pustej listy zamroziłoby
            // alerty na ekranie na zawsze.
            if minelo(&lastAlertsRead, Self.alertsInterval) {
                alerts = await client.failedTaskAlerts() ?? alerts
            }

            // Statystyki na żywo przez SSH: CPU% (agg+per-core), RAM, temperatury CPU,
            // wentylatory, GPU, temperatury dysków. Pewne — /proc + sensors + nvidia-smi.
            // Ten kanał przeszedł z wersji TrueNAS bez zmian: Proxmox to Debian z rootem,
            // więc te same komendy działają 1:1.
            await maybeRefreshStatsViaSSH()
            // Punkt na wykresie dopiero teraz: gdy SSH działa, trafia tam jego dokładniejszy
            // pomiar, a gdy nie — ten z API. Zawsze dokładnie jeden na turę.
            appendCPUHistory()
            await maybeRefreshDiskTemperatures()
            await maybeRefreshRuchDyskow()
            // Przebiegi: zadania serwera co turę (to one łapią moment startu), Kuma
            // i kopia z Maca rzadziej — własne odstępy pilnuje `odswiezPrzebiegi`.
            await odswiezPrzebiegi()
            await odswiezAktualizacjeWPetli()
            // Narzędzie z nieistniejącego już kontenera znika **natychmiast**, bez
            // czekania na powolne `pct exec`: listę gości mamy z tej samej tury.
            let running = Set(guests.filter(\.running).map(\.vmid))
            if !running.isEmpty {
                webServices.removeAll { !running.contains($0.vmid) }
            }

            // Wykrycie leci przy pierwszym udanym połączeniu SSH i za każdym razem,
            // gdy zestaw działających kontenerów przestaje się zgadzać z tym, na
            // którym zbudowano obecną listę.
            if gpuSSHEnabled, !discoveringServices,
               webServices.isEmpty || runningContainerKey != lastDiscoveryKey {
                await discoverWebServices()
            }
            lastError = nil
            lastSuccessfulRefresh = Date()
        } catch {
            lastError = friendly(error)
            // Zerwany transport to nie jest „błąd do pokazania i zapomnienia" — to sygnał,
            // że trzeba wracać do serwera. Bez tego `status` zostawał `.connected` na zawsze,
            // a dashboard zamarzał na danych sprzed awarii (klasycznie: własny przycisk
            // „Restart serwera").
            if isConnectionLost(error) {
                handleConnectionLoss()
            } else if isPermissionDenied(error) {
                // Token odrzucony albo bez uprawnień. Ponawianie tego nie naprawi, a pętla
                // auto-odświeżania waliła w serwer co 5 s bez końca — zmierzone w poprzednim
                // audycie: 171 nieudanych żądań w ~10 minut. Zatrzymujemy pętlę i zostawiamy
                // ręczny przycisk „Odśwież", tak samo jak przy `.giveUp` w pętli powrotu.
                stopAutoRefresh()
                Log.connection.error("Serwer odrzucił żądanie (401/403) — zatrzymuję auto-odświeżanie")
            }
        }
    }

    /// Czy serwer odrzucił żądanie z powodu tożsamości, a nie awarii łącza.
    ///
    /// Świadomie osobno od `isConnectionLost`: tamto pyta „czy warto ponawiać", to pyta
    /// „czy ponawianie ma jakikolwiek sens" — a przy 401/403 nie ma, dopóki nie zmieni się
    /// token albo jego uprawnienia na serwerze.
    private func isPermissionDenied(_ error: Error) -> Bool {
        guard let ce = error as? ProxmoxClient.ClientError else { return false }
        switch ce {
        case .authFailed: return true
        case .http(let status, _): return status == 401 || status == 403
        default: return false
        }
    }

    /// Przepisuje pomiary z API do kafli i dokłada punkt do wykresu CPU.
    ///
    /// Kolejność względem SSH jest celowa: API leci **pierwsze**, a `refreshStatsViaSSH()`
    /// zaraz potem nadpisuje CPU i RAM dokładniejszymi liczbami z `/proc` i dokłada to,
    /// czego API nie ma w ogóle (rdzenie osobno, temperatury, ARC). Dzięki temu dashboard
    /// jest wypełniony od pierwszej sekundy, a po włączeniu SSH robi się dokładniejszy —
    /// zamiast stać pusty i czekać.
    private func applyAPIMeasurements(_ node: NodeSnapshot) {
        memory.total = node.memoryTotal ?? node.info.physmem?.value

        if let usage = node.cpuUsage {
            cpu.averageUsage = usage
        }

        // Rozbicie RAM bez ARC: Proxmox na LVM-thin nie ma ZFS-a, więc „Cache ZFS"
        // zostaje puste i to jest poprawny stan, nie brak danych.
        //
        // 🔴 `node.memoryFree` niesie **`MemAvailable`**, nie `MemFree` — i to jest warunek
        // tego, żeby kafel nie migał. Zgłoszenie 2026-08-20: „RAM co 5 sekund na sekundę
        // pokazuje się prawie cały zajęty". Przyczyną było, że API i SSH mierzyły **dwie
        // różne rzeczy**, a piszą do jednego pola w tej samej turze: API dawał `MemFree`
        // (zmierzone na serwerze testowym: 309 MB, czyli 96% zajęcia), sekundę później SSH nadpisywał
        // to `MemAvailable` (5,37 GB, czyli 34%). Widać było migotanie, nie pomiar.
        // `services` liczymy więc też sami, zamiast brać `memory.used` z API — tamto stoi
        // na `MemFree` i po zmianie licznika nie sumowałoby się z resztą kafla.
        if let free = node.memoryFree {
            memory.free = free
            memory.services = node.memoryTotal.map { max(0, $0 - free) } ?? node.memoryUsed
        }
    }

    /// Dokłada jeden punkt do wykresu „Zużycie CPU w czasie".
    ///
    /// Wołane **raz na turę odświeżania**, po API i po SSH — wcześniej dopisywał to
    /// wyłącznie odczyt SSH, więc bez skonfigurowanego klucza wykres stał pusty na zawsze
    /// („0 pomiarów"), mimo że liczba procentowa była znana.
    private func appendCPUHistory() {
        guard let usage = cpu.averageUsage else { return }
        cpuHistory.append(usage)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
    }

    // MARK: - Powrót po zerwaniu połączenia

    /// Czy błąd oznacza „transport padł" — w odróżnieniu od odrzuconego logowania
    /// albo błędu konkretnej metody middleware, przy których ponawianie nie ma sensu.
    private func isConnectionLost(_ error: Error) -> Bool {
        if let ce = error as? ProxmoxClient.ClientError {
            switch ce {
            case .connectionClosed, .notConnected, .timeout: return true
            // 5xx to padnięty `pveproxy` — serwer wróci sam, więc traktujemy jak zerwanie
            // i ponawiamy. 4xx (zły token, brak uprawnień) ponawianiem się nie naprawi.
            case .http(let status, _): return status >= 500
            default: return false
            }
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorTimedOut:
            return true
        default:
            return false
        }
    }

    private func handleConnectionLoss() {
        guard status == .connected else { return }
        Log.connection.notice("Połączenie zerwane — przechodzę w tryb ponawiania")
        stopAutoRefresh()
        status = .reconnecting
        startReconnectLoop()
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        reconnectDelay = 0
    }

    /// Ponawia `connect` z rosnącym odstępem (5 / 10 / 30 / 60 s, potem co minutę),
    /// żeby restart serwera „sam się zagoił".
    private func startReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var step = 0
            while !Task.isCancelled {
                guard let self, self.status == .reconnecting else { return }
                let delay = Self.reconnectDelays[min(step, Self.reconnectDelays.count - 1)]
                self.reconnectAttempt = step + 1
                self.reconnectDelay = delay
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                guard !Task.isCancelled, self.status == .reconnecting else { return }

                switch await self.attemptReconnect() {
                case .success:
                    return
                case .giveUp(let message):
                    self.status = .failed(message)
                    self.reconnectAttempt = 0
                    self.reconnectDelay = 0
                    return
                case .retry:
                    step += 1
                }
            }
        }
    }

    private enum ReconnectOutcome {
        case success
        case retry
        case giveUp(String)
    }

    private func attemptReconnect() async -> ReconnectOutcome {
        guard let key = sessionKey ?? Keychain.loadAPIKey() else {
            return .giveUp(String(localized: "Połączenie zerwane, a klucz API nie jest zapamiętany — połącz się ponownie."))
        }
        await client?.disconnect()
        client = nil

        let fresh = ProxmoxClient(host: host)
        do {
            try await fresh.connect(tokenID: username, secret: key)
        } catch {
            await fresh.disconnect()
            if let ce = error as? ProxmoxClient.ClientError {
                switch ce {
                case .authFailed(let message):
                    // Serwer odpowiada, ale odrzuca token (np. skasowany na serwerze).
                    // Dalsze próby to już tylko seria nieudanych uwierzytelnień —
                    // zatrzymujemy się i czekamy na użytkownika.
                    return .giveUp(message)
                case .http(let status, _) where status == 401 || status == 403:
                    return .giveUp(ce.errorDescription ?? String(localized: "Token API odrzucony."))
                case .certificateMismatch, .certificateUnreadable, .pinStoreUnreadable:
                    noteCertificateProblem(error)
                    return .giveUp(ce.errorDescription ?? String(localized: "Problem z certyfikatem serwera."))
                default:
                    break
                }
            }
            lastError = friendly(error)
            return .retry
        }

        client = fresh
        sessionKey = key
        nodeName = await fresh.node
        status = .connected
        reconnectAttempt = 0
        reconnectDelay = 0
        lastError = nil
        Log.connection.notice("Połączenie odzyskane")
        await refresh()
        startAutoRefresh()
        return .success
    }

    // MARK: - SSH (statystyki na żywo)

    /// Klucz publiczny mNas do wklejenia na serwerze (generuje parę przy pierwszym użyciu).
    func sshPublicKey() async -> String? {
        await Task.detached { SSHRunner.ensureKey() }.value
    }

    /// Test połączenia SSH. Po sukcesie włącza stały odczyt statystyk przez SSH.
    func testSSH() async -> (ok: Bool, message: String) {
        let r = await commands.connectivityTest()
        guard r.ok else {
            let e = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = e.isEmpty
                ? String(localized: "SSH nie połączył (kod \(r.code)). Sprawdź: usługa SSH włączona na serwerze, klucz wklejony do użytkownika, konto ma dostęp do powłoki.")
                : e
            gpuSSHError = msg
            return (false, msg)
        }
        gpuSSHEnabled = true
        gpuSSHError = nil
        await refreshStatsViaSSH()
        // Dopiero teraz można wejść do kontenerów — wykrywanie narzędzi idzie tym samym kanałem.
        await discoverWebServices()
        if r.output.contains("NO-NVIDIA") {
            return (true, String(localized: "SSH działa — CPU, RAM, temperatury i wentylatory będą się odświeżać. GPU pojawi się po włączeniu sterownika NVIDIA na serwerze."))
        }
        return (true, String(localized: "SSH działa. CPU, RAM, GPU, temperatury i wentylatory odświeżają się na żywo."))
    }

    /// Automatyczna próba pobrania statystyk przez SSH z backoffem.
    /// Po 3 błędach z rzędu próbujemy najwyżej co 30 s, żeby nie dławić odświeżania.
    private func maybeRefreshStatsViaSSH() async {
        if sshFailures >= 3, Date().timeIntervalSince(lastSSHAttempt) < 30 { return }
        lastSSHAttempt = Date()
        await refreshStatsViaSSH()
    }

    /// Temperatury dysków, ale nie częściej niż raz na minutę.
    ///
    /// Odczyt idzie przez `smartctl`, bo Proxmox nie ma odpowiednika `disk.temperatures`
    /// z API TrueNAS-a. Odczyt uśpionego dysku nic nie zwraca (`-n standby`) i wtedy
    /// **zostawiamy poprzednie wartości** zamiast czyścić kafel — inaczej temperatury
    /// migałyby przy każdym uśpieniu dysku w kieszeni USB.
    /// Ruch na dyskach i trwające kopiowania — dwa odczyty SSH, oba co 10 s.
    ///
    /// > [!info] Po co, skoro kafel „Transfery" ma już RRD
    /// > Bo RRD mierzy **łącze**, a kopia z dysku na dysk wewnątrz hosta przez łącze
    /// > nie przechodzi. Zgłoszenie 2026-09-04: kafel pokazywał 16 kB/s w chwili,
    /// > gdy dyski robiły 90 MB/s. Ani kafel, ani RRD nie kłamały — po prostu nie o tym
    /// > mówiły. Pola `diskread`/`diskwrite` ma w RRD wyłącznie kontener, nie węzeł.
    ///
    /// Bez SSH cicho odpuszczamy: kafel spada wtedy na `obciazenieIO` z RRD, które
    /// nie poda megabajtów, ale odróżni pracę od ciszy.
    ///
    /// 🔴 Nieudany odczyt **czyści** listy zamiast zostawiać poprzednie. Inaczej niż
    /// przy temperaturach dysków, gdzie stara wartość jest lepsza niż żadna — tutaj
    /// nieaktualne „kopiuje się 90 MB/s" wisiałoby na ekranie po zakończeniu kopii
    /// i mówiło nieprawdę o teraźniejszości.
    private func maybeRefreshRuchDyskow() async {
        guard gpuSSHEnabled else { return }
        guard Date().timeIntervalSince(lastDiskIORead) >= Self.diskIOInterval else { return }
        lastDiskIORead = Date()

        let dyski = await commands.przeplywDyskow()
        przeplywyDyskow = dyski.ok ? TransferyParsers.przeplywyDyskow(dyski.output) : []

        let trwajace = await commands.kopieWToku()
        kopie = trwajace.ok ? TransferyParsers.kopie(trwajace.output) : []
    }

    private func maybeRefreshDiskTemperatures() async {
        guard gpuSSHEnabled, !disks.isEmpty else { return }
        guard Date().timeIntervalSince(lastDiskTempRead) >= Self.diskTempInterval else { return }
        lastDiskTempRead = Date()
        let r = await commands.diskTemperatures(disks: disks.map(\.name))
        guard !r.timedOut else { return }
        let raporty = StatsParsers.diskTemperatureReports(r.output)
        // Kondycja idzie z tego samego wyjścia — jedno wywołanie `smartctl`, dwa odczyty.
        // Dysk, który spał, nie ma tu wpisu i poprzednia znana wartość zostaje nietknięta.
        let kondycje = StatsParsers.diskHealth(r.output)
        if !kondycje.isEmpty {
            Self.nalozKondycje(kondycje, dyski: disks, na: &kondycjeDyskow)
            Self.nalozKondycje(kondycjeDyskow, na: &disks)
        }
        guard !raporty.isEmpty else { return }
        Self.nalozRaporty(raporty, dyski: disks, na: &temperaturyDyskow)
    }

    /// Nakłada świeże raporty `smartctl` na mapę temperatur kluczowaną stabilnie.
    ///
    /// Wydzielone z `maybeRefreshDiskTemperatures`, bo cała trudność siedzi tutaj
    /// i bez serwera inaczej się jej nie sprawdzi. Trzy przypadki, trzy różne skutki:
    ///
    /// | Raport | Co robimy | Dlaczego |
    /// |---|---|---|
    /// | `wartosc` | zapisz | mamy pomiar |
    /// | `brakCzujnika` | **skasuj klucz** | dysk odpowiedział, czujnika nie ma i nie będzie |
    /// | `brakOdpowiedzi` | zostaw stare | śpi, za chwilę poda — miganie byłoby gorsze |
    static func nalozRaporty(_ raporty: [String: StatsParsers.OdczytTemperatury],
                             dyski: [Disk],
                             na mapa: inout [String: Double]) {
        let kluczePoNazwie = Dictionary(dyski.map { ($0.name, kluczTemperatury($0)) },
                                        uniquingKeysWith: { pierwszy, _ in pierwszy })
        for (nazwa, raport) in raporty {
            guard let klucz = kluczePoNazwie[nazwa] else { continue }
            switch raport {
            case .wartosc(let t):   mapa[klucz] = t
            case .brakCzujnika:     mapa.removeValue(forKey: klucz)
            case .brakOdpowiedzi:   break
            }
        }
    }

    /// Świeże werdykty SMART (klucz = nazwa urządzenia) → mapa kluczowana stabilnie.
    ///
    /// Bliźniacza do `nalozRaporty`, ale prostsza: `smartctl` albo werdykt podał, albo nie.
    /// Brak wpisu znaczy „dysk spał" i **nie kasuje** poprzednio znanej wartości — inaczej
    /// kafel gubiłby kondycję za każdym razem, gdy dysk pójdzie spać.
    static func nalozKondycje(_ swieze: [String: String],
                              dyski: [Disk],
                              na mapa: inout [String: String]) {
        let kluczePoNazwie = Dictionary(dyski.map { ($0.name, kluczTemperatury($0)) },
                                        uniquingKeysWith: { pierwszy, _ in pierwszy })
        for (nazwa, werdykt) in swieze {
            guard let klucz = kluczePoNazwie[nazwa] else { continue }
            mapa[klucz] = werdykt
        }
    }

    /// Wpisuje znane werdykty w listę dysków, żeby reszta apki czytała je tak jak dotąd —
    /// z `Disk.health`. Dzięki temu kafel, ostrzeżenia i pasek menu nie wiedzą, że źródło
    /// się zmieniło, i nie trzeba było ruszać ich sygnatur ani testów.
    static func nalozKondycje(_ mapa: [String: String], na dyski: inout [Disk]) {
        guard !mapa.isEmpty else { return }
        for i in dyski.indices {
            if let werdykt = mapa[kluczTemperatury(dyski[i])] { dyski[i].health = werdykt }
        }
    }

    /// Zbiera kondycję z **pełnej** odpowiedzi API do mapy — używane tylko wtedy, gdy SSH
    /// jest wyłączony i kondycja przyszła z `disks/list` bez `skipsmart`.
    static func zbierzKondycje(z dyski: [Disk], do mapa: inout [String: String]) {
        for d in dyski {
            guard let h = d.health, !h.isEmpty, h.uppercased() != "UNKNOWN" else { continue }
            mapa[kluczTemperatury(d)] = h
        }
    }

    // MARK: - Przebiegi
    //
    // Trzy kanały trzymane osobno i sklejane dopiero na wyjściu. Gdyby leżały w jednej
    // tablicy, jedno nieudane `pct exec` do Kumy kasowałoby z ekranu trwające zadanie
    // serwera — czyli dokładnie to, po co ten kafel powstał.

    /// Zadania serwera, które chodzą **teraz**.
    private var przebiegiTrwajace: [Przebieg] = []
    /// Ile razy serwer nie podał wyniku zadania, które zniknęło z aktywnych (np. w czasie restartu hosta).
    private var probyWynikuZadania: [String: Int] = [:]
    /// Tury są co 15 s i tylko przy połączeniu — 20 prób to ok. 5 minut z serwerem na linii.
    private static let maksProbWynikuZadania = 20
    /// Ostatnio zakończone zadania serwera — pamiętane, żeby po starcie apki było widać,
    /// czy nocna kopia przeszła. Trzymamy kilka, nie wszystkie: to kafel, nie dziennik.
    private var przebiegiZakonczone: [Przebieg] = []
    private var przebiegiKumy: [Przebieg] = []
    /// Zadania, które host naprawdę uruchamia — z crona, timerów i ich dzienników.
    private var przebiegiHosta: [Przebieg] = []
    /// Stan każdego przebiegu z poprzedniej tury — po nim poznajemy **zmianę**, a alarm
    /// należy się za zmianę, nie za stan. Bez tego każde odświeżenie powtarzałoby
    /// powiadomienie o tej samej nieudanej kopii.
    private var poprzednieStany: [String: Przebieg.Stan] = [:]
    private static let maksZakonczonych = 4

    /// Ile trwa najdłuższy sensowny przebieg, zanim uznamy, że coś się zacięło.
    ///
    /// Zmierzone na serwerze testowym 2026-08-19: całe nocne zadanie (osiem kontenerów, 3,1 GB)
    /// zeszło w **8,5 minuty**. Limit 45 minut to pięciokrotny zapas — ma łapać przebieg,
    /// który stanął, a nie taki, który trafił na wolniejszy dysk.
    private static let limitVzdump: Double = 45 * 60

    /// Ostatni pomiar rosnącego archiwum: ścieżka, rozmiar i chwila odczytu.
    /// Prędkość to różnica dwóch takich próbek — dokładnie ta sama zasada, co przy
    /// CPU (`/proc/stat`) i przy poborze mocy (liczniki RAPL).
    private var poprzedniPomiarArchiwum: (sciezka: String, bajty: Int64, kiedy: Date)?

    func odswiezPrzebiegi() async {
        await odswiezZadaniaSerwera()
        await odswiezOstatniaKopieZapasowa()
        await odswiezMechanizmyHosta()
        await odswiezTransfery()
        await odswiezKume()
        zlozPrzebiegi()
    }

    /// Zadania trwające teraz + wyłapanie tych, które właśnie się skończyły.
    ///
    /// 🔴 **Odstęp 15 s, nie co turę** — zmiana 2026-09-11 na polecenie. Poprzednio
    /// leciało to w **każdej** turze odświeżania, czyli co 5 s, i razem z `rrddata`
    /// odpowiadało za ~69% całego ruchu apki do serwera (zmierzone w logu `pveproxy`).
    ///
    /// Poprzedni komentarz bronił tempa słowami „to one łapią moment startu". Nadal go
    /// łapią — tylko z opóźnieniem do 15 s. Kopia nocna trwa kilkanaście minut, więc
    /// piętnaście sekund nie zmienia niczego w tym, co widzisz na kaflu.
    private func odswiezZadaniaSerwera() async {
        guard let client, status == .connected else { return }
        guard minelo(&lastZadaniaRead, Self.zadaniaInterval) else { return }
        guard let aktywne = await client.aktywneZadania() else { return }

        var nowe: [Przebieg] = []
        for zadanie in aktywne {
            guard let upid = zadanie.upid else { continue }
            var p = Przebieg(id: upid,
                             nazwa: nazwaZadania(zadanie),
                             zrodlo: .serwer,
                             stan: .trwa,
                             start: zadanie.poczatek)
            if zadanie.type == "vzdump" {
                p.limitSekund = Self.limitVzdump
                if let log = await client.logZadania(upid: upid) {
                    let postep = PrzebiegiParsers.vzdumpPostep(log: log)
                    p.faza = postep.faza
                    if postep.wszystkich > 0 {
                        p.zrobionych = postep.zrobionych
                        p.wszystkich = postep.wszystkich
                    }
                    if let biezacy = postep.biezacy {
                        p.opis = nazwaGoscia(biezacy)
                    }
                    // Tempo z logu to wartość zastępcza: dotyczy **zakończonej** fazy
                    // i potrafi być sprzed minuty. Bieżący pomiar, jeśli się uda,
                    // nadpisuje ją niżej i podnosi `predkoscBiezaca`.
                    p.predkosc = postep.predkoscZLogu
                    await zmierzTempoArchiwum(&p, sciezka: postep.sciezkaArchiwum)
                }
            }
            nowe.append(p)
        }

        // Zadanie, które zniknęło z listy aktywnych, właśnie się skończyło. Dopiero
        // teraz pytamy o jego wynik — jedno żądanie na zakończony przebieg, nie na turę.
        let byly = Set(przebiegiTrwajace.map(\.id))
        let sa = Set(nowe.map(\.id))
        for upid in byly.subtracting(sa) {
            guard var skonczony = przebiegiTrwajace.first(where: { $0.id == upid }) else { continue }
            // Brak odpowiedzi to nie błąd zadania: przy restarcie hosta zatrzymania kontenerów
            // znikały z listy aktywnych razem z serwerem, a w Proxmoksie kończyły się OK —
            // mNas pokazywał „Zatrzymanie kontenera … błąd” (2026-10-16).
            // Zostaje „trwa” i pytamy znowu w następnej turze, aż do limitu prób.
            guard let e = await client.wynikZadania(upid: upid)?.exitstatus else {
                let proby = (probyWynikuZadania[upid] ?? 0) + 1
                if proby < Self.maksProbWynikuZadania {
                    probyWynikuZadania[upid] = proby
                    nowe.append(skonczony)
                } else {
                    probyWynikuZadania[upid] = nil
                    skonczony.stan = .nieznany
                    skonczony.koniec = Date()
                    skonczony.faza = nil
                    zapamietajZakonczony(skonczony)
                }
                continue
            }
            probyWynikuZadania[upid] = nil
            skonczony.stan = e == "OK" ? .udany : .bledny
            skonczony.koniec = Date()
            skonczony.faza = nil
            if e != "OK" { skonczony.opis = e }
            zapamietajZakonczony(skonczony)
        }
        przebiegiTrwajace = nowe
    }

    /// Ostatnia kopia zapasowa — żeby po uruchomieniu apki w południe było widać,
    /// czy ta z 02:30 w ogóle przeszła. Bez tego kafel byłby pusty przez cały dzień.
    private func odswiezOstatniaKopieZapasowa() async {
        guard let client, status == .connected else { return }
        guard Date().timeIntervalSince(lastVzdumpRead) >= Self.vzdumpInterval else { return }
        lastVzdumpRead = Date()
        guard let zadania = await client.ostatnieZadania(rodzaj: "vzdump", limit: 5) else { return }
        // Interesuje nas **zadanie**, czyli wpis bez numeru gościa: to ono obejmuje
        // wszystkie kontenery. Wpisy per kontener są jego częściami i powtarzałyby to samo.
        guard let ostatnie = zadania.first(where: { ($0.id ?? "").isEmpty && !$0.trwa })
                ?? zadania.first(where: { !$0.trwa }),
              let upid = ostatnie.upid else { return }
        var p = Przebieg(id: upid,
                         nazwa: nazwaZadania(ostatnie),
                         zrodlo: .serwer,
                         stan: ostatnie.status == "OK" ? .udany : .bledny,
                         start: ostatnie.poczatek,
                         koniec: ostatnie.kres)
        if let s = ostatnie.status, s != "OK" { p.opis = s }
        zapamietajZakonczony(p)
    }

    /// Bieżąca prędkość zapisu, liczona z **przyrostu pliku archiwum**.
    ///
    /// 🔴 Robimy to sami, bo log `vzdump` żywego tempa nie podaje — zmierzone na
    /// biegnącym zadaniu 2026-08-20: przy pakowaniu archiwum log milczy aż do końca fazy,
    /// a ta potrafi trwać minutę. Bez tego pomiaru pasek stałby, a obok wisiałaby
    /// prędkość sprzed poprzedniego kontenera — wyglądająca na aktualną.
    ///
    /// Pierwsza tura po zmianie pliku daje tylko rozmiar: prędkość wymaga dwóch próbek.
    /// Kosztuje jedno lekkie `stat` na turę i **wyłącznie wtedy, gdy kopia trwa**.
    private func zmierzTempoArchiwum(_ p: inout Przebieg, sciezka: String?) async {
        guard gpuSSHEnabled, let sciezka else {
            poprzedniPomiarArchiwum = nil
            return
        }
        let r = await commands.rozmiarPliku(sciezka)
        let tekst = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // `@@BRAK` znaczy, że plik jeszcze nie powstał — log wypisuje jego nazwę
        // zanim `tar` go założy. To normalny stan pierwszych sekund fazy, nie błąd.
        guard r.ok, let bajty = Int64(tekst) else { return }
        p.rozmiarBajtow = bajty

        let teraz = Date()
        defer { poprzedniPomiarArchiwum = (sciezka, bajty, teraz) }
        // Zmiana pliku = nowy kontener. Różnica między różnymi plikami nie jest
        // prędkością, tylko śmieciem — pierwsza próbka nowego pliku zaczyna od zera.
        guard let poprzedni = poprzedniPomiarArchiwum, poprzedni.sciezka == sciezka else { return }
        let sekundy = teraz.timeIntervalSince(poprzedni.kiedy)
        let przyrost = bajty - poprzedni.bajty
        // Zerowy przyrost **nie jest** pomiarem „zero na sekundę": plik może akurat
        // czekać na opróżnienie bufora. Zostawiamy wtedy poprzednią wartość z logu,
        // razem z jej dopiskiem „ostatnio" — uczciwiej niż migające zero.
        guard sekundy > 0.5, przyrost > 0 else { return }
        p.predkosc = Double(przyrost) / sekundy
        p.predkoscBiezaca = true
    }

    private func zapamietajZakonczony(_ p: Przebieg) {
        przebiegiZakonczone.removeAll { $0.id == p.id }
        przebiegiZakonczone.insert(p, at: 0)
        if przebiegiZakonczone.count > Self.maksZakonczonych {
            przebiegiZakonczone.removeLast(przebiegiZakonczone.count - Self.maksZakonczonych)
        }
    }

    /// Strumienie transferu — „co teraz płynie i jak dzieli się łącze".
    ///
    /// Źródłem jest RRD Proxmoksa, więc odczyt idzie **REST-em, nie SSH** — kafel działa
    /// także wtedy, gdy SSH nie jest w ogóle skonfigurowane. To nie jest efekt uboczny,
    /// tylko powód, dla którego przepięcie po skasowaniu licznika ruchu (2026-08-29)
    /// wyszło prostsze niż to, co zastąpiło: apka i tak trzyma token do Proxmoksa.
    private func odswiezTransfery() async {
        guard status == .connected else { return }
        let odstepTransferow = Dock.maZwykleOkno()
            ? Self.transferyInterval
            : Self.transferyIntervalBezOkna
        guard Date().timeIntervalSince(lastTransferyRead) >= odstepTransferow else { return }
        lastTransferyRead = Date()

        switch await zbierzStrumienie(okno: .hour) {
        case .success(let nowe):
            strumienie = nowe
            transferyZywe = nowe.contains { !$0.punkty.isEmpty }

        case .failure:
            // Nieudany odczyt zostawia poprzednią listę, ale **gasi** znacznik żywotności:
            // „nie ma danych" i „w sieci cisza" muszą wyglądać w interfejsie inaczej.
            transferyZywe = false
        }
    }

    /// Łącze i wszyscy uruchomieni goście w jednym oknie czasu.
    ///
    /// Jedno wywołanie dla kafla (`okno: .hour`) i dla panelu historii, bo to jest
    /// dokładnie ten sam odczyt — różni się wyłącznie szerokością okna. Dwa osobne
    /// kanały rozjechałyby się pierwszego dnia, tak jak rozjechał się kafel z panelem
    /// przy poprzednim źródle.
    ///
    /// Potknięcie na jednym gościu **nie kasuje reszty**: kontener, który właśnie wstaje,
    /// nie ma prawa wyczyścić całej listy. Brak łącza to co innego — bez mianownika nie
    /// ma udziałów, więc mówimy wprost, że odczyt nie wyszedł.
    ///
    /// Pytamy tylko o gości **uruchomionych**: zatrzymany kontener oddaje szereg samych
    /// zer i zajmuje wiersz, nie wnosząc nic.
    func zbierzStrumienie(okno: OknoRRD) async -> Result<[Strumien], BladTransferow> {
        guard let client, status == .connected else {
            return .failure(BladTransferow(opis: String(localized: "Transfery wymagają połączenia z Proxmoksem.")))
        }

        let wierszeLacza: [WierszRRD]
        do {
            wierszeLacza = try await client.rrdWezla(okno)
        } catch {
            return .failure(BladTransferow(opis: String(localized: "Proxmox nie oddał historii łącza. \(friendly(error))")))
        }

        // Ciśnienie I/O siedzi w tych samych wierszach, co łącze — bierzemy je po drodze,
        // bez dodatkowego żądania. Tylko dla okna kafla: panel historii pyta o inne okna
        // i nie ma po co przestawiać nim bieżącego wskaźnika.
        if okno == .hour, let psi = TransferyParsers.obciazenieIO(wierszeLacza) {
            obciazenieIO = psi
        }

        var wynik = [TransferyParsers.strumien(zrodlo: "host",
                                               kto: nodeName ?? "Proxmox",
                                               rodzaj: .lacze,
                                               wiersze: wierszeLacza,
                                               okno: okno)]

        for gosc in guests where gosc.running {
            guard let wiersze = try? await client.rrdGoscia(gosc, okno: okno) else { continue }
            let kontener = gosc.kind == .container
            wynik.append(TransferyParsers.strumien(
                zrodlo: "\(kontener ? "lxc" : "qemu")/\(gosc.vmid)",
                kto: gosc.name,
                rodzaj: kontener ? .kontener(vmid: gosc.vmid) : .maszyna(vmid: gosc.vmid),
                wiersze: wiersze,
                okno: okno))
        }
        return .success(wynik)
    }

    // MARK: - Historia (spec historii na wykresach, 2026-10-04)
    //
    // Wszystko na żądanie okna albo zakładki — model nic tu nie odpytuje sam.
    // Wzór: `zbierzStrumienie` (ten sam warunek połączenia, ten sam `friendly`).

    /// Temperatury i moc ze zbieracza `mnas-historia`. `.success(nil)` = zbieracza nie ma.
    func historiaZbieracza(_ okno: OknoRRD) async -> Result<HistoriaZbieracza?, BladHistorii> {
        guard gpuSSHEnabled, status == .connected else {
            return .failure(BladHistorii(opis: String(localized: "Historia temperatur i mocy wymaga połączenia SSH.")))
        }
        let r = await commands.odczytajHistorie(okno)
        guard r.ok else {
            return .failure(BladHistorii(opis: r.timedOut ? String(localized: "Serwer nie oddał historii w limicie czasu.")
                                                          : String(localized: "Serwer nie oddał historii (kod \(r.code)).")))
        }
        return .success(HistoriaParsers.zbieracz(r.output))
    }

    func historiaWezla(_ okno: OknoRRD) async -> Result<[WierszRRD], BladHistorii> {
        guard let client, status == .connected else {
            return .failure(BladHistorii(opis: String(localized: "Historia wymaga połączenia z Proxmoksem.")))
        }
        do { return .success(try await client.rrdWezla(okno)) }
        catch { return .failure(BladHistorii(opis: String(localized: "Proxmox nie oddał historii. \(friendly(error))"))) }
    }

    /// Zajętość magazynów Proxmoksa w czasie (od 1.2.16). Magazyn PBS pomijamy —
    /// leży na tym samym systemie plików co `backup`, więc byłby drugą kopią tej samej linii.
    func historiaMagazynow(_ okno: OknoRRD) async -> Result<[(id: String, rodzaj: String?, wiersze: [WierszMagazynuRRD])], BladHistorii> {
        guard let client, status == .connected else {
            return .failure(BladHistorii(opis: String(localized: "Historia magazynów wymaga połączenia z Proxmoksem.")))
        }
        do {
            var wynik: [(id: String, rodzaj: String?, wiersze: [WierszMagazynuRRD])] = []
            for m in try await client.storages() where m.kind != "pbs" {
                if let w = try? await client.rrdMagazynu(m.name, okno: okno) { wynik.append((m.name, m.kind, w)) }
            }
            return .success(wynik)
        } catch {
            return .failure(BladHistorii(opis: String(localized: "Proxmox nie oddał listy magazynów. \(friendly(error))")))
        }
    }

    /// Wszystkie kontenery, nie tylko uruchomione: zatrzymany teraz mógł chodzić w środku
    /// zakresu i jego warstwa ma się pokazać. Potknięcie na jednym nie kasuje reszty.
    func historiaRamKontenerow(_ okno: OknoRRD) async -> [(nazwa: String, vmid: Int, wiersze: [WierszRRD])] {
        guard let client, status == .connected else { return [] }
        var wynik: [(nazwa: String, vmid: Int, wiersze: [WierszRRD])] = []
        for g in guests where g.kind == .container {
            if let w = try? await client.rrdGoscia(g, okno: okno) { wynik.append((g.name, g.vmid, w)) }
        }
        return wynik
    }

    /// Kopie z Proxmoksa (`vzdump`, także PBS) + wpisy z dzienników skryptów hosta.
    /// Kuma celowo poza historią — monitory push meldują się co minutę.
    func historiaPrzebiegow() async -> Result<[WpisHistoriiPrzebiegu], BladHistorii> {
        guard let client, status == .connected else {
            return .failure(BladHistorii(opis: String(localized: "Historia przebiegów wymaga połączenia z Proxmoksem.")))
        }
        var wpisy = PrzebiegiParsers.historiaZadan(await client.ostatnieZadania(rodzaj: "vzdump", limit: 500) ?? [])
        if gpuSSHEnabled {
            let r = await commands.logiPrzebiegow()
            wpisy += HistoriaParsers.historiaLogowHosta(r.output, przebiegiHosta: przebiegiHosta)
        }
        return .success(wpisy.sorted { $0.start > $1.start })
    }

    func szczegolyPrzebiegu(upid: String) async -> SzczegolyVzdump? {
        guard let client, let log = await client.logZadania(upid: upid, limit: 2000) else { return nil }
        return PrzebiegiParsers.szczegolyVzdump(log)
    }

    /// Instalacja albo aktualizacja zbieracza — wołana dopiero po pytaniu w oknie.
    /// Trwa wgrywanie zbieracza na serwer — aktualizacja programu (`Updates.isBusy`) czeka,
    /// bo restart w połowie zostawiłby na serwerze skrypt bez jednostek albo odwrotnie.
    private(set) var instalujeZbieracz = false

    func zainstalujZbieracz() async -> Result<Void, BladHistorii> {
        guard gpuSSHEnabled, status == .connected else {
            return .failure(BladHistorii(opis: String(localized: "Instalacja wymaga połączenia SSH.")))
        }
        instalujeZbieracz = true
        defer { instalujeZbieracz = false }
        let r = await commands.instalujZbieracz()
        guard r.ok else {
            let szczegol = r.error.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            return .failure(BladHistorii(opis: String(localized: "Instalacja nie wyszła (kod \(r.code)). \(szczegol)")))
        }
        Log.ssh.notice("Zainstalowano zbieracz historii, wersja \(HistoriaZbieracz.wersja, privacy: .public)")
        return .success(())
    }

    // MARK: - Aktualizacje serwera (pve-update-check, od 1.2.30)
    //
    // Stan zmienia się raz na dobę (timer 7:30) albo po aktualizacji, więc czytamy go
    // co 30 minut. Co turę (5 s) tylko wtedy, gdy coś na serwerze trwa — aktualizacja,
    // cofnięcie albo sprawdzanie — bo wtedy pasek postępu ma się ruszać.

    /// `nil` = jeszcze nie czytane (albo bez SSH).
    private(set) var aktualizacje: OdczytAktualizacji?
    private(set) var bladAktualizacji: String?
    /// Chwila zlecenia startu z mNas — póki serwer nie potwierdzi, kafel pokazuje „startuje”.
    private(set) var zleconoAktualizacje: Date?
    private var lastAktualizacjeRead = Date.distantPast
    /// Komunikat „nie ruszyło” zostaje do następnego zlecenia, a nie znika przy pierwszym odczycie.
    private var startNieRuszyl = false
    /// Co 5 min — to jeden `cat` małego pliku, a stan zmienia się też poza mNas (sprawdzanie
    /// po starcie hosta, ręczne `pve-update-check`). Przy 30 min kafel po restarcie hosta
    /// pokazywał przez pół godziny stan sprzed restartu (2026-10-16).
    private static let aktualizacjeInterval: TimeInterval = 5 * 60

    var aktualizacjaTrwa: Bool {
        guard let a = aktualizacje else { return zleconoAktualizacje != nil }
        return a.zajete || a.sprawdzaTeraz || a.postep?.trwa == true || zleconoAktualizacje != nil
    }

    private func odswiezAktualizacjeWPetli() async {
        guard gpuSSHEnabled, status == .connected else { return }
        let odstep = aktualizacjaTrwa ? 0 : Self.aktualizacjeInterval
        guard minelo(&lastAktualizacjeRead, odstep) else { return }
        await odswiezAktualizacje()
    }

    func odswiezAktualizacje() async {
        guard gpuSSHEnabled, status == .connected else { return }
        lastAktualizacjeRead = Date()
        let r = await commands.odczytajAktualizacje()
        guard r.ok else {
            bladAktualizacji = r.timedOut ? String(localized: "Serwer nie oddał stanu aktualizacji w limicie czasu.")
                                          : String(localized: "Serwer nie oddał stanu aktualizacji (kod \(r.code)).")
            return
        }
        let nowy = AktualizacjeParsers.odczyt(r.output)
        // Zlecenie jest potwierdzone, gdy serwer ma nowszy start albo coś już chodzi;
        // po 2 minutach bez potwierdzenia uznajemy, że nie ruszyło (log jest w journalu).
        if let z = zleconoAktualizacje {
            let start = AktualizacjeParsers.data(nowy.postep?.start) ?? .distantPast
            if nowy.zajete || nowy.sprawdzaTeraz || start >= z.addingTimeInterval(-5) {
                zleconoAktualizacje = nil
            } else if Date().timeIntervalSince(z) > 120 {
                zleconoAktualizacje = nil
                startNieRuszyl = true
                bladAktualizacji = String(localized: "Aktualizacja nie ruszyła na serwerze. Szczegóły: journalctl -u \(NarzedzieAktualizacji.jednostka)")
            }
        }
        if let stary = aktualizacje?.postep, stary.trwa, let p = nowy.postep, !p.trwa {
            zapiszWynikAktualizacji(p)
        }
        aktualizacje = nowy
        if zleconoAktualizacje == nil, !startNieRuszyl { bladAktualizacji = nil }
    }

    /// Koniec aktualizacji albo cofnięcia — wpis w dzienniku programu. Rejestr zdarzeń
    /// zna tylko przebiegi; wynik i tak zostaje na serwerze w `aktualizacja.json`.
    private func zapiszWynikAktualizacji(_ p: PostepAktualizacji) {
        let tekst = p.podsumowanie?.components(separatedBy: "\n").first(where: { !$0.isEmpty })
            ?? String(localized: "Aktualizacja zakończona")
        Log.ssh.notice("pve-update-check: \(p.stan, privacy: .public) – \(tekst, privacy: .public)")
    }

    enum WynikZlecenia: Equatable { case start, zajete, blad(String) }

    func zainstalujAktualizacje(id: String, zakres: ZakresAktualizacji, serwerNextcloud: Bool) async -> WynikZlecenia {
        guard let polecenie = ServerCommands.poleceniStartuAktualizacji(id: id, zakres: zakres, serwerNextcloud: serwerNextcloud) else {
            return .blad(String(localized: "Niepoprawny numer maszyny."))
        }
        return await zlec(polecenie)
    }

    func cofnijAktualizacje(id: String) async -> WynikZlecenia {
        guard let polecenie = ServerCommands.poleceniCofniecia(id: id) else {
            return .blad(String(localized: "Niepoprawny numer maszyny."))
        }
        return await zlec(polecenie)
    }

    func wyczyscPoAktualizacji(id: String) async -> WynikZlecenia {
        guard let polecenie = ServerCommands.poleceniSprzatania(id: id) else {
            return .blad(String(localized: "Niepoprawny numer maszyny."))
        }
        return await zlec(polecenie)
    }

    func uruchomPonownie(id: String, calyKontener: Bool) async -> WynikZlecenia {
        guard let polecenie = ServerCommands.poleceniRestartu(id: id, calyKontener: calyKontener) else {
            return .blad(String(localized: "Niepoprawny numer maszyny."))
        }
        return await zlec(polecenie)
    }

    func uruchomPonownieHost() async -> WynikZlecenia {
        await restorePWMAuto()
        return await zlec(ServerCommands.poleceniRestartuHosta())
    }

    func sprawdzAktualizacjeTeraz() async -> WynikZlecenia {
        await zlec(ServerCommands.poleceniSprawdzenia())
    }

    private func zlec(_ polecenie: String) async -> WynikZlecenia {
        guard gpuSSHEnabled, status == .connected else { return .blad(String(localized: "Wymaga połączenia SSH.")) }
        let r = await commands.uruchomWTle(polecenie)
        if r.output.contains("@@ZAJETE") { return .zajete }
        guard r.ok, r.output.contains("@@START") else {
            let szczegol = (r.error + r.output).trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            return .blad(String(localized: "Serwer nie przyjął zlecenia (kod \(r.code)). \(szczegol)"))
        }
        zleconoAktualizacje = Date()
        startNieRuszyl = false
        bladAktualizacji = nil
        await odswiezAktualizacje()
        return .start
    }

    private(set) var instalujeNarzedzieAktualizacji = false

    func zainstalujNarzedzieAktualizacji() async -> Result<Void, BladHistorii> {
        guard gpuSSHEnabled, status == .connected else {
            return .failure(BladHistorii(opis: String(localized: "Instalacja wymaga połączenia SSH.")))
        }
        instalujeNarzedzieAktualizacji = true
        defer { instalujeNarzedzieAktualizacji = false }
        let r = await commands.instalujNarzedzieAktualizacji()
        guard r.ok else {
            let szczegol = r.error.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
            return .failure(BladHistorii(opis: String(localized: "Instalacja nie wyszła (kod \(r.code)). \(szczegol)")))
        }
        Log.ssh.notice("Zainstalowano pve-update-check \(NarzedzieAktualizacji.wersja, privacy: .public)")
        await odswiezAktualizacje()
        return .success(())
    }

    /// Zadania, które host naprawdę uruchamia — cron, timery systemd i ich dzienniki.
    ///
    /// > [!danger] Ta lista ma **powstawać z serwera**, nie stać w kodzie
    /// > Zgłoszenie z 2026-08-23: *„program nie reaguje na zmiany, wygląda tak jakbyś
    /// > wpisywał te dane do programu, a nie pobierały informacji prosto z proxmoxa"*.
    /// > Nic tu nie jest wpisane: nazwa bierze się z komentarza nad zadaniem w
    /// > `/etc/cron.d`, harmonogram z wyrażenia cron, a dziennik z linii `LOG=` w samym
    /// > skrypcie. Zadanie zdjęte z crona **znika z listy bez zmiany w aplikacji**.
    /// >
    /// > Sprawdzian: zakomentuj zadanie w `/etc/cron.d/` i odśwież mNas. Ma zniknąć.
    ///
    /// Wymaga SSH — przez REST-a Proxmoksa nie da się zajrzeć ani do crona, ani do
    /// `/var/log`. Bez SSH lista po prostu nie powstaje, zamiast pokazywać połowę prawdy.
    private func odswiezMechanizmyHosta() async {
        guard gpuSSHEnabled, status == .connected else { return }
        guard Date().timeIntervalSince(lastMechanizmyRead) >= Self.mechanizmyInterval else { return }
        lastMechanizmyRead = Date()

        let r = await commands.mechanizmyHosta()
        // Pusty wynik zostawia poprzednią listę — jedno potknięcie SSH nie ma prawa
        // wyczyścić kafla. Ta sama zasada, co przy Kumie i przy wykrywaniu narzędzi.
        let mechanizmy = PrzebiegiParsers.mechanizmyHosta(r.output)
        guard !mechanizmy.isEmpty else { return }

        // Czujki odpadają: `alarm-dyskow.sh` co 10 minut i `pomiar-ruchu.sh` co 10 s
        // nigdy się nie „kończą", więc na liście przebiegów byłyby samym szumem.
        // To ta sama granica, którą stosujemy do monitorów Kumy od 2026-08-20.
        mechanizmyWczytane = true
        przebiegiHosta = mechanizmy.filter { !$0.czujka }.map { m in
            Przebieg(id: "host.\(m.skrypt)",
                     nazwa: m.nazwa,
                     zrodlo: .host,
                     // Bez dziennika nie wiemy, jak poszło — i tak to mówimy, zamiast
                     // malować zieleń na podstawie samego istnienia wpisu w cronie.
                     stan: m.ostatni?.stan ?? .nieznany,
                     faza: m.harmonogram,
                     koniec: m.ostatni?.czas,
                     opis: m.ostatni?.opis)
        }
    }

    /// Monitory push w Uptime Kumie — mechanizmy, które same się meldują po przebiegu.
    ///
    /// Numer kontenera **wyszukujemy po nazwie** zamiast wpisywać go w kod: ten sam błąd
    /// (twarda nazwa zamiast rozpoznania) kosztował już raz kafel Narzędzi, który po
    /// skasowaniu AdGuarda pokazywał go dalej pod adresem Forgejo.
    private func odswiezKume() async {
        guard gpuSSHEnabled, status == .connected else { return }
        guard Date().timeIntervalSince(lastKumaRead) >= Self.kumaInterval else { return }
        guard let kuma = guests.first(where: {
            $0.running && $0.name.localizedCaseInsensitiveContains("kuma")
        }) else { return }
        lastKumaRead = Date()

        let r = await commands.kumaMonitory(ctid: kuma.vmid)
        guard r.ok, !r.timedOut else { return }
        let monitory = PrzebiegiParsers.kumaMonitory(r.output)
        // Pusty wynik zostawia poprzednią listę — jak przy wykrywaniu narzędzi:
        // jedno potknięcie `pct exec` nie ma prawa wyczyścić kafla.
        guard !monitory.isEmpty else { return }

        kumaWczytana = true
        przebiegiKumy = monitory
            .filter { $0.jestPrzebiegiem && $0.aktywny }
            .map { m in
                Przebieg(id: "kuma.\(m.id)",
                         nazwa: m.nazwa,
                         zrodlo: .kuma,
                         stan: m.stan,
                         koniec: m.czas,
                         // Sam spis „ścieżka + procent" pokazuje od 2026-08-23 kafel
                         // „Miejsce", i to z wartości, nie z gotowego zdania. Reszta
                         // wiadomości zostaje — uzasadnienie w `opisJestSpisemMiejsca`.
                         opis: (m.opis.isEmpty || PrzebiegiParsers.opisJestSpisemMiejsca(m.opis))
                               ? nil : m.opis)
            }
    }

    /// Skleja trzy kanały w jedną listę i **z niej** wypuszcza powiadomienia.
    ///
    /// Kolejność: trwające na górze (to jedyna rzecz, która się zmienia w czasie
    /// rzeczywistym), potem zakończone od najświeższego.
    private func zlozPrzebiegi() {
        var wszystkie = przebiegiTrwajace
        wszystkie += przebiegiHosta
        wszystkie += przebiegiKumy
        wszystkie += przebiegiZakonczone.filter { z in !wszystkie.contains { $0.id == z.id } }

        wszystkie.sort { a, b in
            if (a.stan == .trwa) != (b.stan == .trwa) { return a.stan == .trwa }
            return (a.koniec ?? a.start ?? .distantPast) > (b.koniec ?? b.start ?? .distantPast)
        }
        przebiegi = wszystkie
        wyslijPowiadomieniaOZmianach()
    }

    /// Powiadomienie leci za **zmianę** stanu, nie za stan.
    ///
    /// 🔴 Ograniczenie, o którym trzeba mówić wprost: kopie chodzą o 02:15–04:30, kiedy
    /// Mac zwykle śpi i mNas nie działa — wtedy to powiadomienie się nie pokaże i nie ma
    /// jak. Nocny kanał alarmowy to **ntfy z Uptime Kumy** (cisza dłuższa niż 25 h zapala
    /// alarm sama z siebie) i tak ma zostać. To tutaj jest dla przebiegów, które zaczynają
    /// się przy działającej apce, oraz dla zaległości zauważonych po jej uruchomieniu.
    private func wyslijPowiadomieniaOZmianach() {
        var nowe: [String: Przebieg.Stan] = [:]
        for p in przebiegi {
            nowe[p.id] = p.stan
            let poprzedni = poprzednieStany[p.id]
            guard poprzedni != p.stan else { continue }
            // Pierwsze zobaczenie przebiegu nie jest zmianą — inaczej start apki
            // wyrzucałby powiadomienie o każdej starej, nieudanej kopii.
            guard poprzedni != nil || !poprzednieStany.isEmpty else { continue }

            // Chmurka liczy **domknięcia**: przebieg, który się skończył, przyniósł
            // wiadomość. Wejście w stan `trwa` wiadomością nie jest — to widać po ikonie,
            // a doliczanie go dawałoby dwójkę za jedno zdarzenie (start i koniec).
            if p.stan != .trwa, p.stan != .nieznany {
                nieodczytane.insert(p.id)
            }

            // Do rejestru idzie **każda** zmiana, także wejście w `trwa`: to jest historia,
            // a nie licznik nieprzeczytanych. Chmurka gaśnie po otwarciu panelu, ten wpis
            // zostaje — o to poszło zgłoszenie z 2026-08-23 („wiem tylko że jedna
            // akcja, ale jak? Jak przebiegła — zero informacji").
            rejestr.dopisz(przebieg: p, poprzedniStan: poprzedni)

            guard p.stan.alarmujacy else { continue }
            Powiadomienia.pokaz(tytul: "\(p.nazwa) — \(p.stan.opis)",
                                tresc: p.opis ?? String(localized: "Mechanizm zgłosił problem."),
                                identyfikator: p.id)
        }
        poprzednieStany = nowe
        // Przebieg, który wypadł z listy, nie ma już czego zgłaszać.
        let istniejace = Set(przebiegi.map(\.id))
        nieodczytane.formIntersection(istniejace)
        // To samo dla odhaczeń: alarm, którego już nie ma, nie musi zostawiać po sobie
        // klucza. Sprzątanie tutaj, a nie przy odhaczaniu, bo dopiero świeża lista
        // przebiegów mówi, co jeszcze istnieje.
        //
        // 🔴 Tylko przy **pełnej** liście. `Rozłącz` czyści przebiegi i składa listę od
        // nowa, a pierwsza tura po starcie jeszcze nie ma Kumy ani zadań hosta — przycięcie
        // wtedy kasowało wszystkie odhaczenia i odhaczone alarmy świeciły od nowa.
        // Audyt SBW 2026-09-24, E2-S-P3-01. Rośnięciu zbioru i tak pilnuje `limit`.
        if pelnaListaPrzebiegow {
            potwierdzone.zapomnijNieistniejace(przebiegi)
        }
    }

    private var pelnaListaPrzebiegow: Bool {
        guard status == .connected else { return false }
        guard gpuSSHEnabled else { return true }
        let jestKuma = guests.contains { $0.running && $0.name.localizedCaseInsensitiveContains("kuma") }
        return mechanizmyWczytane && (kumaWczytana || !jestKuma)
    }

    /// Wywoływane, gdy użytkownik otworzy panel spod ikony — czyli **zobaczy** te wiadomości.
    func oznaczPrzebiegiJakoPrzeczytane() {
        guard !nieodczytane.isEmpty else { return }
        nieodczytane.removeAll()
    }

    /// Przebiegi, które alarmują **i nie zostały jeszcze odhaczone**.
    ///
    /// To jest jedyne źródło czerwieni na ikonie i jedyny powód, dla którego przycisk
    /// „Przyjęte" ma się w ogóle pokazać. Odhaczony błąd zostaje na liście i w
    /// rejestrze — przestaje tylko krzyczeć kolorem.
    var alarmyDoOdhaczenia: [Przebieg] {
        przebiegi.filter { potwierdzone.alarmuje($0) }
    }

    /// Użytkownik przeczytał alerty i kwituje je. Ikona gaśnie z czerwonej na zieloną —
    /// **razem z liczbą w chmurce obok dysku**.
    ///
    /// 🔴 Chmurka gaśnie tutaj, a nie wyłącznie przy otwarciu panelu. Zgłoszenie
    /// 2026-08-25: *„kiedy już zapoznam się z alertami i kliknę zapoznałem się, to
    /// zostaje jeszcze liczba komunikatów"*. W kodzie były to dwa niezależne znaczniki
    /// — odhaczone alarmy (kolor odznaki) i nieodczytane domknięcia (liczba) — a na
    /// ikonie czytają się jak jeden stan „coś jest do obejrzenia". Kwitowanie gasiło
    /// połowę i zostawiało drugą, czyli mówiło użytkownikowi, że nie skończył czegoś, co zrobił.
    ///
    /// Historii to nie rusza, tak samo jak wcześniej: wiersze w „Przebiegach" i wpisy
    /// w „Zdarzeniach" zostają, znika sam znacznik. Kolejna zmiana stanu zapala oba
    /// od nowa — `wyslijPowiadomieniaOZmianach`.
    func potwierdzAlerty() {
        potwierdzone.potwierdz(alarmyDoOdhaczenia)
        oznaczPrzebiegiJakoPrzeczytane()
    }

    /// `vzdump` bez numeru gościa to całe zadanie; z numerem — jedna jego część.
    private func nazwaZadania(_ zadanie: TaskEntry) -> String {
        let numer = zadanie.id ?? ""
        guard !numer.isEmpty else { return zadanie.opisRodzaju }
        if let vmid = Int(numer), let nazwa = nazwaGoscia(vmid) {
            return "\(zadanie.opisRodzaju) · \(nazwa)"
        }
        return "\(zadanie.opisRodzaju) · \(numer)"
    }

    /// Nazwa kontenera zamiast gołego numeru — „samba" mówi więcej niż „104".
    private func nazwaGoscia(_ vmid: Int) -> String? {
        guard let g = guests.first(where: { $0.vmid == vmid }) else { return nil }
        return g.name
    }

    /// Wykrywa narzędzia webowe w kontenerach i buduje z nich klikalne adresy.
    ///
    /// Świadomie **nie** siedzi w pętli co 5 s: `pct exec` na każdym kontenerze kosztuje
    /// sekundy, a zestaw narzędzi zmienia się raz na tygodnie, nie co odświeżenie.
    /// Leci raz po połączeniu i potem na żądanie (przycisk „Szukaj ponownie").
    func discoverWebServices() async {
        guard gpuSSHEnabled, !discoveringServices else { return }
        discoveringServices = true
        defer { discoveringServices = false }

        let r = await commands.discoverWebServices()
        guard !r.timedOut else {
            Log.ssh.error("Wykrywanie narzędzi przekroczyło limit czasu")
            return
        }
        let found = StatsParsers.webServices(r.output)
        // Pusty wynik zostawia poprzednią listę: pojedyncze potknięcie `pct exec`
        // nie ma prawa skasować z ekranu narzędzi, które istnieją.
        guard !found.isEmpty else { return }
        webServices = found
        // Klucz zapisujemy **dopiero po sukcesie**: gdyby szedł przed odczytem,
        // jedno nieudane wykrycie zamrażałoby listę aż do następnej zmiany kontenerów.
        lastDiscoveryKey = runningContainerKey
        Log.ssh.notice("Wykryto \(found.count, privacy: .public) narzędzi w kontenerach")
    }

    /// Sygnatura bieżącego zestawu działających kontenerów — `vmid:nazwa`, posortowane.
    /// Nazwa jest w kluczu celowo: kontener przemianowany to inne narzędzie na kaflu.
    private var runningContainerKey: String {
        guests
            .filter { $0.kind == .container && $0.running }
            .map { "\($0.vmid):\($0.name)" }
            .sorted()
            .joined(separator: ",")
    }

    /// Jedno wywołanie SSH → wszystkie statystyki na żywo (pewne, bez API).
    func refreshStatsViaSSH() async {
        let r = await commands.liveStats()
        guard r.ok else {
            sshFailures += 1
            let opis = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
            // Pusty `opis` nie jest teoretyczny: komendy w `liveStats` mają `2>/dev/null`,
            // więc gdy któraś zwróci niezerowy kod, zostaje sam kod bez tekstu. Wcześniej
            // trafiał wtedy do interfejsu pusty string — czyli „jest błąd, ale nie powiem
            // jaki". Kod wyjścia mówi więcej niż nic.
            gpuSSHError = r.timedOut
                ? String(localized: "Odczyt statystyk przez SSH przekroczył limit czasu.")
                : (opis.isEmpty ? String(localized: "Odczyt statystyk przez SSH zwrócił kod \(r.code), bez komunikatu.") : opis)
            return
        }
        sshFailures = 0
        gpuSSHEnabled = true          // pierwszy sukces → UI odzwierciedla stan
        gpuSSHError = nil

        let sections = StatsParsers.splitSections(r.output)

        if let stat = sections["STAT"] {
            let (aggregate, perCore) = StatsParsers.procStat(stat, previous: &prevCPUJiffies)
            // Sam punkt na wykresie dokłada `refresh()` raz na turę — tu tylko wartość,
            // żeby przy włączonym SSH nie dopisywać dwóch punktów na jedno odświeżenie.
            if let aggregate { cpu.averageUsage = aggregate }
            if !perCore.isEmpty { cpu.perCoreUsage = perCore }
        }

        if let mem = sections["MEM"] {
            let arc = Double(sections["ARC"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            if let parsed = StatsParsers.memory(mem, arcBytes: arc) { memory = parsed }
        }

        if let sensors = sections["SENSORS"],
           !sensors.trimmingCharacters(in: .whitespaces).isEmpty,
           let reading = StatsParsers.sensors(sensors) {
            if !reading.perCoreTemp.isEmpty { cpu.perCoreTemp = reading.perCoreTemp }
            if let pkg = reading.packageTemp { cpu.packageTemp = pkg }
            fans = reading.fans
        }

        if let csv = sections["GPU"], let parsed = StatsParsers.gpu(csv, into: gpu) {
            gpu = parsed
        }

        // Pobór mocy: dwie próbki liczników RAPL dają waty. Pierwsza tura po połączeniu
        // nie ma z czym porównywać, więc kafel przez jedno odświeżenie pokazuje „—".
        if let raw = sections["POWER"], let sample = StatsParsers.raplSample(raw) {
            if let previous = prevRAPL {
                let watts = StatsParsers.watts(from: previous, to: sample)
                if !watts.isEmpty {
                    var p = PowerStats()
                    // `package-0` to cały procesor; przy jednym gnieździe innych nie ma.
                    p.packageWatts = watts.first { $0.key.hasPrefix("package") }?.value
                    p.domains = watts.filter { !$0.key.hasPrefix("package") }
                    p.gpuWatts = gpu.powerWatts
                    power = p
                }
            }
            prevRAPL = sample
        }

        if let blk = sections["BLK"], let df = sections["DF"] {
            let parsed = StatsParsers.diskUsage(lsblk: blk, df: df, lvm: sections["LVM"] ?? "")
            // Pusty wynik zostawia poprzedni: jedno potknięcie `lsblk` nie ma prawa
            // wyczyścić zajętości ze wszystkich wierszy naraz.
            if !parsed.isEmpty { diskUsage = parsed }
        }

        // Charakterystyka procesora nie zmienia się w trakcie pracy węzła — pobieramy
        // ją raz, przy pierwszym udanym odczycie SSH, i już do niej nie wracamy.
        if cpuDetails == nil {
            let r = await commands.cpuStatic()
            if r.ok {
                let parsed = StatsParsers.lscpu(r.output)
                if !parsed.isEmpty { cpuDetails = parsed }
            }
        }

        // Nazwy udziałów i magazynów — tak samo raz na połączenie. Zmieniają się przy
        // przebudowie serwera, nie co pięć sekund.
        if nazwyMontowan.isEmpty {
            let r = await commands.nazwyMontowan()
            let parsed = Miejsce.nazwy(r.output)
            if !parsed.isEmpty { nazwyMontowan = parsed }
        }

        // Zajętość liczymy z tego samego `@@DF`, które już przyszło wyżej — bez nazw też,
        // bo lepiej pokazać ścieżkę niż nic. Kafel „Miejsce" ma pokazywać **wartości**,
        // nie gotowe zdanie z czujki (zgłoszenie 2026-08-23).
        if let df = sections["DF"] {
            let parsed = Miejsce.udzialy(nazwy: nazwyMontowan, df: df)
            if !parsed.isEmpty { udzialy = parsed }
        }
    }

    // MARK: - Panele sterowania (SSH — realne komendy roota)
    //
    // Cienkie forwardery do `ServerCommands`: widoki wołają `model.…`, a budowanie
    // i odpalanie komend siedzi w jednym, testowalnym miejscu.

    func runCommand(_ command: String, sudo: Bool = false, timeout: Int = 25) async -> String {
        await commands.run(command, sudo: sudo, timeout: timeout)
    }

    func topProcesses(by kind: String) async -> String { await commands.topProcesses(by: kind) }

    // MARK: GPU
    func gpuProcesses() async -> String { await commands.gpuProcesses() }
    func gpuFullStatus() async -> String { await commands.gpuFullStatus() }
    func gpuDriverDiagnostics() async -> String { await commands.gpuDriverDiagnostics() }
    func gpuTryLoadDriver() async -> String { await commands.gpuTryLoadDriver() }

    /// Tłumaczy typowe błędy sterowników na jedno zdanie po polsku.
    /// `nil` = brak rozpoznanego wzorca, pokazujemy tylko surowe wyjście.
    func interpretDriverError(_ text: String) -> String? { StatsParsers.driverError(text) }

    // MARK: Pule ZFS

    // MARK: Wentylatory / czujniki (it87)
    func loadSensorsModule() async -> String { await commands.loadSensorsModule() }
    func sensorsDetect() async -> String { await commands.sensorsDetect() }
    func sensorsRaw() async -> String { await commands.sensorsRaw() }

    /// Wykryte kanały PWM (ścieżka + wartość + tryb), gotowe do pokazania.
    func pwmChannels() async -> [PWMChannel] {
        StatsParsers.pwmChannels(await commands.readPWMChannels())
    }

    /// Ustawia PWM i zapamiętuje, że ten kanał ruszyła apka — żeby móc po sobie posprzątać.
    func setPWM(path: String, value: Int) async -> String {
        // Wpis zanim poznamy wynik: `pwmX_enable = 1` leci pierwsze i mogło już zadziałać,
        // nawet gdy sam zapis wartości się nie powiódł.
        manualPWMPaths.insert(path)
        return await commands.setPWM(path: path, value: value)
    }

    /// Przywraca automatyczne sterowanie jednym kanałem (przycisk „Auto").
    func setPWMAuto(path: String) async -> String {
        let result = await commands.setPWMAuto(path: path)
        manualPWMPaths.remove(path)
        return result
    }

    /// Oddaje wszystkie ruszone kanały układowi. Wołane przy rozłączeniu i przy zamykaniu
    /// aplikacji — limit czasu jest krótki, bo to biegnie na ścieżce wyjścia z programu.
    func restorePWMAuto() async {
        guard !manualPWMPaths.isEmpty else { return }
        let paths = manualPWMPaths
        manualPWMPaths.removeAll()
        // Równolegle, bo to biegnie m.in. na ścieżce zamykania programu: przy trzech
        // kanałach szeregowo dałoby to w najgorszym razie trzy limity czasu pod rząd.
        let cmd = commands
        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask { _ = await cmd.setPWMAuto(path: path, timeout: 8) }
            }
        }
        Log.ssh.notice("Przywrócono tryb automatyczny na \(paths.count, privacy: .public) kanałach PWM")
    }

    // MARK: Kondycja dysków (SMART)

    func diskHealth(_ diskName: String) async -> DiskHealthResult {
        let safe = ServerCommands.safeName(diskName)
        guard !safe.isEmpty else { return DiskHealthResult(ok: false, rawError: String(localized: "Zła nazwa dysku.")) }
        let r = await commands.smartRaw(disk: safe)
        guard let jsonText = StatsParsers.extractJSON(r.output),
              let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let err = (r.error + r.output).trimmingCharacters(in: .whitespacesAndNewlines)
            let hint: String
            if r.timedOut {
                hint = String(localized: "smartctl nie odpowiedział w limicie czasu — dysk mógł być uśpiony.")
            } else if err.lowercased().contains("password") {
                hint = String(localized: "smartctl wymaga sudo bez hasła. Nadaj NOPASSWD dla \(username) albo uruchom smartctl ręcznie.")
            } else {
                hint = err.isEmpty ? String(localized: "Brak odpowiedzi smartctl (SSH/sudo?).") : err
            }
            return DiskHealthResult(ok: false, rawError: hint)
        }
        return StatsParsers.smart(obj)
    }

    func startSelfTest(_ diskName: String, long: Bool) async -> String {
        let r = await commands.startSelfTest(disk: diskName, long: long)
        let text = (r.output + r.error).lowercased()
        if r.ok || text.contains("has begun") || text.contains("test has started") {
            return long
                ? String(localized: "Test długi uruchomiony — może potrwać kilka godzin. Odświeżaj kondycję, żeby zobaczyć wynik.")
                : String(localized: "Test krótki uruchomiony — ~1–2 min. Odśwież kondycję za chwilę.")
        }
        let e = (r.error + r.output).trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? String(localized: "Nie udało się uruchomić testu (SSH/sudo NOPASSWD?).") : e
    }

    // MARK: - Uprawnienia powłoki

    /// W wersji pod TrueNAS-a stał tu przycisk „Napraw sudo (API)": tamten serwer logował
    /// przez konto admina, któremu middleware zarządzało regułami sudo. Na Proxmoksie
    /// logujemy się **bezpośrednio rootem**, więc sudo nie jest w ogóle potrzebne —
    /// zostaje sama weryfikacja, żeby przycisk mówił prawdę zamiast udawać naprawę.
    func checkRootShell() async -> String {
        let r = await commands.run("id -un", timeout: 8)
        let who = r.trimmingCharacters(in: .whitespacesAndNewlines)
        if who == "root" {
            return String(localized: "SSH loguje się jako root — wszystkie panele odblokowane, sudo niepotrzebne.")
        }
        return String(localized: """
        SSH loguje się jako „\(who)”, nie root. Na Proxmoksie mNas zakłada dostęp roota: \
        wpisz `root@pam!<nazwa-tokenu>` w polu tokenu (część przed `@` to konto SSH) \
        i wklej klucz publiczny do `/root/.ssh/authorized_keys`.
        """)
    }

    // MARK: - Akcje zmieniające serwer (zawsze z potwierdzeniem w UI)

    /// Ostatnia akcja na serwerze, która się nie udała — baner na dashboardzie.
    ///
    /// Osobno od `lastError`, bo ten czyści każda udana tura odświeżania: komunikat
    /// zniknąłby, zanim użytkownik by go zobaczył. Do 1.2.9 błąd akcji ginął w `try?`
    /// i kafel po kliknięciu wyglądał tak samo jak przed nim — przy „Restart węzła”
    /// czekało się na restart, którego nie było. Audyt SBW 2026-09-24, E1-S-P2-01.
    var bladAkcji: String?

    /// Wykonuje akcję i zapamiętuje jej błąd. Zwraca opis błędu (`nil` = udało się),
    /// żeby panel, z którego przyszło kliknięcie, mógł go pokazać u siebie.
    @discardableResult
    private func wykonajAkcje(_ opis: String, _ akcja: (ProxmoxClient) async throws -> Void) async -> String? {
        guard let client else {
            bladAkcji = String(localized: "\(opis) — nie wykonano: brak połączenia z serwerem.")
            return bladAkcji
        }
        do {
            try await akcja(client)
            bladAkcji = nil
            return nil
        } catch {
            Log.connection.error("Akcja „\(opis, privacy: .public)” nieudana: \(error.localizedDescription, privacy: .public)")
            bladAkcji = String(localized: "\(opis) — nie udało się. \(friendly(error))")
            return bladAkcji
        }
    }

    @discardableResult
    func setService(_ name: String, running: Bool) async -> String? {
        let blad = await wykonajAkcje(running ? String(localized: "Start usługi \(name)") : String(localized: "Stop usługi \(name)")) {
            try await $0.setService(name, running: running)
        }
        await refresh()
        return blad
    }

    @discardableResult
    func restartService(_ name: String) async -> String? {
        let blad = await wykonajAkcje(String(localized: "Restart usługi \(name)")) { try await $0.restartService(name) }
        await refresh()
        return blad
    }

    /// Start/stop maszyny wirtualnej albo kontenera.
    @discardableResult
    func setGuest(_ guest: Guest, running: Bool) async -> String? {
        let blad = await wykonajAkcje(running ? String(localized: "Start \(guest.name)") : String(localized: "Stop \(guest.name)")) {
            try await $0.setGuest(guest, running: running)
        }
        await refresh()
        return blad
    }

    func rebootServer() async {
        // Przez narzędzie aktualizacji (root po SSH), gdy jest: API odmawia restartu, bo token mNas
        // nie ma `Sys.PowerMgmt` — 2026-10-16 przycisk „nie działał”. Narzędzie sprawdza też kopie i DKMS.
        if gpuSSHEnabled, case .jest(_)? = aktualizacje?.narzedzie {
            switch await uruchomPonownieHost() {
            case .start: bladAkcji = nil
            case .zajete: bladAkcji = String(localized: "Restart węzła — nie teraz: na serwerze trwa kopia, aktualizacja albo sprawdzanie.")
            case .blad(let e): bladAkcji = String(localized: "Restart węzła — nie udało się. \(e)")
            }
            return
        }
        // Serwer zniknie za chwilę — oddaj wentylatory układowi, zanim padnie kanał.
        await restorePWMAuto()
        await wykonajAkcje(String(localized: "Restart węzła")) { try await $0.rebootNode() }
    }

    // MARK: - Auto-odświeżanie

    func setAutoRefresh(_ on: Bool) {
        autoRefresh = on
        if on { startAutoRefresh() } else { stopAutoRefresh() }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        guard autoRefresh else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // Bez otwartego okna program siedzi w pasku menu i nikt nie patrzy na
                // kafle — wtedy wystarczy pilnować alarmów raz na minutę. Warunek
                // „czy jest widoczne zwykłe okno" jest jeden i mieszka w `Dock`.
                let odstep = Dock.maZwykleOkno() ? Self.odstepZOknem : Self.odstepBezOkna
                try? await Task.sleep(nanoseconds: UInt64(odstep * 1_000_000_000))
                guard let self, self.status == .connected, self.autoRefresh else { break }
                await self.refresh()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Ładne komunikaty błędów

    private func friendly(_ error: Error) -> String {
        if let clientError = error as? ProxmoxClient.ClientError {
            return clientError.errorDescription ?? "\(clientError)"
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorNotConnectedToInternet:
                return String(localized: "Nie można połączyć się z \(host). Sprawdź adres serwera i czy Mac jest w tej samej sieci.")
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate:
                // Ta gałąź stała się osiągalna dopiero po włączeniu weryfikacji certyfikatu.
                return String(localized: "Problem z certyfikatem TLS serwera (\(host)).")
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
