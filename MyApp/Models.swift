import Foundation

/// Liczba, która w JSON-ie serwera bywa raz Intem, raz Doublem, raz Stringiem.
/// Dekodujemy ją tolerancyjnie, żeby apka nigdy nie wywaliła się na drobnej różnicy typu.
nonisolated struct FlexibleInt: Decodable {
    let value: Int64?

    /// Do budowania modeli w kodzie (klient REST składa je z pól Proxmoksa),
    /// nie tylko z dekodera.
    init(_ value: Int64?) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int64.self) {
            value = i
        } else if let d = try? c.decode(Double.self) {
            // `Int64(d)` to pułapka procesu dla liczby spoza zakresu, NaN i nieskończoności
            // (`1e19` → „Double value cannot be converted”). Poza zakresem — brak wartości,
            // tak jak przy każdym innym nieczytelnym polu. Audyt SBW 2026-09-24, E1-S-P3-01.
            value = d.isFinite && d >= -9.223372036854775e18 && d < 9.223372036854775e18
                ? Int64(d.rounded(.towardZero)) : nil
        } else if let s = try? c.decode(String.self), let i = Int64(s) {
            value = i
        } else {
            value = nil
        }
    }
}

/// Stan węzła Proxmoksa (`/nodes/{node}/status`), sprowadzony do pól, których używa
/// dashboard. Kształt zostawiony taki jak w wersji pod TrueNAS-a — dzięki temu cała
/// warstwa widoków przeszła bez zmian.
nonisolated struct SystemInfo: Decodable {
    var version: String
    var hostname: String
    var model: String?            // model CPU
    var cores: Int?
    var physicalCores: Int?       // physical_cores
    var physmem: FlexibleInt?     // pamięć RAM w bajtach
    var uptimeSeconds: Double?    // uptime_seconds
    var loadavg: [Double]?
    var systemProduct: String?    // system_product (np. model płyty)
}

/// Migawka węzła: opis systemu i bieżące liczby z tej samej odpowiedzi API.
///
/// Trzymane razem, bo przychodzą jednym żądaniem — rozbijanie tego na dwa wywołania
/// znaczyłoby pytać serwer dwa razy o to samo.
nonisolated struct NodeSnapshot: Sendable {
    var info: SystemInfo
    var cpuUsage: Double?       // % (0…100), pomiar z Proxmoksa
    var memoryTotal: Int64?
    var memoryUsed: Int64?
    /// Wolna pamięć **w rozumieniu `MemAvailable`** — tym samym, którego używa odczyt
    /// przez SSH. Zrównanie obu źródeł jest warunkiem, żeby kafel RAM nie migał:
    /// oba kanały piszą do tego samego pola w każdej turze odświeżania.
    var memoryFree: Int64?
}

/// Magazyn Proxmoksa (`local`, `local-lvm`, `backup2`…) w kaflu „Pamięć masowa".
///
/// Nazwa typu została z wersji pod TrueNAS-a, gdzie oznaczała pulę ZFS. W Proxmoksie
/// odpowiednikiem funkcjonalnym jest **storage**: to on ma pojemność, zajętość i stan.
///
/// Osobnego typu na pule ZFS **nie ma i nie ma go potrzeby**: `ZFSPool` razem z metodą
/// `zfsPools()` został usunięty 2026-08-16 (P2-03). Pobierał listę osobnym żądaniem co 5 s
/// — dwanaście razy na minutę — a nie renderował go żaden widok. Gdyby kiedyś powstał
/// kafel pul ZFS, typ trzeba odtworzyć razem z nim, nie wcześniej.
nonisolated struct Pool: Decodable, Identifiable {
    var name: String
    /// Rodzaj magazynu z API (`dir`, `lvmthin`, `zfspool`…). Pokazywany na kaflu, bo
    /// sama nazwa (`aplikacje`, `multimedia`, `local-lvm`) nie mówi, czym to w ogóle jest.
    var kind: String? = nil
    var status: String
    var healthy: Bool?
    var size: FlexibleInt?
    var allocated: FlexibleInt?
    var free: FlexibleInt?

    var id: String { name }
}

