import Foundation
import os

/// Klient REST API Proxmox VE (`https://host:8006/api2/json`).
///
/// Zastępuje `TrueNASClient` z wersji pod TrueNAS-a. Różnica jest zasadnicza, nie
/// kosmetyczna: TrueNAS wystawia **WebSocket JSON-RPC 2.0** z jedną sesją i metodami
/// middleware (`pool.query`, `service.query`), a Proxmox — **zwykły REST**, bezstanowy,
/// gdzie każde żądanie niesie własne uwierzytelnienie w nagłówku.
///
/// Stąd wynika reszta konstrukcji:
/// - nie ma `connect()` w sensie gniazda; `connect()` to pierwszy strzał, który
///   sprawdza token i wykrywa nazwę węzła,
/// - nie ma pętli odbioru ani mapy `pending` po `id`,
/// - „połączenie zerwane" poznajemy po błędach URLSession, nie po zamkniętym gnieździe.
///
/// Uwierzytelnienie: **token API** (`PVEAPIToken=user@realm!tokenid=sekret`). Świadomie
/// nie używamy biletu z `/access/ticket` — bilet wygasa po 2 godzinach i wymagałby
/// odnawiania oraz nagłówka `CSRFPreventionToken` przy każdym zapisie. Token nie wygasa
/// i nie potrzebuje CSRF.
actor ProxmoxClient {

    enum ClientError: LocalizedError {
        case notConnected
        case connectionClosed
        /// Serwer odpowiedział kodem błędu HTTP.
        case http(status: Int, message: String)
        case authFailed(String)
        case decoding(String)
        case badResponse
        case timeout(path: String)
        /// Nie udało się ustalić, którym węzłem klastra się zajmujemy.
        case noNode
        /// Certyfikat serwera nie zgadza się z przypiętym przy pierwszym połączeniu.
        case certificateMismatch(expected: String, received: String)
        /// Z zaufania nie dało się wyciągnąć klucza publicznego — nie ma czego porównać.
        case certificateUnreadable
        /// Plik przypięć jest, ale nieczytelny — nie wiadomo, któremu certyfikatowi ufać.
        case pinStoreUnreadable(path: String)

        var errorDescription: String? {
            switch self {
            case .notConnected:      return String(localized: "Brak połączenia z serwerem.")
            case .connectionClosed:  return String(localized: "Połączenie z serwerem zostało przerwane.")
            case .http(let s, let m):
                switch s {
                case 401: return String(localized: "Serwer odrzucił token API (401). Sprawdź identyfikator tokenu i sekret.")
                // Najczęstsza przyczyna nie jest oczywista: przy tworzeniu tokenu Proxmox
                // domyślnie ZAZNACZA „Separację uprawnień", a taki token startuje z zerowymi
                // prawami — niezależnie od tego, że należy do roota. Komunikat prowadzi
                // wprost do naprawy, bo samo „brak uprawnień" wysyła użytkownika w złą stronę
                // (sprawdzanie konta zamiast dopisania uprawnienia tokenowi).
                case 403: return String(localized: """
                Token API nie ma uprawnień (403) — przy tworzeniu została zaznaczona \
                „Separacja uprawnień”, więc token nie odziedziczył praw konta. \
                Napraw: Centrum danych → Uprawnienia → Dodaj → Uprawnienie tokenu API, \
                ścieżka „/”, rola PVEAdmin (albo PVEAuditor, jeśli ma tylko podglądać), \
                Propaguj zaznaczone. Tokenu nie trzeba tworzyć od nowa.
                """)
                default:  return String(localized: "Błąd serwera (\(s)): \(m)")
                }
            case .authFailed(let m): return m
            case .decoding(let m):   return String(localized: "Błąd odczytu odpowiedzi: \(m)")
            case .badResponse:       return String(localized: "Nieprawidłowa odpowiedź serwera.")
            case .timeout(let path): return String(localized: "Serwer nie odpowiedział na czas (\(path)).")
            case .noNode:            return String(localized: "Nie udało się ustalić nazwy węzła Proxmoksa (`/nodes` nie zwróciło nic).")
            case .certificateMismatch:
                return String(localized: "Certyfikat serwera się zmienił. Jeśli nie był wymieniany celowo, ktoś podszywa się pod serwer — połączenie zostało przerwane.")
            case .certificateUnreadable:
                return String(localized: "Nie udało się odczytać klucza publicznego z certyfikatu serwera — połączenie przerwane dla bezpieczeństwa.")
            case .pinStoreUnreadable(let path):
                return String(localized: "Plik zapamiętanych certyfikatów jest uszkodzony (\(path)) — połączenie przerwane, bo nie wiadomo, któremu certyfikatowi ufać. Jeśli nikt przy nim nie grzebał, usuń ten plik: następne połączenie zapamięta certyfikat od nowa.")
            }
        }
    }

    /// Port panelu i API Proxmoksa. Stały — Proxmox nie pozwala go zmienić bez grzebania
    /// w `pveproxy`, a wpisywanie `:8006` w polu adresu tylko myliłoby użytkownika.
    static let port = 8006

    private let host: String
    private let session: URLSession
    private let trustDelegate: TrustDelegate
    /// Gotowy nagłówek `Authorization`. Trzymany po uwierzytelnieniu, bo REST jest
    /// bezstanowy — leci przy każdym żądaniu.
    private var authorization: String?
    /// Nazwa węzła (np. `pve`). Wykrywana raz, w `connect()`; wchodzi w większość ścieżek.
    private(set) var node: String?

    init(host: String) {
        self.host = host
        let delegate = TrustDelegate(host: host)
        self.trustDelegate = delegate
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // Bez tego URLSession potrafi oddać odpowiedź sprzed sekund jako świeżą —
        // przy odświeżaniu co 5 s dashboard zamarzłby na starych liczbach.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Połączenie

    /// Sprawdza token i ustala węzeł. Odpowiednik `connect()` + `authenticate()` z wersji
    /// TrueNAS — tyle że tu nie ma czego otwierać, więc jedno i drugie to ten sam strzał.
    ///
    /// - Parameters:
    ///   - tokenID: pełny identyfikator, np. `root@pam!mnas`.
    ///   - secret: sekret tokenu (UUID pokazany raz, przy tworzeniu).
    func connect(tokenID: String, secret: String) async throws {
        let id = tokenID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.contains("@"), id.contains("!") else {
            throw ClientError.authFailed(String(localized: """
            Identyfikator tokenu musi mieć postać `użytkownik@realm!nazwa`, np. `root@pam!kopia`. \
            Wpisano: „\(id)”.
            """))
        }
        // `trimmingCharacters` zdejmuje białe znaki tylko z KOŃCÓW. Znak nowej linii
        // w ŚRODKU wklejonego sekretu (albo w identyfikatorze) przeszedłby stąd wprost
        // do nagłówka `Authorization` i rozciął żądanie HTTP na dwa. Ryzyko jest
        // teoretyczne — użytkownik wkleja własny sekret — ale sprawdzenie kosztuje linijkę,
        // a komunikat oszczędza zgadywania, czemu logowanie „nie działa bez powodu".
        let zepsute = CharacterSet.newlines.union(CharacterSet.controlCharacters)
        guard id.rangeOfCharacter(from: zepsute) == nil,
              key.rangeOfCharacter(from: zepsute) == nil else {
            throw ClientError.authFailed(String(localized: """
            Identyfikator albo sekret tokenu zawiera znak nowej linii lub znak sterujący. \
            Najczęstsza przyczyna: skopiowanie wartości razem z łamaniem wiersza. \
            Wklej ją ponownie, w jednym kawałku.
            """))
        }
        authorization = "PVEAPIToken=\(id)=\(key)"
        Log.connection.notice("Łączę z https://\(self.host, privacy: .public):\(Self.port)/api2/json")

        let nodes = try await get("/nodes", as: [NodeSummary].self)
        // Klaster jednowęzłowy to typowy przypadek domowy; przy kilku węzłach bierzemy
        // ten, który faktycznie żyje, zamiast pierwszego z brzegu.
        guard let picked = nodes.first(where: { $0.status == "online" }) ?? nodes.first else {
            throw ClientError.noNode
        }
        node = picked.node
        Log.connection.notice("Węzeł: \(picked.node, privacy: .public)")
    }

    func disconnect() {
        authorization = nil
        node = nil
        session.invalidateAndCancel()
    }

    // MARK: - Warstwa HTTP

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: "https://\(host):\(Self.port)/api2/json\(path)") else {
            throw ClientError.badResponse
        }
        return u
    }

    /// Surowe żądanie. Zwraca zawartość pola `data` z koperty Proxmoksa.
    ///
    /// Proxmox pakuje **każdą** odpowiedź w `{"data": …}` — także `null` przy akcjach,
    /// które nic nie zwracają. Rozpakowujemy to tutaj, żeby wywołania wyżej widziały
    /// wyłącznie treść.
    private func request(_ path: String, method: String = "GET", form: [String: String]? = nil) async throws -> Data {
        guard let authorization else { throw ClientError.notConnected }
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formEncode(form).data(using: .utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as NSError where error.domain == NSURLErrorDomain
                                        && error.code == NSURLErrorTimedOut {
            throw ClientError.timeout(path: path)
        } catch {
            // Odrzucenie certyfikatu wraca z URLSession jako suche „cancelled" —
            // podmieniamy na konkretny powód zapamiętany przez delegata.
            if let recorded = trustDelegate.takeError() { throw recorded }
            throw error
        }

        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Log.rpc.error("\(method, privacy: .public) \(path, privacy: .public) → \(http.statusCode, privacy: .public)")
            throw ClientError.http(status: http.statusCode, message: body.isEmpty ? String(localized: "(brak treści)") : body)
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse
        }
        let payload = envelope["data"] ?? NSNull()
        guard let out = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else {
            throw ClientError.badResponse
        }
        return out
    }

    /// GET z dekodowaniem do konkretnego typu.
    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await request(path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decoding("\(path): \(error)")
        }
    }

    /// POST bez oczekiwania na treść (akcje: start/stop usługi, restart węzła).
    @discardableResult
    private func post(_ path: String, form: [String: String] = [:]) async throws -> Data {
        try await request(path, method: "POST", form: form.isEmpty ? nil : form)
    }

    /// Kodowanie ciała `application/x-www-form-urlencoded`.
    ///
    /// Biała lista jest wypisana **jawnie i po ASCII**, a nie zbudowana z
    /// `CharacterSet.alphanumerics` — tamten zbiór jest **unikodowy**, więc uznawał za
    /// „literę" także `ą`, `ż` czy cyrylicę i przepuszczał je do ciała żądania bez
    /// zakodowania. Dziś jedyne wywołanie to `command=reboot`, więc była to pułapka
    /// na przyszłość, nie dzisiejszy błąd — ale koszt jej rozbrojenia to jedna linia.
    /// Zbiór odpowiada „unreserved characters" z RFC 3986.
    private static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields
            .map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
    }

    /// Nazwa węzła albo błąd — żeby wywołania nie musiały co chwilę rozpakowywać `Optional`.
    private func requireNode() throws -> String {
        guard let node else { throw ClientError.noNode }
        return node
    }

    // MARK: - Odczyty

    /// Stan węzła: opis systemu **plus** bieżące zużycie CPU i rozbicie RAM.
    ///
    /// Proxmox podaje w tej samej odpowiedzi `cpu` (ułamek 0…1) i `memory.used/free`.
    /// To są **realne pomiary**, nie przybliżenia — więc kafle CPU i RAM wypełniają się
    /// od razu po połączeniu, jeszcze zanim ktokolwiek skonfiguruje SSH. Wcześniej te
    /// pola leciały do kosza, a apka rysowała „przybliżone" z `loadavg` i pusty wykres.
    func nodeSnapshot() async throws -> NodeSnapshot {
        let node = try requireNode()
        let s = try await get("/nodes/\(node)/status", as: NodeStatus.self)
        let info = SystemInfo(
            version: Self.shortVersion(s.pveversion),
            hostname: node,
            model: s.cpuinfo?.model,
            cores: s.cpuinfo?.cpus,
            physicalCores: s.cpuinfo?.cores,
            physmem: FlexibleInt(s.memory?.total),
            uptimeSeconds: s.uptime.map(Double.init),
            // Proxmox podaje loadavg jako tablicę **napisów** („0.14"), nie liczb.
            loadavg: s.loadavg?.compactMap(Double.init),
            systemProduct: s.kversion
        )
        return NodeSnapshot(
            info: info,
            cpuUsage: s.cpu.map { min(100, max(0, $0 * 100)) },
            memoryTotal: s.memory?.total,
            memoryUsed: s.memory?.used,
            memoryFree: Self.wolnaPamiec(available: s.memory?.available, free: s.memory?.free)
        )
    }

    /// Która liczba znaczy „wolna pamięć".
    ///
    /// 🔴 **`available`, nie `free`** — i to jest cała naprawa migającego kafla RAM
    /// (zgłoszenie 2026-08-20: „co 5 sekund na sekundę RAM prawie cały zajęty").
    /// Kafel dostaje w każdej turze najpierw pomiar z API, a chwilę później ten z SSH;
    /// dopóki mierzyły dwie różne rzeczy, różnica była widoczna jako migotanie.
    ///
    /// Zmierzone na serwerze testowym 2026-08-20, ten sam moment, te same 8 GB:
    ///
    /// | Źródło | Wartość | Co to jest |
    /// |---|---:|---|
    /// | API `memory.free` | 309 MB | goły `MemFree` — reszta to bufory i cache |
    /// | API `memory.available` | 5,37 GB | `MemAvailable` |
    /// | SSH `/proc/meminfo` | 5,38 GB | `MemAvailable`, czytane przez `StatsParsers.memory` |
    ///
    /// Zapasowe `free` zostaje dla starszych wydań Proxmoksa, które `available` nie podają:
    /// liczba za niska jest gorsza od dobrej, ale wciąż lepsza od pustego kafla.
    static func wolnaPamiec(available: Int64?, free: Int64?) -> Int64? {
        available ?? free
    }

    /// `pve-manager/9.2.10/abcdef` → `9.2.10`. Pełny ciąg nie mieści się w kaflu,
    /// a sam numer to jedyna część, która cokolwiek mówi.
    private static func shortVersion(_ raw: String?) -> String {
        guard let raw else { return String(localized: "Proxmox VE") }
        let parts = raw.split(separator: "/")
        guard parts.count >= 2 else { return raw }
        return String(localized: "Proxmox VE \(parts[1])")
    }

    /// Magazyny → `Pool`. W TrueNAS-ie kafel „Pamięć masowa" pokazywał pule ZFS;
    /// w Proxmoksie odpowiednikiem są **storage'e** (`local`, `local-lvm`, `backup2`…),
    /// bo to one mają pojemność, zajętość i stan włączenia.
    ///
    /// Magazyny wyłączone (`enabled = 0`) pomijamy — pokazywanie zer dla czegoś, co
    /// świadomie nie działa, tylko zaśmieca kafel.
    func storages() async throws -> [Pool] {
        let node = try requireNode()
        let list = try await get("/nodes/\(node)/storage", as: [StorageEntry].self)
        return list
            .filter { ($0.enabled ?? 1) != 0 }
            .map { s in
                Pool(
                    name: s.storage,
                    kind: s.type,
                    status: (s.active ?? 0) != 0 ? "ONLINE" : "OFFLINE",
                    healthy: (s.active ?? 0) != 0,
                    size: FlexibleInt(s.total),
                    allocated: FlexibleInt(s.used),
                    free: FlexibleInt(s.avail)
                )
            }
            .sorted { $0.name < $1.name }
    }

    /// Dyski fizyczne → `Disk`. Nazwę skracamy z `/dev/nvme0n1` do `nvme0n1`, bo taką
    /// postać przyjmują komendy SSH (`smartctl /dev/<nazwa>`) i tak wygląda w kaflu.
    /// - Parameter skipSmart: gdy `true` (domyślnie) Proxmox **nie** odpala `smartctl`.
    ///
    /// 🔴 Bez `skipsmart=1` każde odpytanie tej ścieżki uruchamia na serwerze `smartctl`
    /// na **każdym** dysku po kolei. Przy odświeżaniu co 5 s znaczy to ~12 300 przebiegów
    /// na dobę i **talerzowy dysk w kieszeni USB nie ma prawa zasnąć**. Zmierzone na
    /// serwerze testowym 2026-09-11: 24 żądania do talerzy bez tego parametru, **0** z nim, przy
    /// kontroli dodatniej. Wywołanie budziło śpiący dysk w ciągu jednej tury.
    ///
    /// Kondycja SMART dochodzi osobno — ścieżką SSH `smartctl -A -H -n standby`
    /// (`ServerCommands.diskTemperatures`), która śpiącego dysku **nie budzi**. Ta sama
    /// zasada stała już w apce dla temperatur; tutaj była przeoczona.
    ///
    /// `skipSmart: false` zostaje wyłącznie na wypadek wyłączonego SSH — wtedy kondycja
    /// nie ma innego źródła. Wywoływać **rzadko**: każde takie zapytanie budzi talerze.
    func disks(skipSmart: Bool = true) async throws -> [Disk] {
        let node = try requireNode()
        let sciezka = "/nodes/\(node)/disks/list" + (skipSmart ? "?skipsmart=1" : "")
        let list = try await get(sciezka, as: [DiskEntry].self)
        return list.map { d in
            Disk(
                name: d.devpath.replacingOccurrences(of: "/dev/", with: ""),
                model: d.model,
                serial: d.serial,
                type: d.type?.uppercased(),
                size: FlexibleInt(d.size),
                // Oba pola przychodziły z API od początku i były tu wyrzucane. Bez nich
                // kafel „Dyski" umiał tylko zapalić trójkąt na temperaturze i nie miał
                // czym powiedzieć, co się stało — zgłoszenie z 2026-08-23.
                health: d.health,
                wearout: d.wearout
            )
        }
    }

    /// Usługi Proxmoksa (`pveproxy`, `pvedaemon`, `pve-cluster`…) → `Service`.
    func services() async throws -> [Service] {
        let node = try requireNode()
        let list = try await get("/nodes/\(node)/services", as: [ServiceEntry].self)
        return list.map { s in
            Service(
                service: s.service,
                state: (s.state ?? "").lowercased() == "running" ? "RUNNING" : "STOPPED",
                enable: (s.unitState ?? "") == "enabled"
            )
        }
    }

    /// Maszyny wirtualne i kontenery z całego klastra.
    func guests() async throws -> [Guest] {
        let list = try await get("/cluster/resources?type=vm", as: [ClusterResource].self)
        return list
            .filter { ($0.template ?? 0) == 0 }     // szablony to nie maszyny do pokazania
            .map { r in
                Guest(
                    vmid: r.vmid ?? 0,
                    name: r.name ?? "vm\(r.vmid ?? 0)",
                    kind: r.type == "lxc" ? .container : .virtualMachine,
                    running: r.status == "running",
                    cpuFraction: r.cpu,
                    maxCPU: r.maxcpu,
                    memoryUsed: r.mem,
                    memoryTotal: r.maxmem,
                    diskUsed: r.disk,
                    diskTotal: r.maxdisk,
                    uptimeSeconds: r.uptime.map(Double.init)
                )
            }
            .sorted { $0.vmid < $1.vmid }
    }

    // MARK: - Transfery (RRD)
    //
    // Jedyne źródło monitora transferów od 2026-08-29. Poprzednie (`/var/log/pomiar-ruchu`
    // po SSH) użytkownik skasował tego dnia; RRD mierzy to samo, tylko sam. Cała interpretacja
    // liczb — a zwłaszcza to, że host sumuje wyłącznie karty fizyczne — siedzi
    // w `Transfery.swift` i tam trzeba czytać, zanim się te wywołania podepnie gdzie indziej.
    //
    // Koszt zmierzony 2026-08-29 na serwerze testowym: odpowiedź hosta to 28 051 B surowo
    // i 4 554 B po gzipie, kontenera 20 646 / 2 286 B. `pveproxy` kompresuje, gdy klient
    // to przyjmuje (`APIServer/AnyEvent.pm:348`), a `URLSession` wysyła `Accept-Encoding`
    // sam z siebie. Przy dziesięciu źródłach raz na minutę to około 25 kB — trzy rzędy
    // wielkości poniżej ruchu, który ten monitor obserwuje.

    /// Szereg RRD **węzła** — czyli całego łącza.
    /// `maksima: true` = `cf=MAX` — najwyższa próbka w każdym przedziale (historia, od 1.2.43).
    /// Monitor transferów zostaje na średnich.
    func rrdWezla(_ okno: OknoRRD, maksima: Bool = false) async throws -> [WierszRRD] {
        let node = try requireNode()
        return try await get("/nodes/\(node)/rrddata?timeframe=\(okno.rawValue)\(maksima ? "&cf=MAX" : "")", as: [WierszRRD].self)
    }

    /// Historia zajętości jednego magazynu (od 1.2.16). Proxmox trzyma ją sam
    /// (`pvestatd`), rok wstecz — także dla dysku kopii na talerzu, bez nowego odczytu.
    func rrdMagazynu(_ id: String, okno: OknoRRD, maksima: Bool = false) async throws -> [WierszMagazynuRRD] {
        let node = try requireNode()
        return try await get("/nodes/\(node)/storage/\(id)/rrddata?timeframe=\(okno.rawValue)\(maksima ? "&cf=MAX" : "")",
                             as: [WierszMagazynuRRD].self)
    }

    /// Szereg RRD jednego gościa. Gałąź zależy od rodzaju: kontener siedzi pod `lxc`,
    /// maszyna pod `qemu`, i pomylenie ich daje czyste 404, nie pustą listę.
    func rrdGoscia(_ guest: Guest, okno: OknoRRD, maksima: Bool = false) async throws -> [WierszRRD] {
        let node = try requireNode()
        let galaz = guest.kind == .container ? "lxc" : "qemu"
        return try await get("/nodes/\(node)/\(galaz)/\(guest.vmid)/rrddata?timeframe=\(okno.rawValue)\(maksima ? "&cf=MAX" : "")",
                             as: [WierszRRD].self)
    }

    /// Zadania zakończone błędem → `Alert`.
    ///
    /// Proxmox **nie ma** systemu alertów w rozumieniu TrueNAS-a (`alert.list`). Najbliższy
    /// prawdziwy odpowiednik to nieudane zadania: przerwany backup, nieudany start
    /// kontenera, padnięta replikacja. Zamiast zostawiać kafel „Alerty" pusty na zawsze,
    /// budujemy alerty z tego, co faktycznie poszło źle.
    ///
    /// `errors=1` zwraca wyłącznie zadania zakończone czymś innym niż `OK`.
    /// Zwraca `nil`, gdy odczytu **nie udało się wykonać**, i pustą tablicę, gdy serwer
    /// odpowiedział, że nieudanych zadań nie ma. Rozróżnienie jest konieczne: wcześniej
    /// oba przypadki dawały `[]`, więc chwilowy błąd sieci wyglądał w interfejsie
    /// identycznie jak „wszystko w porządku" i czyścił alerty z ekranu.
    func failedTaskAlerts(limit: Int = 20) async -> [Alert]? {
        guard let node = try? requireNode() else { return nil }
        guard let tasks = try? await get("/nodes/\(node)/tasks?errors=1&limit=\(limit)", as: [TaskEntry].self) else {
            return nil
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "d.MM HH:mm"
        return tasks.compactMap { t in
            guard let status = t.status, status != "OK" else { return nil }
            let when = t.starttime.map { stamp.string(from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? ""
            let what = [t.type, t.id].compactMap { $0 }.joined(separator: " ")
            return Alert(
                uuid: t.upid,
                level: "CRITICAL",
                formatted: "\(when) — \(what): \(status)",
                dismissed: false,
                klass: t.type
            )
        }
    }

    // MARK: - Przebiegi: zadania trwające i zakończone

    /// Zadania **wykonujące się w tej chwili**.
    ///
    /// `source=active` to filtr samego Proxmoksa — pytanie o pełną listę i odsiewanie
    /// po `endtime` na Macu dałoby ten sam wynik kosztem przesyłania kilkuset wpisów
    /// co turę odświeżania.
    ///
    /// Zwraca `nil`, gdy odczyt się nie powiódł (jak `failedTaskAlerts`): pusta lista
    /// znaczy „nic teraz nie chodzi", a to zupełnie inna wiadomość niż „nie wiem".
    func aktywneZadania() async -> [TaskEntry]? {
        guard let node = try? requireNode() else { return nil }
        return try? await get("/nodes/\(node)/tasks?source=active&limit=50", as: [TaskEntry].self)
    }

    /// Ostatnie zadania danego rodzaju — do pokazania „kiedy ostatnio i z jakim skutkiem".
    func ostatnieZadania(rodzaj: String, limit: Int = 5) async -> [TaskEntry]? {
        guard let node = try? requireNode() else { return nil }
        let bezpieczny = ServerCommands.safeName(rodzaj)
        guard !bezpieczny.isEmpty else { return nil }
        return try? await get("/nodes/\(node)/tasks?typefilter=\(bezpieczny)&limit=\(limit)",
                              as: [TaskEntry].self)
    }

    /// Log zadania — z niego liczy się postęp `vzdump` (patrz `PrzebiegiParsers`).
    ///
    /// `limit` jest tu duży celowo: postęp liczymy z **całego** logu, bo licznik
    /// skończonych kontenerów to suma linii „Finished Backup of VM", a nie ostatnia z nich.
    func logZadania(upid: String, limit: Int = 500) async -> [String]? {
        guard let node = try? requireNode() else { return nil }
        guard let zakodowany = upid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        let linie = try? await get("/nodes/\(node)/tasks/\(zakodowany)/log?limit=\(limit)",
                                   as: [TaskLogLine].self)
        return linie?.compactMap(\.t)
    }

    /// Wynik zadania, którego już nie ma na liście aktywnych. Odpowiada na jedyne
    /// pytanie, które ma wtedy sens: skończyło się dobrze czy źle.
    func wynikZadania(upid: String) async -> TaskStatus? {
        guard let node = try? requireNode() else { return nil }
        guard let zakodowany = upid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return try? await get("/nodes/\(node)/tasks/\(zakodowany)/status", as: TaskStatus.self)
    }

    // MARK: - Akcje zmieniające serwer

    func setService(_ name: String, running: Bool) async throws {
        let node = try requireNode()
        let safe = ServerCommands.safeName(name)
        guard !safe.isEmpty else { throw ClientError.badResponse }
        try await post("/nodes/\(node)/services/\(safe)/\(running ? "start" : "stop")")
    }

    func restartService(_ name: String) async throws {
        let node = try requireNode()
        let safe = ServerCommands.safeName(name)
        guard !safe.isEmpty else { throw ClientError.badResponse }
        try await post("/nodes/\(node)/services/\(safe)/restart")
    }

    func rebootNode() async throws {
        let node = try requireNode()
        try await post("/nodes/\(node)/status", form: ["command": "reboot"])
    }

    /// Start/stop maszyny albo kontenera. `kind` decyduje o gałęzi ścieżki (`qemu` vs `lxc`).
    func setGuest(_ guest: Guest, running: Bool) async throws {
        let node = try requireNode()
        let branch = guest.kind == .container ? "lxc" : "qemu"
        let action = running ? "start" : "shutdown"
        try await post("/nodes/\(node)/\(branch)/\(guest.vmid)/status/\(action)")
    }
}

// MARK: - Kształty odpowiedzi Proxmoksa
//
// Typy prywatne dla warstwy transportu: mapują JSON 1:1, a `ProxmoxClient` przekłada je
// na modele, które zna dashboard. Dzięki temu zmiana pola w API nie sięga do widoków.

private nonisolated struct NodeSummary: Decodable {
    let node: String
    let status: String?
}

private nonisolated struct NodeStatus: Decodable {
    struct CPUInfo: Decodable {
        let cpus: Int?
        let cores: Int?
        let model: String?
    }
    struct Memory: Decodable {
        let total: Int64?
        let used: Int64?
        let free: Int64?
        /// `MemAvailable`, czyli ile system realnie odda programom. **To jest liczba,
        /// której chcemy** — `free` wyżej to goły `MemFree`, a on na serwerze z rozgrzanym
        /// cache'em wynosi kilkaset MB przy kilku GB faktycznie wolnych.
        /// Starsze wydania Proxmoksa tego pola nie mają, stąd `Optional` i zapasowe `free`.
        let available: Int64?
    }
    let uptime: Int?
    let loadavg: [String]?
    /// Zużycie CPU jako ułamek 0…1 — gotowy pomiar, nie przybliżenie z `loadavg`.
    let cpu: Double?
    let cpuinfo: CPUInfo?
    let memory: Memory?
    let kversion: String?
    let pveversion: String?
}

private nonisolated struct StorageEntry: Decodable {
    let storage: String
    let type: String?
    let total: Int64?
    let used: Int64?
    let avail: Int64?
    let enabled: Int?
    let active: Int?
}

private nonisolated struct DiskEntry: Decodable {
    let devpath: String
    let size: Int64?
    let model: String?
    let serial: String?
    let type: String?
    let health: String?
    let wearout: FlexibleInt?
}

private nonisolated struct ServiceEntry: Decodable {
    let service: String
    let name: String?
    let desc: String?
    let state: String?
    let unitState: String?

    // Proxmox używa `unit-state` z myślnikiem, więc `convertFromSnakeCase` tu nie pomoże.
    enum CodingKeys: String, CodingKey {
        case service, name, desc, state
        case unitState = "unit-state"
    }
}

private nonisolated struct ClusterResource: Decodable {
    let type: String?
    let vmid: Int?
    let name: String?
    let status: String?
    let cpu: Double?
    let maxcpu: Double?
    let mem: Int64?
    let maxmem: Int64?
    let disk: Int64?
    let maxdisk: Int64?
    let uptime: Int?
    let template: Int?
}

nonisolated struct TaskEntry: Decodable, Sendable {
    let upid: String?
    let type: String?
    let id: String?
    let status: String?
    let starttime: Int?
    /// Brak `endtime` = zadanie **jeszcze trwa**. Tak odróżnia się bieżący przebieg
    /// od zakończonego bez dodatkowego żądania o status.
    let endtime: Int?

    var trwa: Bool { endtime == nil }

    var poczatek: Date? { starttime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    var kres: Date? { endtime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// Nazwa rodzaju zadania po polsku. Proxmox podaje techniczne skróty (`vzdump`,
    /// `vzstart`), a one nic nie mówią komuś, kto patrzy na kafel, a nie w dokumentację.
    var opisRodzaju: String {
        switch type {
        case "vzdump":     return String(localized: "Kopia zapasowa")
        case "vzstart":    return String(localized: "Start kontenera")
        case "vzstop",
             "vzshutdown": return String(localized: "Zatrzymanie kontenera")
        case "vzreboot":   return String(localized: "Restart kontenera")
        case "vzcreate":   return String(localized: "Tworzenie kontenera")
        case "vzdestroy":  return String(localized: "Usuwanie kontenera")
        case "qmstart":    return String(localized: "Start maszyny")
        case "qmstop",
             "qmshutdown": return String(localized: "Zatrzymanie maszyny")
        case "imgcopy":    return String(localized: "Kopiowanie obrazu")
        case "download":   return String(localized: "Pobieranie")
        case "push_file":  return String(localized: "Wysyłka pliku")
        case "srvstart":   return String(localized: "Start usługi")
        case "srvstop":    return String(localized: "Zatrzymanie usługi")
        case "srvrestart": return String(localized: "Restart usługi")
        case "aptupdate":  return String(localized: "Odświeżenie listy pakietów")
        default:           return type ?? String(localized: "Zadanie")
        }
    }
}

/// Odpowiedź `/nodes/{n}/tasks/{upid}/status`.
nonisolated struct TaskStatus: Decodable, Sendable {
    /// `running` albo `stopped`.
    let status: String?
    /// Wypełnione dopiero po zakończeniu: `OK` albo treść błędu.
    let exitstatus: String?
}

private nonisolated struct TaskLogLine: Decodable {
    let n: Int?
    let t: String?
}

// MARK: - Delegat zaufania: przypięcie certyfikatu

/// Sprawdza tożsamość serwera, zanim poleci do niego token API.
///
/// Ta sama zasada co w wersji pod TrueNAS-a: certyfikat Proxmoksa jest **samopodpisany**,
/// więc zaufania systemowego nigdy nie przejdzie — dowodem tożsamości jest odcisk klucza,
/// zapamiętany przy pierwszym połączeniu (TOFU, jak `known_hosts` w SSH). Każdy kolejny
/// certyfikat jest z nim porównywany, a rozbieżność **przerywa połączenie**.
private final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let host: String
    private let lock = NSLock()
    private var recorded: Error?

    init(host: String) {
        self.host = host
        super.init()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let fingerprint = CertificatePin.fingerprint(of: trust) else {
            Log.certificate.error("Nie udało się policzyć odcisku klucza serwera \(self.host, privacy: .public)")
            record(ProxmoxClient.ClientError.certificateUnreadable)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        switch CertificatePin.lookup(host) {
        case .pinned(let expected):
            guard expected == fingerprint else {
                Log.certificate.fault("Odcisk certyfikatu \(self.host, privacy: .public) się zmienił — połączenie przerwane")
                record(ProxmoxClient.ClientError.certificateMismatch(expected: expected, received: fingerprint))
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        case .storeUnreadable:
            Log.certificate.fault("Plik przypięć certyfikatów nieczytelny — połączenie z \(self.host, privacy: .public) przerwane")
            record(ProxmoxClient.ClientError.pinStoreUnreadable(path: CertificatePin.unreadableStorePath))
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        case .unknown:
            CertificatePin.store(fingerprint, for: host)
            Log.certificate.notice("Zapamiętano certyfikat \(self.host, privacy: .public): \(CertificatePin.display(fingerprint), privacy: .public)")
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func record(_ error: Error) {
        lock.lock(); recorded = error; lock.unlock()
    }

    /// Odbiera zapamiętany powód odrzucenia (i czyści go). Wołane, gdy URLSession zwróci
    /// błąd bez treści — sam kod `cancelled` nie mówi użytkownikowi nic.
    func takeError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        let e = recorded
        recorded = nil
        return e
    }
}
