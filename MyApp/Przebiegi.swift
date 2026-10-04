import Foundation

// MARK: - Model

/// Jeden **przebieg**: mechanizm, który się uruchamia, chwilę pracuje i kończy.
///
/// Kilka źródeł, celowo w jednym typie — na kaflu i w pasku menu mają wyglądać jednakowo,
/// bo z punktu widzenia użytkownika to jedno pytanie: „czy coś się teraz kopiuje i czy
/// ostatnie kopiowanie się udało".
///
/// | Źródło | Skąd | Czym w praktyce jest |
/// |---|---|---|
/// | `.serwer` | `/nodes/{n}/tasks` | `vzdump` (02:30), kopia konfiguracji hosta (02:15), start/stop gościa |
/// | `.kuma` | baza Uptime Kumy przez SSH | monitory typu **push** — mechanizmy, które same się meldują |
/// | `.host` | `/etc/cron.d`, timery systemd, `/var/log` | zadania, które host naprawdę uruchamia (od 2026-08-23) |
nonisolated struct Przebieg: Identifiable, Sendable, Hashable {

    nonisolated enum Zrodlo: String, Codable, Sendable, Hashable {
        /// `mak` nie ma już żadnego źródła — zostaje, bo rejestr zdarzeń zapisuje to pole
        /// i starsze wpisy muszą się dalej wczytać.
        case serwer, mak, kuma, host

        var opis: String {
            switch self {
            case .serwer: return String(localized: "serwer")
            case .mak:    return String(localized: "ten Mac")
            case .kuma:   return String(localized: "Uptime Kuma")
            case .host:   return String(localized: "zadanie hosta")
            }
        }
    }

    /// Stan przebiegu.
    ///
    /// `cisza` to osobny stan, nie odmiana błędu: mechanizm miał się zameldować i nie
    /// zameldował. Nie wiemy, czy padł, czy nie wystartował — wiemy tylko, że go nie ma.
    /// Tak samo liczy to Uptime Kuma (monitor push gaśnie po przekroczeniu czasu).
    nonisolated enum Stan: String, Codable, Sendable, Hashable {
        case trwa, udany, bledny, cisza, nieznany

        var opis: String {
            switch self {
            case .trwa:     return String(localized: "trwa")
            case .udany:    return String(localized: "udany")
            case .bledny:   return String(localized: "błąd")
            case .cisza:    return String(localized: "brak sygnału")
            case .nieznany: return String(localized: "nieznany")
            }
        }

        /// Czy ten stan ma zapalić czerwoną kropkę na ikonie w pasku menu.
        var alarmujacy: Bool { self == .bledny || self == .cisza }
    }

    let id: String
    var nazwa: String
    var zrodlo: Zrodlo
    var stan: Stan
    /// Co się w tej chwili dzieje — „pakowanie archiwum", „pierwsza synchronizacja".
    var faza: String?
    /// Ile pozycji z ilu. Dla `vzdump` to liczba kontenerów, nie procent — patrz
    /// `PrzebiegiParsers.vzdumpPostep`.
    var zrobionych: Int?
    var wszystkich: Int?
    var start: Date?
    var koniec: Date?
    /// Ostatnia wiadomość mechanizmu, tak jak ją podał (np. „Kopia laptop OK w 6s").
    var opis: String?
    /// Po ilu sekundach trwający przebieg zaczyna być podejrzany. Nie kończy go i nie
    /// zmienia stanu — sam fakt, że coś chodzi długo, nie znaczy jeszcze, że padło.
    var limitSekund: Double?
    /// Bieżąca prędkość w bajtach na sekundę. Dla `vzdump` liczona z **przyrostu pliku
    /// archiwum** między turami odświeżania, bo log żywego tempa nie podaje.
    var predkosc: Double?
    /// Czy `predkosc` to pomiar bieżący, czy tempo ostatniej zakończonej fazy z logu.
    /// Różnica jest istotna: druga wartość potrafi być sprzed minuty i nie mówi nic
    /// o tym, czy przebieg **teraz** się rusza.
    var predkoscBiezaca: Bool = false
    /// Ile już zapisano — rozmiar rosnącego archiwum.
    var rozmiarBajtow: Int64?

    /// Ile trwa albo trwał — do wypisania obok nazwy.
    var czasTrwania: TimeInterval? {
        guard let start else { return nil }
        return (koniec ?? Date()).timeIntervalSince(start)
    }

    /// Chodzi dłużej, niż powinien. To jest ostrzeżenie, nie werdykt:
    /// odpowiedź na „włączył się i nie kończy", zanim serwer cokolwiek zgłosi.
    var przekroczylCzas: Bool {
        guard stan == .trwa, let limitSekund, let czasTrwania else { return false }
        return czasTrwania > limitSekund
    }

    var postepOpis: String? {
        guard let zrobionych, let wszystkich, wszystkich > 0 else { return nil }
        return String(localized: "\(zrobionych) z \(wszystkich)")
    }

    /// Ułamek do paska postępu, `0…1`.
    ///
    /// 🔴 Liczony w **pozycjach**, nie w bajtach — bo tylko to serwer podaje uczciwie.
    /// Trwająca pozycja liczy się jako **pół**: bez tego pasek stoi w miejscu przez całą
    /// minutę pakowania kontenera i wygląda na zawieszony, a po skończeniu przeskakuje
    /// o całe pole. Połowa nie udaje precyzji — mówi „ta pozycja jest w robocie".
    var postepUlamek: Double? {
        guard let zrobionych, let wszystkich, wszystkich > 0 else { return nil }
        let wtoku = (stan == .trwa && zrobionych < wszystkich) ? 0.5 : 0
        return min(1, (Double(zrobionych) + wtoku) / Double(wszystkich))
    }
}