/// Dysk fizyczny z `/nodes/{node}/disks/list`.
nonisolated struct Disk: Decodable, Identifiable {
    var name: String
    var model: String?
    var serial: String?
    var type: String?             // HDD / SSD
    var size: FlexibleInt?
    /// Werdykt SMART z API: `PASSED`, `FAILED`, `UNKNOWN`. Nie jest tym samym co
    /// temperatura — dysk może być chłodny i mieć werdykt `FAILED`.
    var health: String? = nil
    /// **Pozostała** żywotność komórek w procentach, nie zużycie. Proxmox liczy ją jako
    /// `100 − Percentage Used` ze SMART-u: 100 = nowy, 0 = wyczerpany.
    ///
    /// 🔴 Zmierzone 2026-08-23 na serwerze testowym — trzy NVMe: `wearout` 100/98/99 przy
    /// `Percentage Used` 0%/2%/1%. Kierunek jest odwrotny do intuicji i pomylenie go
    /// zapaliłoby ostrzeżenie na każdym zdrowym dysku. Dyski SATA podają `N/A`.
    var wearout: FlexibleInt? = nil

    var id: String { name }

    /// Zużycie komórek w procentach — to, czym operuje czujka na serwerze
    /// (`PROG_ZUZYCIE=80` w `/usr/local/bin/alarm-dyskow.sh`). `nil`, gdy dysk
    /// nie podaje żywotności (talerze i mostki SATA).
    var zuzycieProcent: Int? {
        guard let pozostalo = wearout?.value, (0...100).contains(pozostalo) else { return nil }
        return 100 - Int(pozostalo)
    }
}

/// Alert pokazywany w dashboardzie.
///
/// Proxmox **nie ma** odpowiednika `alert.list` z TrueNAS-a. Alerty składa
/// `ProxmoxClient.failedTaskAlerts()` z zadań zakończonych błędem (przerwany backup,
/// nieudany start kontenera, padnięta replikacja) — to najbliższy prawdziwy odpowiednik.
///
/// `id` MUSI wynikać z danych, nie z `UUID()`. Alerty są odświeżane co 5 s — przy losowej
/// tożsamości `ForEach` uznawał każdy za nowy wiersz i przebudowywał całą listę
/// dwanaście razy na minutę, mimo że treść się nie zmieniała.
nonisolated struct Alert: Decodable, Identifiable {
    var uuid: String?             // UPID zadania — stabilny identyfikator
    var level: String?            // INFO / WARNING / CRITICAL
    var formatted: String?        // gotowy tekst alertu
    var dismissed: Bool?
    var klass: String?

    /// Zapasowo (gdy serwer nie poda `uuid`) sklejamy klasę z treścią — dla tego samego
    /// alertu jest to ta sama wartość w kolejnych odświeżeniach.
    var id: String { uuid ?? "\(klass ?? "?")|\(formatted ?? "?")" }
}

/// Usługa systemowa węzła (`pveproxy`, `pvedaemon`, `sshd`…) z `/nodes/{node}/services`.
nonisolated struct Service: Decodable, Identifiable {
    var service: String           // nazwa usługi, np. "pveproxy"
    var state: String?            // RUNNING / STOPPED
    var enable: Bool?             // czy startuje z systemem

    var id: String { service }
}

// MARK: - Maszyny i kontenery

