import Foundation

/// Czyste funkcje „tekst z serwera → struktura". Bez stanu, bez sieci, bez UI —
/// dzięki temu każdą da się przetestować na zapisanej odpowiedzi serwera, bez
/// uruchamiania NAS-a (target `mNasTests`).
///
/// Wydzielone z `AppModel`, który wcześniej łączył trzy role naraz: stan dla UI,
/// parsowanie tekstu i budowanie komend powłoki.
nonisolated enum StatsParsers {

    // MARK: - lscpu → stała charakterystyka procesora

    /// Parsuje `LC_ALL=C lscpu` — proste pary „klucz: wartość".
    ///
    /// `LC_ALL=C` po stronie komendy jest **warunkiem działania**: przy polskiej lokalizacji
    /// klucze nazywają się inaczej i całość zwróciłaby puste pola, bez żadnego błędu.
    static func lscpu(_ text: String) -> CPUDetails {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            fields[key] = value
        }
        var out = CPUDetails()
        out.threads = fields["CPU(s)"].flatMap { Int($0) }
        out.coresPerSocket = fields["Core(s) per socket"].flatMap { Int($0) }
        out.threadsPerCore = fields["Thread(s) per core"].flatMap { Int($0) }
        out.sockets = fields["Socket(s)"].flatMap { Int($0) }
        out.maxMHz = fields["CPU max MHz"].flatMap { Double($0) }
        out.minMHz = fields["CPU min MHz"].flatMap { Double($0) }
        // Klucz zmienił nazwę w util-linux 2.38 („L2 cache" → „L2 cache (sum)"),
        // więc bierzemy pierwszy pasujący zamiast jednej sztywnej nazwy.
        out.l2 = cacheSize(fields.first { $0.key.hasPrefix("L2 cache") }?.value)
        out.l3 = cacheSize(fields.first { $0.key.hasPrefix("L3 cache") }?.value)
        out.architecture = fields["Architecture"]
        out.virtualization = fields["Virtualization"]
        return out
    }

    /// „9 MiB (1 instance)" → „9 MiB".
    ///
    /// Nowsze `lscpu` dopisuje liczbę instancji cache'u. W kaflu to szum: rozmiar
    /// jest tym, o co się pyta, a nawias rozpycha wiersz i wypycha go poza kafel.
    private static func cacheSize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let paren = raw.firstIndex(of: "(") else { return raw }
        let trimmed = raw[raw.startIndex..<paren].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? raw : trimmed
    }

    // MARK: - Sekcje zbiorczego wywołania SSH

    /// Rozbija wyjście jednej komendy na sekcje po znacznikach `@@NAZWA`.
    /// Jedno połączenie SSH zwraca wszystkie statystyki naraz — tu je rozdzielamy.
    static func splitSections(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        var buf: [Substring] = []
        func flush() { if let c = current { out[c] = buf.joined(separator: "\n") } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { flush(); current = String(line.dropFirst(2)); buf = [] }
            else { buf.append(line) }
        }
        flush()
        return out
    }

    // MARK: - Narzędzia w kontenerach (pct + ss)

    /// Składa listę klikalnych narzędzi z wyjścia `ServerCommands.discoverWebServices()`.
    ///
    /// Trzy rzeczy odsiewamy tutaj, nie w interfejsie — bo to są decyzje o danych,
    /// a nie o wyglądzie:
    /// 1. **nasłuch tylko na pętli zwrotnej** (`127.0.0.1`, `::1`) — z Maca nieosiągalny,
    ///    kafel prowadziłby donikąd;
    /// 2. **porty infrastrukturalne** (SSH, DNS, poczta…) — nie są narzędziami z panelem;
    /// 3. **duplikaty** — usługa nasłuchująca i na IPv4, i na IPv6 pojawia się w `ss`
    ///    dwa razy, a jest jednym narzędziem.
    static func webServices(_ text: String) -> [DiscoveredService] {
        var out: [DiscoveredService] = []
        var seen: Set<String> = []
        /// Kontener, którego wiersze właśnie czytamy. Lokalny — dwa równoległe wywołania
        /// parsera nie mają prawa się o niego potknąć.
        var currentCT: (vmid: Int, name: String, address: String?)?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first else { continue }

            if head == "@@CT" {
                // Nowy kontener — dopiero po nim przyjdą jego IP i porty.
                guard parts.count >= 3, let id = Int(parts[1]) else { currentCT = nil; continue }
                currentCT = (vmid: id, name: String(parts[2]), address: nil)
                continue
            }
            guard var ct = currentCT else { continue }

            if head == "IP", parts.count >= 2 {
                ct.address = String(parts[1])
                currentCT = ct
                continue
            }

            guard head == "LISTEN", parts.count >= 2, let address = ct.address else { continue }
            guard let port = listeningPort(String(parts[1])) else { continue }
            guard !DiscoveredService.ignoredPorts.contains(port) else { continue }
            guard port < DiscoveredService.ephemeralPortFloor else { continue }

            let key = "\(ct.vmid):\(port)"
            guard seen.insert(key).inserted else { continue }

            // Nazwa kontenera pierwsza, port dopiero jako awaryjna podpowiedź —
            // patrz komentarz przy `DiscoveredService.tool(forName:)`.
            let byName = DiscoveredService.tool(forName: ct.name)
            let byPort = DiscoveredService.tool(forPort: port)
            out.append(DiscoveredService(vmid: ct.vmid,
                                         guestName: ct.name,
                                         address: address,
                                         port: port,
                                         toolName: byName ?? byPort?.name,
                                         secure: DiscoveredService.isSecure(port: port) || (byPort?.secure ?? false)))
        }
        // Rozpoznane narzędzia na górę, reszta pod spodem — po numerze kontenera i portu.
        return out.sorted {
            if ($0.toolName != nil) != ($1.toolName != nil) { return $0.toolName != nil }
            return ($0.vmid, $0.port) < ($1.vmid, $1.port)
        }
    }

    /// Wyciąga numer portu z adresu z `ss` (`0.0.0.0:3000`, `*:8080`, `[::]:443`,
    /// `127.0.0.1:9000`). Pętla zwrotna → `nil`, bo z Maca i tak się tam nie dobijemy.
    private static func listeningPort(_ field: String) -> Int? {
        guard let colon = field.lastIndex(of: ":") else { return nil }
        let host = String(field[field.startIndex..<colon])
        let portText = String(field[field.index(after: colon)...])
        guard let port = Int(portText), port > 0 else { return nil }
        if host == "127.0.0.1" || host == "[::1]" || host.hasPrefix("127.") { return nil }
        return port
    }

    // MARK: - Temperatury dysków (smartctl -j, sekcje per dysk)

    /// Co serwer powiedział o temperaturze jednego dysku.
    ///
    /// Rozróżnienie dwóch ostatnich przypadków jest tu całym sensem: z wyjścia
    /// `smartctl` wyglądają identycznie (brak pola `temperature`), a znaczą coś
    /// przeciwnego. Dysk uśpiony **ma** czujnik i za chwilę poda odczyt, więc stara
    /// wartość jest lepsza niż żadna. Dysk bez czujnika nie poda go nigdy i trzymanie
    /// czegokolwiek pod jego kluczem to trzymanie liczby, która nie ma pokrycia.
    enum OdczytTemperatury: Equatable {
        /// Dysk odpowiedział i podał °C.
        case wartosc(Double)
        /// Dysk odpowiedział treścią SMART-u, ale temperatury w niej nie ma.
        /// Tak zachowuje się NONAME S100 na serwerze testowym: firmware `FW01.0` nie wystawia
        /// atrybutu `194` i żadne narzędzie tego nie obejdzie (sprawdzone do poziomu
        /// surowej ramki ATA).
        case brakCzujnika
        /// Serwer nie odpowiedział treścią: dysk śpi (`-n standby`), zniknął
        /// albo `smartctl` się wyłożył.
        case brakOdpowiedzi
    }

    /// Wyciąga stan odczytu z serii odpowiedzi `smartctl -A -j`, po jednej na dysk.
    ///
    /// Odpowiedź bez temperatury poznajemy po tym, że **treść SMART-u jednak przyszła**
    /// — jest tablica atrybutów ATA albo log zdrowia NVMe. To pewniejsze niż czytanie
    /// `exit_status`, którego znaczenie zależy od wersji `smartctl` i od mostka USB.
    static func diskTemperatureReports(_ text: String) -> [String: OdczytTemperatury] {
        var out: [String: OdczytTemperatury] = [:]
        for (name, body) in splitSections(text) {
            guard let json = extractJSON(body),
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                out[name] = .brakOdpowiedzi
                continue
            }
            if let temp = obj["temperature"] as? [String: Any],
               let current = temp["current"] as? NSNumber {
                out[name] = .wartosc(current.doubleValue)
                continue
            }
            let maTabliceATA = (obj["ata_smart_attributes"] as? [String: Any])?["table"] != nil
            let maLogNVMe = obj["nvme_smart_health_information_log"] != nil
            out[name] = (maTabliceATA || maLogNVMe) ? .brakCzujnika : .brakOdpowiedzi
        }
        return out
    }

    /// Werdykt SMART z tego samego wyjścia co temperatury — `smart_status.passed`.
    ///
    /// Dysk **uśpiony** (`-n standby`) nie zwraca `smart_status` w ogóle i wtedy **nie ma
    /// go w wyniku**. To jest poprawne i celowe: „nie wiem, bo śpi" nie może wyglądać jak
    /// „FAILED". Ta sama zasada co przy temperaturach i ta sama, co przy braku połączenia
    /// w pasku menu — brak wiedzy to brak odznaki, nie awaria.
    static func diskHealth(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for (name, body) in splitSections(text) {
            guard let json = extractJSON(body),
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["smart_status"] as? [String: Any],
                  let passed = status["passed"] as? Bool else { continue }
            out[name] = passed ? "PASSED" : "FAILED"
        }
        return out
    }

    /// Same zmierzone °C, po nazwie urządzenia.
    ///
    /// Dysk uśpiony (`-n standby`) nie zwraca w ogóle pola `temperature` — wtedy nie ma
    /// go w wyniku i **to jest poprawne**. Wpisanie zera albo `nil` do słownika kazałoby
    /// interfejsowi pokazać „0 °C" dla dysku, który po prostu śpi.
    static func diskTemperatures(_ text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for (name, raport) in diskTemperatureReports(text) {
            if case .wartosc(let t) = raport { out[name] = t }
        }
        return out
    }

    // MARK: - CPU (/proc/stat)

    /// Zużycie CPU z delty liczników `/proc/stat` — agregat i per-core.
    /// Pierwsze wywołanie nie ma z czym porównać, więc zwraca puste wartości i tylko
    /// zapełnia `previous`.
    static func procStat(_ text: String,
                         previous: inout [String: CPUJiffies]) -> (aggregate: Double?, perCore: [Double]) {
        var agg: Double?
        var cores: [(Int, Double)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard let first = parts.first, first.hasPrefix("cpu") else { continue }
            let key = String(first)
            let nums = parts.dropFirst().compactMap { Double($0) }
            guard nums.count >= 5 else { continue }
            let total = nums.reduce(0, +)
            let idle = nums[3] + nums[4]              // idle + iowait
            if let prev = previous[key] {
                let dt = total - prev.total, di = idle - prev.idle
                if dt > 0 {
                    let usage = max(0, min(100, 100 * (1 - di / dt)))
                    if key == "cpu" { agg = usage }
                    else if let idx = Int(key.dropFirst(3)) { cores.append((idx, usage)) }
                }
            }
            previous[key] = CPUJiffies(total: total, idle: idle)
        }
        return (agg, cores.sorted { $0.0 < $1.0 }.map { $0.1 })
    }

    // MARK: - RAM (/proc/meminfo + arcstats)

    /// RAM: total/Free z `/proc/meminfo`, ZFS Cache z ARC, reszta = Usługi.
    /// `nil`, gdy wejście nie zawiera `MemTotal` — wtedy nie nadpisujemy tego, co już jest.
    static func memory(_ meminfo: String, arcBytes: Double?) -> MemoryStats? {
        var vals: [String: Double] = [:]
        for line in meminfo.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let numStr = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""
            if let v = Double(numStr) { vals[key] = v * 1024 }   // kB → bajty
        }
        guard let total = vals["MemTotal"], total > 0 else { return nil }
        let free = vals["MemAvailable"] ?? vals["MemFree"] ?? 0
        let zfs = min(max(arcBytes ?? 0, 0), total)
        let services = max(0, total - free - zfs)
        // `nil`, a nie `0`, gdy serwer w ogóle nie ma ZFS-a. Zero znaczy „zmierzono zero",
        // a tu nie ma czego mierzyć: `/proc/spl/kstat/zfs/arcstats` na LVM-thin nie istnieje.
        // Przy zerze panel RAM pokazywał wiersz „Cache ZFS (ARC): Zero KB" na maszynie bez
        // ZFS-a; przy `nil` `Format.bytes` wypisuje „—", czyli „nie dotyczy".
        return MemoryStats(total: Int64(total),
                           free: Int64(free),
                           zfsCache: arcBytes == nil ? nil : Int64(zfs),
                           services: Int64(services))
    }

    // MARK: - Czujniki (sensors -j)

    /// `sensors -j` (JSON): temperatury rdzeni/pakietu + obroty wentylatorów.
    ///
    /// Struktura wejścia to układ → czujnik → odczyty, a więc dwa zagnieżdżone słowniki,
    /// obchodzone w nieokreślonej kolejności. Dlatego numery (`coreN`, `fanN_input`)
    /// wyciągamy z kluczy i sortujemy po nich, zamiast polegać na kolejności obchodu.
    static func sensors(_ json: String) -> SensorsReading? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var coreTemps: [(Int, Double)] = []
        var fanList: [FanReading] = []
        var pkg: Double?

        for (chip, chipVal) in obj {
            guard let features = chipVal as? [String: Any] else { continue }
            let chipL = chip.lowercased()
            for (feat, featVal) in features {
                guard let readings = featVal as? [String: Any] else { continue }
                let fl = feat.lowercased()
                for (k, v) in readings {
                    let kl = k.lowercased()
                    guard kl.hasSuffix("_input"), let num = (v as? NSNumber)?.doubleValue else { continue }
                    if kl.hasPrefix("fan"), num >= 0 {
                        // `fan2_input` → 2. Bez tego numeru „Fan 2" w UI nie da się
                        // powiązać z `pwm2` na serwerze (audyt P2-06).
                        let digits = kl.dropFirst(3).prefix { $0.isNumber }
                        let index = Int(digits) ?? (fanList.count + 1)
                        fanList.append(FanReading(index: index, rpm: num))
                    } else if chipL.contains("coretemp") || fl.contains("core") || fl.contains("package"),
                              num > 0, num < 150 {
                        if fl.contains("package") {
                            pkg = num
                        } else if fl.contains("core") {
                            let idx = Int(fl.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
                                ?? coreTemps.count
                            coreTemps.append((idx, num))
                        }
                    }
                }
            }
        }

        var out = SensorsReading()
        out.fans = fanList.sorted { $0.index < $1.index }
        if !coreTemps.isEmpty {
            let sorted = coreTemps.sorted { $0.0 < $1.0 }.map { $0.1 }
            out.perCoreTemp = sorted
            out.packageTemp = pkg ?? (sorted.reduce(0, +) / Double(sorted.count))
        } else {
            out.packageTemp = pkg
        }
        return out
    }

    // MARK: - GPU (nvidia-smi CSV)

    /// GPU z `nvidia-smi --format=csv,noheader,nounits`.
    /// Puste wyjście = sterownik nieaktywny → `nil`, żeby nie skasować znanej nazwy karty
    /// (nazwa pochodzi z `device.get_gpus` i jest pewna nawet bez sterownika).
    static func gpu(_ csv: String, into current: GPUStats) -> GPUStats? {
        guard let line = csv.split(separator: "\n").first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        let cols = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cols.count >= 3 else { return nil }
        var out = current
        if !cols[0].isEmpty { out.name = cols[0] }
        out.utilization = Double(cols[1])
        out.temperature = Double(cols[2])
        if cols.count >= 5 { out.memoryUsed = Double(cols[3]); out.memoryTotal = Double(cols[4]) }
        if cols.count >= 6 { out.powerWatts = Double(cols[5]) }
        return out
    }

    // MARK: - SMART (smartctl -j)

    /// Wycina czysty blok JSON z wyjścia terminala — `-tt` (wymuszony pty dla sudo) potrafi
    /// dorzucić na początku baner MOTD, a na końcu „Connection to X closed.". Bierzemy tylko
    /// zawartość między pierwszym `{` a ostatnim `}`.
    static func extractJSON(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end])
    }

    // MARK: - Zajętość nośników (lsblk -P + df -B1 -P)

    /// Składa mapę „nośnik → zajętość" z dwóch sekcji jednego wywołania SSH.
    ///
    /// Kluczem jest **punkt montowania**, nie urządzenie z `df`. Powód: `df` dla woluminu
    /// LVM podaje `/dev/mapper/pve-root`, czego nie da się prosto powiązać z `nvme1n1`.
    /// `lsblk` zna za to i punkt montowania, i rodzica (`PKNAME`), więc idziemy po
    /// łańcuchu rodziców w górę aż do wiersza `TYPE="disk"` i tam dopisujemy zajętość.
    /// Dzięki temu `/` (LVM na NVMe) trafia na właściwy nośnik.
    static func diskUsage(lsblk: String, df: String, lvm: String = "") -> [String: DiskUsage] {
        // 1. punkt montowania → (zajęte, pojemność) z df
        var byMount: [String: (used: Int64, total: Int64)] = [:]
        for line in df.split(separator: "\n") {
            let c = line.split(separator: " ", omittingEmptySubsequences: true)
            // Filesystem 1-blocks Used Available Capacity Mounted-on
            guard c.count >= 6, let used = Int64(c[2]), let avail = Int64(c[3]) else { continue }
            let mount = c[5...].joined(separator: " ")
            // Mianownikiem jest **zajęte + dostępne**, a nie rozmiar systemu plików:
            // ext4 rezerwuje kilka procent dla roota, więc licząc z rozmiaru dostaje się
            // procent niższy niż w `df` i niż w panelu Proxmoksa. Ta sama liczba w dwóch
            // miejscach musi znaczyć to samo, inaczej program wygląda na zepsuty.
            byMount[mount] = (used, used + avail)
        }

        // 2. wiersze lsblk w formie par KLUCZ="wartość"
        struct Row { var pkname = ""; var type = ""; var tran = ""; var size: Int64 = 0; var mount = "" }
        var rows: [String: Row] = [:]
        var order: [String] = []
        for line in lsblk.split(separator: "\n") {
            let fields = keyValuePairs(String(line))
            guard let kname = fields["KNAME"], !kname.isEmpty else { continue }
            var r = Row()
            r.pkname = fields["PKNAME"] ?? ""
            r.type = fields["TYPE"] ?? ""
            r.tran = fields["TRAN"] ?? ""
            r.size = Int64(fields["SIZE"] ?? "") ?? 0
            r.mount = fields["MOUNTPOINT"] ?? ""
            rows[kname] = r
            order.append(kname)
        }

        // 3. korzeń łańcucha rodziców — nośnik, na którym wszystko siedzi
        func rootDisk(of kname: String) -> String? {
            var current = kname
            // Ogranicznik na wypadek zapętlonego łańcucha (thin pool potrafi mieć
            // dwie nogi wskazujące na siebie nawzajem w widoku lsblk).
            for _ in 0..<16 {
                guard let row = rows[current] else { return nil }
                if row.type == "disk" { return current }
                guard !row.pkname.isEmpty else { return nil }
                current = row.pkname
            }
            return nil
        }

        var out: [String: DiskUsage] = [:]
        // Nośniki: loop i ram-dyski pomijamy — to obrazy plików, nie sprzęt.
        for kname in order where rows[kname]?.type == "disk" {
            guard let row = rows[kname] else { continue }
            var u = DiskUsage()
            u.capacity = row.size
            u.transport = row.tran.isEmpty ? nil : row.tran
            out[kname] = u
        }

        for kname in order {
            guard let row = rows[kname], !row.mount.isEmpty, row.mount != "[SWAP]" else { continue }
            guard let disk = rootDisk(of: kname), var u = out[disk] else { continue }
            guard let m = byMount[row.mount] else { continue }
            u.used += m.used
            u.mountedTotal += m.total
            u.mountpoints.append(row.mount)
            out[disk] = u
        }

        // 4. cienkie pule LVM — zajętość, której `df` nie widzi
        //
        // Wolumeny maszyn nie są zamontowanymi systemami plików, więc dla `df` nie
        // istnieją. Na serwerze testowym to 141 GB puli na dysku systemowym: bez tego kroku
        // nośnik z maszynami wyglądał na zajęty w kilku procentach.
        var vgToDisk: [String: String] = [:]
        var poolBytes: [String: Int64] = [:]      // grupa wolumenów → zajęte bajty
        for line in lvm.split(separator: "\n") {
            let c = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = c.first else { continue }
            if head == "PV", c.count >= 3 {
                // `/dev/nvme1n1p3` → `nvme1n1p3` → korzeń łańcucha rodziców
                let device = String(c[1]).replacingOccurrences(of: "/dev/", with: "")
                if let disk = rootDisk(of: device) { vgToDisk[String(c[2])] = disk }
            } else if head == "POOL", c.count >= 4,
                      let size = Double(c[2]), let percent = Double(c[3]) {
                // Do tego miejsca dochodzą **wyłącznie pule** (`lv_attr` zaczyna się
                // od `t`), odsiane po stronie serwera. Wolumeny maszyn też mają
                // `data_percent`, ale ich zajętość siedzi **już w puli** — liczenie
                // obu naraz podwajało zajęte miejsce.
                //
                // Świadomie nie liczymy zwykłych wolumenów (`swap`, 8 GB na serwerze testowym):
                // przydzielone są, ale bez zamontowania nie wiadomo, ile z nich zajęte,
                // a wpisanie całego rozmiaru byłoby zgadywaniem.
                poolBytes[String(c[1]), default: 0] += Int64(size * percent / 100)
            }
        }
        for (vg, bytes) in poolBytes {
            guard let disk = vgToDisk[vg], var u = out[disk] else { continue }
            u.used += bytes
            out[disk] = u
        }
        return out
    }

    /// Rozbija wiersz `lsblk -P` (`KLUCZ="wartość" KLUCZ="wartość"…`) na słownik.
    /// Wartości potrafią zawierać spacje (`MODEL="DYSK HDD1000A"`), więc
    /// dzielenie po spacjach jest tu nie do użycia.
    private static func keyValuePairs(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = ""
        var value = ""
        var inValue = false
        var inQuotes = false
        for ch in line {
            if !inValue {
                if ch == "=" { inValue = true } else if !ch.isWhitespace { key.append(ch) }
                continue
            }
            if ch == "\"" {
                if inQuotes { out[key] = value; key = ""; value = ""; inValue = false; inQuotes = false }
                else { inQuotes = true }
                continue
            }
            if inQuotes { value.append(ch) }
        }
        return out
    }

    // MARK: - Pobór mocy (RAPL)

    /// Czyta sekcję `@@POWER`: pierwszy wiersz to znacznik czasu serwera w nanosekundach,
    /// dalej po jednym wierszu na domenę: `nazwa energia_uj max_uj`.
    static func raplSample(_ text: String) -> RAPLSample? {
        var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let head = lines.first, let stamp = Int64(head) else { return nil }
        lines.removeFirst()

        var domains: [String: RAPLSample.Counter] = [:]
        for line in lines {
            let c = line.split(separator: " ")
            guard c.count >= 2, let energy = Int64(c[1]) else { continue }
            let max = c.count >= 3 ? (Int64(c[2]) ?? 0) : 0
            domains[String(c[0])] = RAPLSample.Counter(energy: energy, max: max)
        }
        return domains.isEmpty ? nil : RAPLSample(timestampNanos: stamp, domains: domains)
    }

    /// Waty z dwóch kolejnych próbek: różnica energii przez różnicę czasu.
    ///
    /// Licznik `energy_uj` narasta i **przewija się** po osiągnięciu
    /// `max_energy_range_uj` (na serwerze testowym ~262 s przy 1 kW, w praktyce kilka godzin).
    /// Ujemna różnica znaczy przewinięcie, nie spadek poboru — dodajemy zakres.
    static func watts(from previous: RAPLSample, to current: RAPLSample) -> [String: Double] {
        let seconds = Double(current.timestampNanos - previous.timestampNanos) / 1_000_000_000
        // Zbyt krótki albo cofnięty odstęp daje dzielenie przez ~zero i liczby rzędu
        // tysięcy watów. Lepiej nie pokazać nic niż pokazać bzdurę.
        guard seconds >= 0.5, seconds <= 600 else { return [:] }

        var out: [String: Double] = [:]
        for (name, now) in current.domains {
            guard let before = previous.domains[name] else { continue }
            var delta = now.energy - before.energy
            if delta < 0 {
                guard before.max > 0 else { continue }
                delta += before.max
            }
            guard delta >= 0 else { continue }
            let w = Double(delta) / 1_000_000 / seconds
            // Górne sito: pojedynczy pakiet desktopowy nie ciągnie 1 kW. Taka wartość
            // znaczy przeoczone przewinięcie licznika albo zmianę zegara na serwerze.
            guard w >= 0, w < 1000 else { continue }
            out[name] = w
        }
        return out
    }

    static func smart(_ o: [String: Any]) -> DiskHealthResult {
        var res = DiskHealthResult(ok: true)
        res.model = o["model_name"] as? String
        res.serial = o["serial_number"] as? String
        if let s = o["smart_status"] as? [String: Any], let p = s["passed"] as? Bool { res.passed = p }
        if let t = o["temperature"] as? [String: Any], let c = t["current"] as? NSNumber { res.temperature = c.doubleValue }
        if let pot = o["power_on_time"] as? [String: Any], let h = pot["hours"] as? NSNumber { res.powerOnHours = h.intValue }
        if let sd = o["ata_smart_data"] as? [String: Any],
           let st = sd["self_test"] as? [String: Any],
           let stat = st["status"] as? [String: Any] {
            res.selfTestStatus = stat["string"] as? String
        }
        var attrs: [SmartAttribute] = []
        // Wskaźniki, przy których wartość różna od zera coś znaczy.
        // id → (etykieta, czy każda wartość >0 jest krytyczna)
        let critical: [Int: (String, Bool)] = [
            5:   (String(localized: "Sektory przydzielone ponownie"), true),
            197: (String(localized: "Sektory oczekujące"), true),
            198: (String(localized: "Sektory nieodwracalne"), true),
            199: (String(localized: "Błędy CRC (kabel SATA)"), false),
            187: (String(localized: "Błędy nieskorygowane"), true),
            10:  (String(localized: "Nieudane rozkręcenia talerzy"), false),
        ]
        // Wskaźniki informacyjne: wartość >0 jest normalna, więc nie kolorujemy jej
        // na czerwono — ale pokazać trzeba, bo dla dysku bez ani jednego wskaźnika
        // z listy wyżej panel był **pusty** i wyglądał jak awaria odczytu.
        // Zmierzone 2026-08-19 na NONAME S100 (USB): dziewięć atrybutów, z czego
        // ani jeden nie należał do listy krytycznej.
        let informational: [Int: String] = [
            1:   String(localized: "Surowa stopa błędów odczytu"),
            4:   String(localized: "Rozkręcenia talerzy"),
            12:  String(localized: "Cykle zasilania"),
            173: String(localized: "Zużycie komórek (wear leveling)"),
            177: String(localized: "Zużycie komórek (wear leveling)"),
            190: String(localized: "Temperatura (airflow)"),
            194: String(localized: "Temperatura"),
            231: String(localized: "Pozostała żywotność SSD"),
            233: String(localized: "Pozostała żywotność SSD"),
            241: String(localized: "Zapisano łącznie (LBA)"),
            242: String(localized: "Odczytano łącznie (LBA)"),
            192: String(localized: "Awaryjne parkowania głowic"),
        ]
        if let table = (o["ata_smart_attributes"] as? [String: Any])?["table"] as? [[String: Any]] {
            for row in table {
                guard let id = (row["id"] as? NSNumber)?.intValue else { continue }
                let rawObj = row["raw"] as? [String: Any]
                let raw = (rawObj?["value"] as? NSNumber)?.intValue
                    ?? Int((rawObj?["string"] as? String)?.split(separator: " ").first.map(String.init) ?? "") ?? 0

                if let (label, crit) = critical[id] {
                    let sev: SmartAttribute.Severity = raw == 0 ? .ok : (crit ? .crit : .warn)
                    attrs.append(SmartAttribute(name: label, value: "\(raw)", severity: sev, critical: true, code: id))
                    continue
                }

                // Dysk podaje temperaturę wskaźnikiem, a nie blokiem `temperature`
                // — częste na mostkach USB. Bierzemy stamtąd, jeśli nie ma lepszego.
                if (id == 194 || id == 190), res.temperature == nil, raw > 0, raw < 150 {
                    res.temperature = Double(raw)
                }

                // Nazwa własna dysku, gdy wskaźnika nie ma w żadnej z naszych list.
                // `Unknown_Attribute` od smartctl nic nie mówi, więc pokazujemy numer:
                // producent go zna, my nie — i lepiej to przyznać niż zmyślić etykietę.
                let vendorName = (row["name"] as? String) ?? ""
                let label = informational[id]
                    ?? (vendorName.isEmpty || vendorName.hasPrefix("Unknown")
                        ? String(localized: "Wskaźnik \(id) (nienazwany)")
                        : vendorName.replacingOccurrences(of: "_", with: " "))
                attrs.append(SmartAttribute(name: label, value: "\(raw)", severity: .ok, critical: false, code: id))
            }
        }
        // Dyski NVMe: osobny log zdrowia.
        if let nvme = o["nvme_smart_health_information_log"] as? [String: Any] {
            if let pct = nvme["percentage_used"] as? NSNumber {
                let u = pct.intValue
                attrs.append(SmartAttribute(name: String(localized: "Zużycie SSD"), value: "\(u)%", severity: u >= 90 ? .crit : (u >= 70 ? .warn : .ok), critical: true))
            }
            if let cw = nvme["critical_warning"] as? NSNumber {
                attrs.append(SmartAttribute(name: String(localized: "Ostrzeżenia krytyczne"), value: "\(cw.intValue)", severity: cw.intValue == 0 ? .ok : .crit, critical: true))
            }
            if res.temperature == nil, let t = nvme["temperature"] as? NSNumber { res.temperature = t.doubleValue }
            if res.powerOnHours == nil, let h = nvme["power_on_hours"] as? NSNumber { res.powerOnHours = h.intValue }
        }
        res.attributes = attrs
        return res
    }

    // MARK: - Kanały PWM

    /// Wyjście skryptu wykrywającego PWM: `/sys/class/hwmon/hwmon2/pwm1 = 128 tryb=1`.
    static func pwmChannels(_ text: String) -> [PWMChannel] {
        var rows: [PWMChannel] = []
        for line in text.split(separator: "\n") {
            guard let eq = line.range(of: " = ") else { continue }
            let path = String(line[line.startIndex..<eq.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[eq.upperBound...])
            let valStr = rest.split(separator: " ").first.map(String.init) ?? "0"
            let mode = rest.contains("tryb=") ? String(rest.split(separator: "=").last ?? "?").trimmingCharacters(in: .whitespaces) : "?"
            if ServerCommands.isValidPWMPath(path), let v = Double(valStr) {
                rows.append(PWMChannel(path: path, value: v, mode: mode))
            }
        }
        return rows.sorted { $0.path < $1.path }
    }

    // MARK: - Tłumaczenie błędów sterownika

    /// Tłumaczy typowe błędy `modprobe`/sterowników na jedno zdanie po polsku,
    /// zamiast zostawiać surowy zrzut terminala jako jedyne wyjaśnienie.
    /// `nil` = brak rozpoznanego wzorca, pokazujemy tylko surowe wyjście.
    static func driverError(_ text: String) -> String? {
        let t = text.lowercased()
        if t.contains("key was rejected") || t.contains("required key not available") {
            return String(localized: "Secure Boot w BIOS blokuje niepodpisany moduł sterownika. Trzeba wyłączyć Secure Boot w ustawieniach UEFI płyty (restart, wejście w BIOS) — inaczej jądro nigdy go nie wczyta.")
        }
        if t.contains("device or resource busy") {
            return String(localized: "Port urządzenia jest zarezerwowany przez ACPI (typowe na płytach Gigabyte) — sam moduł nie wystarczy. Wymaga to dodania parametru rozruchowego jądra acpi_enforce_resources=lax w GRUB i restartu. To zmiana rozruchu systemu, więc mNas nie robi jej automatycznie.")
        }
        if t.contains("no such device") {
            return String(localized: "Moduł nie rozpoznał żadnego obsługiwanego chipu na standardowych adresach. Kliknij przycisk Wykryj czujniki (sensors-detect) — to narzędzie realnie przeskanuje sprzęt i poda właściwy moduł/adres, zamiast zgadywać.")
        }
        if t.contains("no such file or directory") || t.contains("module not found") {
            return String(localized: "Sterownik nie jest zainstalowany w tym jądrze (albo jądro zmieniło się po aktualizacji, a moduł nie został przebudowany).")
        }
        if t.contains("vermagic") || (t.contains("exec format error") && t.contains("insmod")) {
            return String(localized: "Wersja modułu nie pasuje do aktualnego jądra — moduł trzeba przebudować (DKMS) po ostatniej aktualizacji systemu.")
        }
        return nil
    }
}