// MARK: - Parsery

/// Czysto tekstowe parsowanie — bez sieci, bez stanu, testowalne bez serwera.
/// Ta sama zasada co w `StatsParsers`: surowe wyjście przychodzi na Maca i jest
/// rozbierane tutaj, żeby regresja wychodziła z testu, a nie z patrzenia na kafel.
nonisolated enum PrzebiegiParsers {

    // MARK: Postęp zadania vzdump

    nonisolated struct VzdumpPostep: Sendable, Equatable {
        var wszystkich: Int = 0
        var zrobionych: Int = 0
        /// Numer gościa, którego kopia właśnie się robi (`nil`, gdy między kontenerami).
        var biezacy: Int?
        var faza: String?
        /// Zadanie zapisało w logu błąd — widać to przed jego zakończeniem.
        var bylBlad: Bool = false
        /// Plik archiwum, który właśnie rośnie. Stąd bierze się **żywa** prędkość:
        /// log jej nie podaje, ale przyrost tego pliku owszem.
        var sciezkaArchiwum: String?
        /// Prędkość ostatniej **zakończonej** fazy, w bajtach na sekundę.
        /// To nie jest pomiar bieżący — patrz `Przebieg.predkosc`.
        var predkoscZLogu: Double?
    }

    /// Postęp zadania `vzdump` wyciągnięty z **logu zadania**.
    ///
    /// 🔴 **Procentów tu nie ma i nie będzie.** Zmierzone na serwerze testowym 2026-08-20: log
    /// `vzdump` dla kontenerów LXC zawiera wyłącznie nazwy faz („first sync finished",
    /// „creating vzdump archive", „Finished Backup of VM 104 (00:00:15)"), ani jednej
    /// linii z procentem. Procenty wypisuje `vzdump` maszyn **QEMU**, a te (200, 201)
    /// są z nocnego zadania celowo wyłączone. Dlatego postęp liczymy w **kontenerach**:
    /// ilu skończonych z ilu zaplanowanych. To jest liczba, którą serwer naprawdę podaje.
    ///
    /// Zaplanowane bierzemy z pierwszej linii zadania — `starting new backup job: vzdump
    /// 100 101 103 …` — a nie z konfiguracji zadania, bo ta może się zmienić w trakcie
    /// nocy i wtedy licznik pokazywałby „9 z 8".
    static func vzdumpPostep(log: [String]) -> VzdumpPostep {
        var out = VzdumpPostep()

        for linia in log {
            if out.wszystkich == 0, let zakres = linia.range(of: "starting new backup job: vzdump ") {
                // Same numery gości, do pierwszego przełącznika. `--all` i `--pool`
                // nie podają listy — wtedy zostaje zero i licznik się nie pokaże.
                let ogon = linia[zakres.upperBound...]
                var ile = 0
                for token in ogon.split(separator: " ") {
                    if token.hasPrefix("-") { break }
                    if Int(token) != nil { ile += 1 }
                }
                out.wszystkich = ile
            }
            if let id = numerGoscia(linia, po: "Starting Backup of VM ") {
                out.biezacy = id
                out.faza = "start"
            }
            if numerGoscia(linia, po: "Finished Backup of VM ") != nil {
                out.zrobionych += 1
                out.biezacy = nil
                out.faza = nil
                // 🔴 Archiwum skończonego kontenera **przestaje rosnąć**. Zostawienie tu
                // ścieżki znaczyłoby, że w fazie synchronizacji następnego kontenera
                // mierzymy nieruchomy plik i meldujemy „0 B/s" jako pomiar bieżący —
                // czyli „stoi" o przebiegu, który właśnie ostro pracuje.
                out.sciezkaArchiwum = nil
            }
            if let f = faza(linia) { out.faza = f }
            if let sciezka = sciezkaArchiwum(linia) { out.sciezkaArchiwum = sciezka }
            if let v = predkosc(linia) { out.predkoscZLogu = v }
            if linia.hasPrefix("ERROR:") || linia.contains("ERROR: Backup of VM") {
                out.bylBlad = true
            }
        }
        return out
    }

    /// `INFO: creating vzdump archive '/mnt/backup/dump/vzdump-lxc-105-….tar.zst'` → ścieżka.
    ///
    /// Ścieżka jest potrzebna, bo **żywej prędkości w logu nie ma**. Zmierzone na
    /// biegnącym zadaniu 2026-08-20: przy pakowaniu archiwum log milczy aż do końca
    /// fazy. Rosnący plik jest jedynym źródłem bieżącego tempa.
    private static func sciezkaArchiwum(_ linia: String) -> String? {
        guard linia.contains("creating vzdump archive"),
              let od = linia.firstIndex(of: "\'") else { return nil }
        let reszta = linia[linia.index(after: od)...]
        guard let do_ = reszta.firstIndex(of: "\'") else { return nil }
        let sciezka = String(reszta[..<do_])
        return sciezka.isEmpty ? nil : sciezka
    }

    /// Prędkość **zakończonej** fazy, w bajtach na sekundę. Dwa kształty w logu:
    ///
    /// - `INFO: first sync finished - transferred 930.28M bytes in 7s`
    /// - `INFO: Total bytes written: 862330880 (823MiB, 121MiB/s)`
    ///
    /// Pierwszy trzeba przeliczyć, drugi podaje tempo wprost. Oba zmierzone na
    /// prawdziwych zadaniach z serwera testowego.
    private static func predkosc(_ linia: String) -> Double? {
        if let zakres = linia.range(of: ", "), linia.contains("Total bytes written:"),
           let koniec = linia.range(of: "/s)") {
            let tekst = String(linia[zakres.upperBound..<koniec.lowerBound])
            return przelicz(tekst.replacingOccurrences(of: "/s", with: ""))
        }
        if linia.contains("sync finished - transferred") {
            guard let po = linia.range(of: "transferred ") else { return nil }
            let reszta = linia[po.upperBound...]
            let czesci = reszta.split(separator: " ")
            guard czesci.count >= 4,
                  let bajty = przelicz(String(czesci[0])),
                  let sekundy = Double(czesci[3].replacingOccurrences(of: "s", with: "")),
                  sekundy > 0 else { return nil }
            return bajty / sekundy
        }
        return nil
    }

    /// `930.28M`, `823MiB`, `121MiB` → bajty. Proxmox miesza zapisy w jednym logu.
    private static func przelicz(_ tekst: String) -> Double? {
        let czysty = tekst.trimmingCharacters(in: .whitespaces)
        // Kolejność ma znaczenie: „MiB" musi trafić przed „M", inaczej `hasSuffix("M")`
        // nigdy nie zostanie sprawdzone dla właściwego przyrostka, a `Double("823Mi")`
        // zwróci `nil` i prędkość po cichu zniknie.
        let mnozniki: [(String, Double)] = [
            ("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824),
            ("MiB", 1_048_576), ("KiB", 1024),
            ("T", 1_099_511_627_776), ("G", 1_073_741_824),
            ("M", 1_048_576), ("K", 1024)
        ]
        for (jednostka, mnoznik) in mnozniki where czysty.hasSuffix(jednostka) {
            let liczba = czysty.dropLast(jednostka.count)
            guard let v = Double(liczba) else { return nil }
            return v * mnoznik
        }
        return Double(czysty)
    }

    /// `INFO: Starting Backup of VM 104 (lxc)` → `104`.
    private static func numerGoscia(_ linia: String, po wzorzec: String) -> Int? {
        guard let zakres = linia.range(of: wzorzec) else { return nil }
        let cyfry = linia[zakres.upperBound...].prefix { $0.isNumber }
        return Int(cyfry)
    }

    /// Nazwy faz z logu `vzdump` po polsku. Angielskie oryginały zostają w kodzie
    /// jako wzorce — to one przychodzą z serwera i nie wolno ich tłumaczyć „w locie".
    private static func faza(_ linia: String) -> String? {
        switch true {
        case linia.contains("starting first sync"):     return String(localized: "pierwsza synchronizacja")
        case linia.contains("first sync finished"):     return String(localized: "pierwsza synchronizacja gotowa")
        case linia.contains("suspending guest"):        return String(localized: "wstrzymywanie kontenera")
        case linia.contains("starting final sync"):     return String(localized: "domykanie kopii")
        case linia.contains("resuming guest"):          return String(localized: "wznawianie kontenera")
        case linia.contains("creating vzdump archive"): return String(localized: "pakowanie archiwum")
        case linia.contains("prune older backups"):     return String(localized: "usuwanie starych kopii")
        default: return nil
        }
    }

    // MARK: Monitory Uptime Kumy

    nonisolated struct KumaMonitor: Sendable, Hashable {
        var id: Int
        var nazwa: String
        /// `push`, `http`, `ping`, `port`… Push to mechanizm, który sam się melduje —
        /// i tylko taki jest „przebiegiem". Reszta to czujki stanu, nie zadania.
        var typ: String
        var aktywny: Bool
        /// Kod Kumy: `0` padł, `1` działa, `2` czeka, `3` przerwa techniczna, `-1` brak sygnału.
        var status: Int
        var czas: Date?
        var opis: String

        var jestPrzebiegiem: Bool { typ == "push" }

        var stan: Przebieg.Stan {
            guard aktywny else { return .nieznany }
            switch status {
            case 1:  return .udany
            case 0:  return .cisza      // push bez sygnału w oknie czasu — cisza, nie błąd
            case 2:  return .nieznany
            case 3:  return .nieznany
            default: return .nieznany
            }
        }
    }

    /// Czy wiadomość monitora to **sam spis zajętości** punktów montowania.
    ///
    /// > [!warning] Po co odsiew zamiast skasowania wszystkich podpisów
    /// > Zgłoszenie [U] z 2026-08-23 dotyczyło jednej linijki — tej z monitora
    /// > „Dyski pve — miejsce i SMART":
    /// > `/mnt/zasoby 78%,/mnt/wspolny 2% /mnt/multimedia 11%,/mnt/backup 9%`.
    /// > To jest treść powiadomienia push, a nie dane, i od 2026-08-23 te same wartości
    /// > rysuje kafel „Miejsce" z `df`.
    /// >
    /// > Ale skasowanie **każdego** podpisu wyrzuciłoby też informacje, które są prawdziwe.
    /// > Zmierzone tego samego dnia w bazie Kumy: monitor „Kopia Programy na HDD" melduje
    /// > `Sync na talerz: migawka 2026-08-23, 8.2G w 5s, migawek 2` — i to ma zostać.
    /// > Stąd odsiew po **kształcie** wiadomości, nie po stanie monitora.
    ///
    /// Spisem jest wiadomość, w której **każdy** człon to para „ścieżka + procent".
    /// Wystarczy jedno słowo spoza tego wzorca, żeby wiadomość została uznana za treść.
    static func opisJestSpisemMiejsca(_ opis: String) -> Bool {
        let fragmenty = opis.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Jeden człon to za mało na spis — „No heartbeat in the time window" też jest jeden.
        guard fragmenty.count >= 2 else { return false }

        for fragment in fragmenty {
            let slowa = fragment.split(separator: " ", omittingEmptySubsequences: true)
            // Pary, więc parzysta liczba słów. `paste -sd', '` potrafi skleić dwie pary
            // w jeden człon, gdy `df` nie dołoży przecinka — stąd pętla, nie `count == 2`.
            guard slowa.count >= 2, slowa.count % 2 == 0 else { return false }
            for i in stride(from: 0, to: slowa.count, by: 2) {
                guard slowa[i].hasPrefix("/") else { return false }
                let procent = slowa[i + 1]
                guard procent.hasSuffix("%"), Int(procent.dropLast()) != nil else { return false }
            }
        }
        return true
    }

    /// Wiersze `id|nazwa|typ|aktywny|status|czas|wiadomość` z bazy Uptime Kumy.
    ///
    /// 🔴 **Czas w bazie Kumy jest w UTC**, mimo że wygląda jak lokalny. Zmierzone
    /// 2026-08-20: sygnał kopii z laptopa ma w bazie `2026-08-19 21:38:20`, a ten sam
    /// przebieg w logu na Macu — `23:38:20`. Bez wymuszenia strefy kafel pokazywałby
    /// każdą kopię jako zrobioną dwie godziny wcześniej, czyli wiarygodnie i błędnie.
    static func kumaMonitory(_ raw: String) -> [KumaMonitor] {
        guard !raw.contains("@@BRAK-BAZY") else { return [] }
        var out: [KumaMonitor] = []
        for linia in raw.split(separator: "\n") {
            let p = linia.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false)
            guard p.count >= 6, let id = Int(p[0]) else { continue }
            out.append(KumaMonitor(
                id: id,
                nazwa: String(p[1]),
                typ: String(p[2]),
                aktywny: p[3] == "1",
                status: Int(p[4]) ?? -1,
                czas: dataUTC(String(p[5])),
                opis: p.count > 6 ? String(p[6]).trimmingCharacters(in: .whitespaces) : ""
            ))
        }
        return out
    }

    private static let kumaFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func dataUTC(_ s: String) -> Date? {
        let czysty = s.split(separator: ".").first.map(String.init) ?? s   // ucina ułamki sekund
        return kumaFormat.date(from: czysty.replacingOccurrences(of: "T", with: " "))
    }

    // MARK: Mechanizmy hosta — cron, timery, dzienniki

    /// Jeden mechanizm, który host naprawdę uruchamia.
    ///
    /// Wszystko tu jest **znalezione**, nie wpisane: nazwa z komentarza nad zadaniem
    /// albo z opisu jednostki systemd, harmonogram z wyrażenia cron, dziennik z linii
    /// `LOG=` w skrypcie. Mechanizm zdjęty z crona nie ma tu jak powstać.
    nonisolated struct MechanizmHosta: Identifiable, Sendable, Hashable {
        var skrypt: String
        var nazwa: String
        /// Harmonogram po ludzku („codziennie 04:45"), a gdy się nie da — surowe
        /// wyrażenie. Zgadywanie tu byłoby gorsze niż pokazanie tego, co stoi w cronie.
        var harmonogram: String
        /// Skąd zadanie pochodzi: `cron: kopia-zdjec`, `timer: pomiar-ruchu.service`.
        var skad: String
        /// Mechanizm, który tyka bez przerwy, a nie odpala się o wyznaczonej porze.
        ///
        /// 🔴 To rozróżnienie stoi już w tym pliku od 2026-08-20 przy monitorach Kumy:
        /// *„przebiegami są tylko monitory push, reszta to czujki stanu — nie zadania"*.
        /// Ta sama zasada dotyczy hosta: `alarm-dyskow.sh` co 10 minut i
        /// `pomiar-ruchu.sh` co 10 sekund **nie są przebiegami**, tylko czujkami.
        /// Wpuszczenie ich na listę zamieniłoby kafel w ścianę wierszy, które nigdy
        /// się nie kończą — a [U] pyta tam o jedno: czy ostatnia kopia przeszła.
        var czujka: Bool
        /// Ostatni wpis z dziennika mechanizmu. `nil`, gdy mechanizm dziennika nie prowadzi.
        var ostatni: WpisKopii?

        var id: String { skrypt }
    }

    /// Czyta wyjście `ServerCommands.mechanizmyHosta()`.
    static func mechanizmyHosta(_ raw: String) -> [MechanizmHosta] {
        let sekcje = StatsParsers.splitSections(raw)
        var znalezione: [(skrypt: String, nazwa: String, harmonogram: String,
                          skad: String, czujka: Bool)] = []

        // 1. Zadania cron. Nazwą jest **pierwszy komentarz z bloku stojącego bezpośrednio
        //    nad zadaniem**. Dzięki temu `kopia-zdjec` daje dwa czytelne wiersze
        //    („Kopia 1 …", „Kopia 2 …"), a `sprzatanie-udzialow` bierze zdanie
        //    opisujące, co robi, a nie drugą linijkę o tym, kiedy powstał.
        //
        //    Blok kończy się na **dowolnej** innej linii — dlatego komentarz z nagłówka
        //    pliku, oddzielony od zadania przez `SHELL=` i `PATH=`, nie jest jego opisem
        //    i wtedy nazwa bierze się z nazwy skryptu.
        var blokKomentarza: [String: String] = [:]      // plik → pierwszy komentarz bloku
        for linia in (sekcje["CRON"] ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            let czesci = linia.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard czesci.count == 2 else { continue }
            let plik = String(czesci[0])
            let tresc = String(czesci[1]).trimmingCharacters(in: .whitespaces)

            if tresc.hasPrefix("#") {
                // 🔴 Wyłączone zadanie zaczyna się od `#` i **ma zostać wyłączone**.
                // To jest dokładnie ten przypadek: `#30 4 * * * root …kopia-dokumentow-na-hdd.sh`
                // wisiał na liście po wygaszeniu 2026-08-22 i to była połowa zgłoszenia [U].
                if blokKomentarza[plik] == nil { blokKomentarza[plik] = opisZKomentarza(tresc) }
                continue
            }

            let pola = tresc.split(separator: " ", omittingEmptySubsequences: true)
            guard pola.count >= 7, pola[5] == "root",
                  pola[6].hasPrefix("/usr/local/bin/") else {
                blokKomentarza[plik] = nil      // `SHELL=`, `PATH=`, pusta linia — blok się kończy
                continue
            }
            let skrypt = String(pola[6])
            let wyrazenie = pola[0..<5].joined(separator: " ")
            znalezione.append((skrypt: skrypt,
                               nazwa: blokKomentarza[plik] ?? nazwaZeSkryptu(skrypt),
                               harmonogram: harmonogramPoLudzku(wyrazenie),
                               skad: "cron: \(plik)",
                               czujka: czyCzujka(wyrazenie)))
            blokKomentarza[plik] = nil
        }

        // 2. Timery systemd — opis jednostki jest gotową nazwą, nie trzeba go składać.
        for linia in (sekcje["TIMERY"] ?? "").split(separator: "\n") {
            let pola = linia.split(separator: "\t", omittingEmptySubsequences: false)
            guard pola.count >= 3 else { continue }
            let skrypt = String(pola[2]).trimmingCharacters(in: .whitespaces)
            guard !skrypt.isEmpty else { continue }
            let opis = String(pola[1]).trimmingCharacters(in: .whitespaces)
            // Czwarte pole to `TimersCalendar`. Puste znaczy timer monotoniczny
            // (`OnUnitActiveUSec`), czyli tykanie w kółko — czujka, nie przebieg.
            let kalendarz = pola.count >= 4
                ? String(pola[3]).trimmingCharacters(in: .whitespaces) : ""
            znalezione.append((skrypt: skrypt,
                               nazwa: opis.isEmpty ? nazwaZeSkryptu(skrypt) : opis,
                               harmonogram: kalendarz.isEmpty ? "timer systemd" : kalendarzPoLudzku(kalendarz),
                               skad: "timer: \(pola[0])",
                               czujka: kalendarz.isEmpty))
        }

        // 3. Dzienniki — każdy blok zaczyna się od `### <skrypt> <dziennik>`.
        var dzienniki: [String: WpisKopii] = [:]
        var biezacySkrypt: String?
        var bufor: [String] = []
        func domknij() {
            if let s = biezacySkrypt, let wpis = ostatniaKopia(log: bufor.joined(separator: "\n")) {
                dzienniki[s] = wpis
            }
            bufor = []
        }
        for linia in (sekcje["LOGI"] ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            if linia.hasPrefix("### ") {
                domknij()
                let pola = linia.dropFirst(4).split(separator: " ", omittingEmptySubsequences: true)
                biezacySkrypt = pola.first.map(String.init)
            } else {
                bufor.append(String(linia))
            }
        }
        domknij()

        // Ten sam skrypt potrafi stać w cronie i w timerze — bierzemy pierwsze wystąpienie,
        // żeby nie zrobić z jednego mechanizmu dwóch wierszy.
        var widziane: Set<String> = []
        return znalezione.compactMap { m in
            guard widziane.insert(m.skrypt).inserted else { return nil }
            return MechanizmHosta(skrypt: m.skrypt, nazwa: m.nazwa,
                                  harmonogram: m.harmonogram, skad: m.skad,
                                  czujka: m.czujka,
                                  ostatni: dzienniki[m.skrypt])
        }
    }

    /// Czy wyrażenie cron opisuje mechanizm tykający w kółko, a nie zadanie o porze.
    ///
    /// Krokowa minuta (`*/10 * * * *`) albo gwiazdka w minucie znaczy „co chwilę".
    /// Zadanie z konkretną godziną i minutą (`45 4 * * *`) odpala się raz na dobę
    /// i to jest przebieg.
    static func czyCzujka(_ wyrazenie: String) -> Bool {
        let p = wyrazenie.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard p.count == 5 else { return false }
        if p[0] == "*" || p[0].contains("/") { return true }
        // Godzina „co N" przy stałej minucie to nadal zadanie o porze, tyle że częściej —
        // np. `0 */6 * * *`. Czujką robi się dopiero wtedy, gdy chodzi częściej niż raz
        // na godzinę, czyli gdy krok siedzi w minutach.
        return false
    }

    /// `*-*-* 00:00:00` → `codziennie 00:00`. Wszystko inne wraca surowe.
    static func kalendarzPoLudzku(_ spec: String) -> String {
        // systemd potrafi zwrócić kilka wpisów sklejonych w nawiasach klamrowych —
        // bierzemy pierwszy `OnCalendar=…` i zostawiamy resztę w spokoju.
        guard let zakres = spec.range(of: "OnCalendar=") else { return spec }
        var tekst = String(spec[zakres.upperBound...])
        if let koniec = tekst.range(of: " ;") { tekst = String(tekst[..<koniec.lowerBound]) }
        tekst = tekst.trimmingCharacters(in: .whitespaces)
        let pola = tekst.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if pola.count == 2, pola[0] == "*-*-*" {
            let hm = pola[1].split(separator: ":").prefix(2).compactMap { Int($0) }
            if hm.count == 2 { return String(format: String(localized: "codziennie %02d:%02d"), hm[0], hm[1]) }
        }
        return tekst
    }

    /// Nazwa z komentarza: pierwsze zdanie, bez części po strzałce.
    ///
    /// `# Alarm dyskow pve -> powiadomienie. Opis w dokumentacji.`
    /// daje `Alarm dyskow pve`. Cięcie po `". "`, a nie po samej kropce — inaczej
    /// `(.Trashes)` w komentarzu `sprzatanie-udzialow` urywałby zdanie w połowie.
    static func opisZKomentarza(_ komentarz: String) -> String {
        var tekst = komentarz.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        if let zakres = tekst.range(of: ". ") { tekst = String(tekst[..<zakres.lowerBound]) }
        if let zakres = tekst.range(of: " -> ") { tekst = String(tekst[..<zakres.lowerBound]) }
        if tekst.hasSuffix(".") { tekst.removeLast() }
        return tekst.trimmingCharacters(in: .whitespaces)
    }

    /// Zapasowa nazwa, gdy nad zadaniem nie ma komentarza: `kopia-zdjec-na-nas.sh`
    /// → `Kopia zdjec na nas`. Wprost z nazwy pliku, bez słownika w kodzie.
    static func nazwaZeSkryptu(_ sciezka: String) -> String {
        var nazwa = sciezka.split(separator: "/").last.map(String.init) ?? sciezka
        if nazwa.hasSuffix(".sh") { nazwa.removeLast(3) }
        nazwa = nazwa.replacingOccurrences(of: "-", with: " ")
                     .replacingOccurrences(of: "_", with: " ")
        return nazwa.prefix(1).uppercased() + nazwa.dropFirst()
    }

    /// Wyrażenie cron po ludzku. Rozpoznajemy dwa najczęstsze kształty; wszystko inne
    /// wraca **surowe**, bo błędnie przetłumaczony harmonogram jest gorszy niż gwiazdki.
    static func harmonogramPoLudzku(_ wyrazenie: String) -> String {
        let p = wyrazenie.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard p.count == 5 else { return wyrazenie }

        // `*/10 * * * *` → „co 10 minut"
        if p[0].hasPrefix("*/"), let co = Int(p[0].dropFirst(2)),
           p[1] == "*", p[2] == "*", p[3] == "*", p[4] == "*" {
            // Odmiana po liczbie (minutę / minuty / minut; minute / minutes) siedzi w katalogu
            // tekstów jako warianty liczby mnogiej — od 2026-10-04, tor „mNas po angielsku”.
            return String(localized: "co \(co) minut")
        }
        // `45 4 * * *` → „codziennie 04:45"
        if let minuta = Int(p[0]), let godzina = Int(p[1]),
           p[2] == "*", p[3] == "*", p[4] == "*" {
            return String(format: String(localized: "codziennie %02d:%02d"), godzina, minuta)
        }
        return wyrazenie
    }

    // MARK: Log nocnej kopii na Macu

    nonisolated struct WpisKopii: Sendable, Hashable {
        var czas: Date
        var stan: Przebieg.Stan
        var opis: String
    }

    static let logFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f      // czas lokalny — skrypt pisze `date '+%Y-%m-%d %H:%M:%S'`
    }()

    /// Ostatni **zakończony** przebieg z dziennika skryptu kopii.
    ///
    /// Format linii: `2026-08-19 23:38:20  OK: kopia laptop gotowa w 6s`. Między znacznikiem czasu
    /// a treścią stoją **dwie spacje**, ale nie opieramy się na tym — bierzemy pierwsze
    /// 19 znaków, bo tyle ma znacznik.
    ///
    /// Do logu trafia też wyjście samego `rsync` (skrypt przekierowuje tam jego stdout),
    /// więc linie bez znacznika czasu na początku są pomijane — to nie są wpisy stanu.
    static func ostatniaKopia(log: String) -> WpisKopii? {
        for linia in log.split(separator: "\n").reversed() {
            guard linia.count > 21 else { continue }
            let znacznik = String(linia.prefix(19))
            guard let czas = logFormat.date(from: znacznik) else { continue }
            let tresc = linia.dropFirst(19).trimmingCharacters(in: .whitespaces)
            let stan: Przebieg.Stan
            if tresc.hasPrefix("OK:") { stan = .udany }
            else if tresc.hasPrefix("BLAD:") { stan = .bledny }
            else if tresc.hasPrefix("UWAGA:") { stan = .udany }   // kopia się udała, nie doszedł tylko sygnał
            else { continue }
            return WpisKopii(czas: czas, stan: stan, opis: tresc)
        }
        return nil
    }
}