/// Jedna maszyna wirtualna albo kontener LXC z `/cluster/resources?type=vm`.
///
/// To jest kafel, którego wersja pod TrueNAS-a nie miała w ogóle i który w Proxmoksie
/// jest najważniejszy: serwer wirtualizacyjny mierzy się liczbą i stanem gości,
/// nie samą zajętością dysków.
nonisolated struct Guest: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case container            // LXC
        case virtualMachine       // QEMU/KVM

        var label: String { self == .container ? String(localized: "Kontener") : String(localized: "Maszyna") }
        var symbol: String { self == .container ? "shippingbox" : "desktopcomputer" }
    }

    var vmid: Int
    var name: String
    var kind: Kind
    var running: Bool
    var cpuFraction: Double?      // 0…1 (udział jednego rdzenia × maxCPU)
    var maxCPU: Double?           // przydzielone rdzenie
    var memoryUsed: Int64?        // bajty
    var memoryTotal: Int64?       // bajty
    var diskUsed: Int64?          // bajty
    var diskTotal: Int64?         // bajty
    var uptimeSeconds: Double?

    var id: Int { vmid }

    /// Zużycie CPU w procentach. Proxmox podaje ułamek **jednego** rdzenia hosta
    /// przemnożony przez przydział, więc `0.5` przy 2 rdzeniach to 50 %, nie 25 %.
    var cpuPercent: Double? {
        guard let cpuFraction else { return nil }
        return min(100, max(0, cpuFraction * 100))
    }

    /// Zajętość RAM w procentach — `nil`, gdy maszyna stoi (Proxmox raportuje wtedy zera).
    var memoryPercent: Double? {
        guard running, let used = memoryUsed, let total = memoryTotal, total > 0 else { return nil }
        return min(100, Double(used) / Double(total) * 100)
    }
}

// MARK: - Narzędzia w kontenerach

/// Usługa webowa wykryta w kontenerze — gotowy adres do kliknięcia.
///
/// Powstaje z **wykrycia**, nie z wpisanej na stałe listy: mNas pyta każdy działający
/// kontener o jego adres i porty nasłuchu. Dzięki temu nowy kontener pojawia się w apce
/// sam, a przeniesiony na inny adres nie zostawia martwego linku — czego lista wklepana
/// w kod nigdy by nie dała.
nonisolated struct DiscoveredService: Identifiable, Sendable, Equatable {
    var vmid: Int
    var guestName: String        // nazwa kontenera, np. „adguard"
    var address: String          // IP osiągalne z sieci lokalnej
    var port: Int
    /// Czytelna nazwa narzędzia rozpoznanego po porcie (`nil` = nieznane).
    var toolName: String?
    /// Czy pod tym portem spodziewamy się HTTPS.
    var secure: Bool

    var id: String { "\(vmid):\(port)" }

    var url: URL? { URL(string: "\(secure ? "https" : "http")://\(address):\(port)") }

    /// Co pokazać na kaflu: nazwa narzędzia, a gdy nieznane — nazwa kontenera.
    var label: String { toolName ?? guestName }

    /// Rozpoznanie narzędzia po **nazwie kontenera**. Ma pierwszeństwo przed portem.
    ///
    /// Pierwotnie rozpoznawaliśmy wyłącznie po porcie, z uzasadnieniem „nazwy nadaje
    /// użytkownik i bywają dowolne, a port jest własnością usługi". To założenie jest
    /// **fałszywe** i wyszło na tym boleśnie: port 3000 miał wpisane na sztywno
    /// „AdGuard Home", a po skasowaniu AdGuarda (2026-08-19) nasłuchuje na nim
    /// **Forgejo** z kontenera 105. Kafel dalej pokazywał AdGuarda i prowadził do
    /// cudzego panelu — nazwa wzięta z powietrza wygrywała z nazwą, którą właściciel
    /// serwera sam nadał kontenerowi.
    ///
    /// Port 3000 dzielą Forgejo, Gitea, Grafana, Homepage i AdGuard; port 8080 —
    /// Vaultwarden i pół internetu. Nazwa kontenera jest jedyną informacją, która
    /// naprawdę mówi, co tam stoi.
    static func tool(forName raw: String) -> String? {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        switch key {
        case "adguard", "adguardhome":        return "AdGuard Home"
        case "kuma", "uptimekuma":            return "Uptime Kuma"
        case "forgejo":                       return "Forgejo"
        case "gitea":                         return "Gitea"
        case "nextcloud":                     return "Nextcloud"
        case "vaultwarden", "bitwarden":      return "Vaultwarden"
        case "jellyfin":                      return "Jellyfin"
        case "immich":                        return "Immich"
        case "paperless", "paperlessngx":     return "Paperless"
        case "grafana":                       return "Grafana"
        case "prometheus":                    return "Prometheus"
        case "ntfy":                          return "ntfy"
        case "homeassistant", "hass":         return "Home Assistant"
        case "plex":                          return "Plex"
        case "samba", "smb":                  return "Samba"
        case "tailscale":                     return "Tailscale"
        default:                              return nil
        }
    }

    /// Rozpoznanie po porcie — **tylko awaryjnie**, gdy nazwa kontenera nic nie mówi
    /// (`ct101`, `test`, `monitoring`), i tylko dla portów, których w praktyce nie
    /// dzieli kilka aplikacji. Porty-wspólniki (3000, 8080, 80, 443) świadomie
    /// wypadły z tej listy: lepszy kafel z nazwą kontenera niż z cudzą nazwą.
    static func tool(forPort port: Int) -> (name: String, secure: Bool)? {
        switch port {
        case 8006:  return ("Proxmox VE", true)
        case 3001:  return ("Uptime Kuma", false)
        case 8096:  return ("Jellyfin", false)
        case 2283:  return ("Immich", false)
        case 8123:  return ("Home Assistant", false)
        case 32400: return ("Plex", false)
        default:    return nil
        }
    }

    /// Czy pod tym portem spodziewamy się HTTPS. Osobno od nazwy, bo to cecha portu
    /// (a nie aplikacji) i obowiązuje też wtedy, gdy nazwę wzięliśmy z kontenera.
    static func isSecure(port: Int) -> Bool {
        port == 443 || port == 8006 || port == 8443
    }

    /// Porty, których nie pokazujemy jako narzędzi — nie są webowe albo są infrastrukturą,
    /// którą i tak obsługuje się inaczej. Bez tego kafle zalałby SSH i DNS z każdego kontenera.
    /// Dopisane 2026-08-19 po pomiarze na serwerze testowym: trzy kontenery Samby (`samba`,
    /// `media`, `foto`) nasłuchują na 139 i 445, co dawało **sześć** kafli „narzędzi"
    /// z adresami `http://…:445` — linki donikąd, bo to nie jest protokół webowy.
    /// Porty baz danych z tego samego powodu: nasłuchują, ale panelu nie mają.
    static let ignoredPorts: Set<Int> = [
        22, 25, 53, 111, 123, 587, 631, 3493, 5353,
        137, 138, 139, 445,                    // SMB/NetBIOS — udział sieciowy, nie panel
        3306, 5432, 6379, 11211, 27017,        // bazy danych
    ]

    /// Początek zakresu portów efemerycznych. Wszystko od tej wartości w górę odpada.
    ///
    /// Zmierzone na żywym serwerze testowym 2026-08-16: kontener `tailscale` nasłuchuje na
    /// `100.64.0.10:34151` i `[fd7a:…]:63440` — to gniazda robocze demona, losowane
    /// przy każdym starcie. Bez tego progu robiły się z nich kafle „narzędzi", które
    /// prowadzą donikąd i zmieniają adres po restarcie kontenera.
    ///
    /// Panele administracyjne siedzą na portach stałych i niskich, więc próg nie odcina
    /// niczego, co warto pokazać (Plex 32400, Home Assistant 8123 — obie poniżej).
    static let ephemeralPortFloor = 32_768
}

// MARK: - Statystyki na żywo (SSH: /proc + sensors + nvidia-smi)