// MARK: - Historia przebiegów (okno kafla „Przebiegi”, od 1.2.13)

/// Jeden miniony przebieg w historii. Kafel pokazuje stan „teraz”, okno — listę wstecz.
nonisolated struct WpisHistoriiPrzebiegu: Identifiable, Sendable, Hashable {
    var id: String
    var mechanizm: String
    var start: Date
    var koniec: Date?
    var stan: Przebieg.Stan
    var opis: String?
    /// Tylko dla zadań Proxmoksa — po kliknięciu dociągamy log i `SzczegolyVzdump`.
    var upid: String?
    var czasTrwania: TimeInterval? { koniec.map { $0.timeIntervalSince(start) } }
}

/// Co da się wyczytać z logu zadania `vzdump`: dokąd szła kopia i ile trwał każdy gość.
/// Rozmiar jest tylko przy magazynie katalogowym (`archive file size`) — PBS kopiuje
/// przyrostowo i całkowitego rozmiaru w logu nie podaje.
nonisolated struct SzczegolyVzdump: Sendable, Hashable {
    struct Gosc: Sendable, Hashable { var vmid: Int; var czas: String?; var rozmiar: String? }
    var magazyn: String?
    var goscie: [Gosc]
}

extension PrzebiegiParsers {
    /// Lista zadań `vzdump` z `/nodes/{n}/tasks` → historia. Bez `endtime` = trwa.
    static func historiaZadan(_ z: [TaskEntry]) -> [WpisHistoriiPrzebiegu] {
        z.compactMap { t -> WpisHistoriiPrzebiegu? in
            guard let start = t.poczatek else { return nil }
            let stan: Przebieg.Stan = t.trwa ? .trwa : (t.status == "OK" ? .udany : .bledny)
            return WpisHistoriiPrzebiegu(id: t.upid ?? "zadanie-\(t.starttime ?? 0)", mechanizm: String(localized: "Kopia kontenerów"),
                                         start: start, koniec: t.kres, stan: stan,
                                         opis: t.trwa ? nil : t.status, upid: t.upid)
        }
        .sorted { $0.start > $1.start }
    }