/// Zużycie i temperatury CPU (z SSH: /proc/stat + sensors).
nonisolated struct CPUStats: Sendable {
    var averageUsage: Double? = nil   // % (0…100), średnie zużycie wszystkich rdzeni
    var perCoreUsage: [Double] = []   // % na rdzeń
    var perCoreTemp: [Double] = []    // °C na rdzeń
    var packageTemp: Double? = nil    // °C
}

/// Stała charakterystyka procesora — z `lscpu`, czytana **raz na połączenie**.
///
/// API Proxmoksa podaje wyłącznie model i liczbę rdzeni. Reszta (wątki, cache, gniazda,
/// taktowanie) jest tylko w systemie i wymaga SSH — a to właśnie o nią pyta się patrząc
/// na kafel CPU (uwaga [U] 2026-08-17: „a co z wątkami, a co z ilością cache?").
nonisolated struct CPUDetails: Sendable, Equatable {
    var threads: Int? = nil           // CPU(s) — logiczne
    var coresPerSocket: Int? = nil
    var threadsPerCore: Int? = nil
    var sockets: Int? = nil
    var maxMHz: Double? = nil
    var minMHz: Double? = nil
    var l2: String? = nil             // gotowy tekst, np. „1,5 MiB"
    var l3: String? = nil
    var architecture: String? = nil
    var virtualization: String? = nil

    var isEmpty: Bool {
        threads == nil && l3 == nil && sockets == nil && maxMHz == nil
    }
}

/// Migawka licznika `/proc/stat` dla jednego wiersza `cpu*` — do policzenia delty.
nonisolated struct CPUJiffies: Sendable, Equatable {
    var total: Double
    var idle: Double
}

/// Rozbicie pamięci RAM (jak w dashboardzie TrueNAS).
nonisolated struct MemoryStats: Sendable {
    var total: Int64? = nil           // bajty
    var free: Int64? = nil            // bajty
    var zfsCache: Int64? = nil        // bajty (ARC)
    var services: Int64? = nil        // bajty (reszta „w użyciu")

    var hasBreakdown: Bool { free != nil && (zfsCache != nil || services != nil) }
}

/// Jeden wentylator z `sensors -j`.
///
/// Numer pochodzi z klucza (`fan2_input` → 2) i musi przetrwać parsowanie: bez niego
/// nie da się rzetelnie powiązać „Fan 2" w interfejsie z `pwm2` na serwerze, bo
/// `sensors -j` wraca jako słownik, a słownik nie ma określonej kolejności.
nonisolated struct FanReading: Identifiable, Sendable, Equatable {
    var index: Int                    // numer czujnika (1, 2, 3…)
    var rpm: Double

    var id: Int { index }
}

/// Wynik parsowania `sensors -j`: temperatury rdzeni i obroty wentylatorów.
nonisolated struct SensorsReading: Sendable, Equatable {
    var perCoreTemp: [Double] = []    // °C, posortowane po numerze rdzenia
    var packageTemp: Double? = nil    // °C
    var fans: [FanReading] = []       // posortowane po numerze czujnika
}

/// Opis GPU z `device.get_gpus` (dekodujemy tolerancyjnie — bierzemy tylko nazwę/producenta).
nonisolated struct GPUInfo: Decodable, Sendable {
    var vendor: String?
    var description: String?
}

/// Stan GPU (nazwa pewna z `device.get_gpus`, statystyki na żywo z nvidia-smi przez SSH).
nonisolated struct GPUStats: Sendable {
    var name: String? = nil            // np. „NVIDIA GeForce GTX 1650"
    var utilization: Double? = nil     // % (0…100)
    var temperature: Double? = nil     // °C
    var powerWatts: Double? = nil      // W
    var memoryUsed: Double? = nil      // MiB
    var memoryTotal: Double? = nil     // MiB

    var isPresent: Bool { name != nil || utilization != nil || temperature != nil }
}

// MARK: - Sterowanie wentylatorami (PWM)

/// Granice i tryby sterowania PWM w sysfs.
///
/// `minimum` to dolny próg suwaka i zapisu: `pwmX_enable = 1` wyłącza automatykę układu,
/// więc wartość 0 zatrzymywała wentylator na dobre — układ nie podniósłby obrotów przy
/// wzroście temperatury, bo już nie reguluje. Egzekwujemy próg w `ServerCommands.setPWM`,
/// nie tylko na suwaku, żeby ograniczenie nie wisiało wyłącznie w UI.
nonisolated enum PWM {
    static let minimum = 40            // ~16 % — najniższe obroty, przy których wentylator kręci
    static let maximum = 255
    static let manualMode = 1          // pwmX_enable = 1 → sterowanie ręczne
}

/// Jeden kanał PWM wykryty w sysfs.
///
/// `id` to ścieżka — stabilna między odświeżeniami, więc suwak nie resetuje pozycji
/// przy każdym `reload()` (przy `UUID()` resetował).
nonisolated struct PWMChannel: Identifiable, Sendable, Equatable {
    var path: String                  // np. /sys/class/hwmon/hwmon2/pwm1
    var value: Double                 // 0…255
    var mode: String                  // wartość pwmX_enable: 1 = ręczny, 2/5 = automat

    var id: String { path }

    /// Nazwa do pokazania — bez wspólnego przedrostka sysfs.
    var shortName: String { path.replacingOccurrences(of: "/sys/class/hwmon/", with: "") }
}

// MARK: - Zajętość nośników (lsblk + df)

/// Ile miejsca zajęto na jednym **nośniku fizycznym**, policzone z `lsblk` i `df`.
///
/// Po co osobno od `Pool`: kafel „Pamięć masowa" pokazuje storage'e Proxmoksa
/// (`local`, `local-lvm`, `aplikacje`…), a to nie to samo co dysk. Na serwerze testowym `/mnt/zasoby`
/// — nośnik NVMe 1 TB zapełniony w 85% — **nie jest** storagem Proxmoksa, więc
/// nie pojawiał się w programie ani razu. Odwrotnie też: `local` i `local-lvm` siedzą
/// na jednym NVMe, więc dwa wiersze magazynów opisują jeden nośnik.
nonisolated struct DiskUsage: Sendable, Equatable {
    /// Zajętość, jaką udało się zmierzyć: systemy plików z `df` **plus** zajętość
    /// cienkich pul LVM z tego nośnika (wolumeny maszyn, których `df` nie widzi).
    var used: Int64 = 0
    /// Suma pojemności zamontowanych systemów plików. Zostaje jako informacja,
    /// **nie jest już mianownikiem** — patrz `fraction`.
    var mountedTotal: Int64 = 0
    /// Pojemność całego nośnika wg `lsblk` — i to jest mianownik procentu.
    ///
    /// Zmienione 2026-08-19 na zgłoszenie [U]: koło sumowało systemy plików i
    /// pokazywało 2 TB, choć w maszynie siedzi 3,26 TB dysków. Różnicę robiły
    /// nośnik odmontowany (1 TB) i pula LVM (141 GB), której `df` nie raportuje.
    /// „Ile mam miejsca" znaczy „ile mam na dyskach", więc mianownikiem jest dysk.
    var capacity: Int64 = 0
    var mountpoints: [String] = []
    /// `usb`, `nvme`, `sata` — z kolumny `TRAN`.
    var transport: String? = nil

    var fraction: Double? { capacity > 0 ? Double(used) / Double(capacity) : nil }
    /// Czy z tego nośnika mamy **jakikolwiek** pomiar zajętości. Nośnik odmontowany
    /// nadal liczy się do sumy pojemności — po prostu nic na nim nie widać.
    var isMeasured: Bool { mountedTotal > 0 || used > 0 }
}

// MARK: - Pobór mocy (RAPL)