    /// Każdy wpis `OK:` / `UWAGA:` / `BLAD:` z dziennika skryptu hosta to jeden przebieg.
    /// Format linii jak w `ostatniaKopia`; wyjście `rsync` i `INFO:` pomijamy.
    static func historiaLogu(_ log: String, mechanizm: String) -> [WpisHistoriiPrzebiegu] {
        log.split(separator: "\n").enumerated().compactMap { (nr, linia) -> WpisHistoriiPrzebiegu? in
            guard linia.count > 21, let czas = logFormat.date(from: String(linia.prefix(19))) else { return nil }
            let tresc = linia.dropFirst(19).trimmingCharacters(in: .whitespaces)
            let stan: Przebieg.Stan
            if tresc.hasPrefix("OK:") || tresc.hasPrefix("UWAGA:") { stan = .udany }
            else if tresc.hasPrefix("BLAD:") { stan = .bledny }
            else { return nil }
            return WpisHistoriiPrzebiegu(id: "\(mechanizm)#\(nr)", mechanizm: mechanizm,
                                         start: czas, koniec: czas, stan: stan, opis: tresc, upid: nil)
        }
        .sorted { $0.start > $1.start }
    }

    static func szczegolyVzdump(_ log: [String]) -> SzczegolyVzdump {
        var magazyn: String?
        var goscie: [SzczegolyVzdump.Gosc] = []
        var biezacy: Int?
        var rozmiar: String?
        for l in log {
            if l.contains("starting new backup job"), let r = l.range(of: "--storage ") {
                magazyn = l[r.upperBound...].split(separator: " ").first.map(String.init)
            } else if let r = l.range(of: "Starting Backup of VM ") {
                biezacy = Int(l[r.upperBound...].split(separator: " ").first ?? "")
                rozmiar = nil
            } else if let r = l.range(of: "archive file size: ") {
                rozmiar = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = l.range(of: "Finished Backup of VM "), let vmid = biezacy {
                let czas = l[r.upperBound...].split(separator: "(").last.map { String($0.dropLast()) }
                goscie.append(.init(vmid: vmid, czas: czas, rozmiar: rozmiar))
                biezacy = nil
            }
        }
        return SzczegolyVzdump(magazyn: magazyn, goscie: goscie)
    }
}