/// Pobór mocy policzony z liczników energii RAPL.
///
/// > [!important] To **nie jest** pomiar z gniazdka.
/// > RAPL raportuje procesor: rdzenie, część nierdzeniową i kontroler pamięci.
/// > Zasilacz mini PC nie ma telemetrii (brak IPMI, `sensors` nie podaje
/// > ani watów, ani amperów — zmierzone 2026-08-19), więc realnego poboru całego
/// > komputera nie da się odczytać programowo. Pokazujemy to, co da się zmierzyć,
/// > i mówimy wprost, czego dotyczy.
nonisolated struct PowerStats: Sendable, Equatable {
    /// Pobór całego pakietu procesora [W].
    var packageWatts: Double? = nil
    /// Domeny szczegółowe: `core`, `uncore`, `dram`.
    var domains: [String: Double] = [:]
    /// Pobór GPU z `nvidia-smi` — jedyny drugi układ, który sam podaje waty.
    var gpuWatts: Double? = nil

    /// Suma tego, co faktycznie zmierzone. Nie udaje poboru całego komputera.
    var measuredWatts: Double? {
        let parts = [packageWatts, gpuWatts].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// Surowa próbka liczników RAPL — dwie kolejne dają waty.
nonisolated struct RAPLSample: Sendable, Equatable {
    /// Znacznik czasu **serwera** w nanosekundach (`date +%s%N`). Liczymy nim różnicę
    /// czasu, bo zegar Maca i opóźnienie SSH nie mają z poborem serwera nic wspólnego.
    var timestampNanos: Int64
    /// nazwa domeny → licznik energii. Osobny typ, nie krotka: krotki nie są
    /// `Equatable`, więc słownik z krotką w wartości nie skompilowałby się w typie
    /// oznaczonym `Equatable`.
    var domains: [String: Counter]

    nonisolated struct Counter: Sendable, Equatable {
        var energy: Int64      // µJ, licznik narastający
        var max: Int64         // wartość, przy której licznik się przewija (0 = nieznana)
    }
}

// MARK: - Kondycja dysków (SMART przez SSH)

/// Pojedynczy wskaźnik SMART pokazany użytkownikowi (nazwa + wartość + waga problemu).
///
/// `critical` dzieli wskaźniki na dwie grupy, bo mieszanie ich wprowadzało w błąd:
/// **krytyczne** to te, przy których wartość różna od zera znaczy kłopot (sektory
/// przydzielone ponownie, błędy nieskorygowane); **informacyjne** mają wartość >0
/// w każdym zdrowym dysku (cykle zasilania, zapisane LBA) i kolorowanie ich na
/// czerwono byłoby fałszywym alarmem.
///
/// `id` zawiera numer wskaźnika, nie samą nazwę: dwa różne numery potrafią mieć tę
/// samą etykietę (173 i 177 to oba „wear leveling"), a zduplikowane `id` rozjeżdża
/// `ForEach`.
nonisolated struct SmartAttribute: Identifiable, Sendable, Equatable {
    enum Severity: Sendable, Equatable { case ok, warn, crit }
    var name: String
    var value: String
    var severity: Severity
    var critical: Bool = false
    /// Numer wskaźnika SMART (0 dla wskaźników spoza tabeli ATA, np. NVMe).
    var code: Int = 0

    var id: String { "\(code)-\(name)" }
}

/// Wynik odczytu SMART jednego dysku (`smartctl -j`).
nonisolated struct DiskHealthResult: Sendable {
    var ok: Bool                       // komenda się powiodła i mamy JSON
    var passed: Bool? = nil            // ogólny werdykt SMART (PASSED/FAILED)
    var temperature: Double? = nil     // °C
    var powerOnHours: Int? = nil       // godziny pracy
    var model: String? = nil
    var serial: String? = nil
    var selfTestStatus: String? = nil  // np. „Completed without error"
    var attributes: [SmartAttribute] = []
    var rawError: String? = nil        // gdy się nie udało — co poszło nie tak
}
