import Foundation

/// Miejsce na dyskach — nazwy i zajętość **liczone z serwera**, nie przepisane z komunikatu.
///
/// > [!danger] Po co to powstało
/// > Zgłoszenie [U] z 2026-08-23. mNas pokazywał w przebiegach gotowe zdanie:
/// > `/mnt/zasoby 78%,/mnt/wspolny 2% / mnt/multimedia 11%,/mnt/backup 9%` — czyli
/// > **treść powiadomienia push**, sklejaną na hoście przez `/usr/local/bin/alarm-dyskow.sh`
/// > (`df -h --output=target,pcent … | paste -sd', '`). Stąd surowe ścieżki zamiast nazw,
/// > brak gigabajtów, łamanie w środku ścieżki i zero informacji, który nośnik zapalił alarm.
/// >
/// > Diagnoza [U] była trafna: *„wygląda tak jak byś wpisywał te dane do programu
/// > a nie pobierały informacji prosto z proxmoxa"*.
///
/// Dlatego **nazwy też są mierzone**, nie wpisane w kod. Tabela `/mnt/zasoby` → „Serwer"
/// wpisana na sztywno zestarzałaby się przy pierwszej zmianie na serwerze — dokładnie tak,
/// jak zestarzała się lista przebiegów. Nazwa udziału Samby wychodzi z `smb.conf`
/// w kontenerze, nazwa magazynu z `/etc/pve/storage.cfg`.
///
/// 🔴 Ta sama lekcja co przy `Problem-narzedzia-nazywane-po-porcie-podszywaly-sie`:
/// rozpoznanie zamiast twardej wartości.

// MARK: - Nazwa punktu montowania

nonisolated struct NazwaMontowania: Sendable, Hashable {

    /// Skąd wzięła się nazwa. Rozróżnienie ma znaczenie w interfejsie: udział widać
    /// w Finderze, magazyn tylko w panelu Proxmoksa, a katalog nigdzie.
    enum Rodzaj: String, Sendable, Hashable {
        /// Udział Samby — nazwa sekcji z `smb.conf` w kontenerze.
        case udzial
        /// Magazyn Proxmoksa — nazwa z `/etc/pve/storage.cfg`.
        case magazyn
        /// Zwykły katalog, którego nikt nie nazwał — zostaje ostatni człon ścieżki.
        case katalog

        var etykieta: String {
            switch self {
            case .udzial:  return String(localized: "udział sieciowy")
            case .magazyn: return String(localized: "magazyn Proxmoksa")
            case .katalog: return String(localized: "katalog na hoście")
            }
        }
    }

    var nazwa: String
    var rodzaj: Rodzaj
}

// MARK: - Jeden wiersz miejsca

nonisolated struct Udzial: Identifiable, Sendable, Hashable {
    /// Punkt montowania na hoście — jednocześnie tożsamość wiersza.
    var sciezka: String
    var nazwa: String
    var rodzaj: NazwaMontowania.Rodzaj
    var zajete: Int64
    var calosc: Int64

    var id: String { sciezka }

    /// Procent zajętości — **ta sama liczba, którą podaje `df` na serwerze**.
    ///
    /// Dwie rzeczy są tu celowe i obie zostały zmierzone 2026-08-23 na siedmiu punktach
    /// montowania serwera testowego:
    /// - mianownikiem jest **zajęte + dostępne**, nie rozmiar systemu plików (ext4
    ///   rezerwuje kilka procent dla roota) — tak samo liczy `StatsParsers.diskUsage`;
    /// - zaokrąglenie idzie **w górę**, bo tak liczy `df`. Przy zwykłym zaokrągleniu
    ///   `/mnt/zasoby` pokazywałby 77% wobec 78% w `df`, a `/mnt/multimedia` 10% wobec 11%.
    ///   [U] porównuje te liczby z serwerem, więc rozjazd o jeden wygląda jak błąd.
    var procent: Int {
        guard calosc > 0, zajete > 0 else { return 0 }
        return Int((Double(zajete) / Double(calosc) * 100).rounded(.up))
    }

    var wolne: Int64 { max(0, calosc - zajete) }

    var przekroczylProg: Bool { procent >= Miejsce.progZajetosci }
}

// MARK: - Zbieranie

nonisolated enum Miejsce {

    /// Zajętość, powyżej której wiersz robi się czerwony.
    ///
    /// **Ten sam próg co czujka na serwerze** (`PROG_PROCENT=90` w `alarm-dyskow.sh`).
    /// Rozjazd znaczyłby, że ntfy dzwoni, a kafel pokazuje spokojną zieleń.
    static let progZajetosci = 90

    /// Pokazujemy to, co siedzi pod `/mnt` — czyli dyski danych. Katalogi systemowe
    /// (`/`, `/boot/efi`) mają własny kafel „Pamięć masowa" i tu byłyby szumem.
    static let przedrostek = "/mnt/"

    // MARK: Nazwy

    /// Czyta wyjście `ServerCommands.nazwyMontowan()` i zwraca mapę
    /// „ścieżka na hoście → nazwa".
    ///
    /// Kolejność źródeł jest **decyzją [U] z 2026-08-23**: „nazwy udziałów Samby".
    /// Gdy ta sama ścieżka jest i udziałem, i magazynem — wygrywa udział, bo to ta nazwa,
    /// którą [U] widzi w Finderze.
    static func nazwy(_ raw: String) -> [String: NazwaMontowania] {
        let sekcje = StatsParsers.splitSections(raw)
        var out: [String: NazwaMontowania] = [:]

        // 1. Magazyny Proxmoksa: `dir: nazwa` + wcięta linia `path /ścieżka`.
        //    Typy inne niż `dir` (lvmthin, zfspool) nie mają punktu montowania.
        var biezacyMagazyn: String?
        for linia in (sekcje["STORAGE"] ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            let tekst = String(linia)
            if tekst.hasPrefix("dir: ") {
                biezacyMagazyn = String(tekst.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if tekst.first == " " || tekst.first == "\t" {
                let pola = tekst.split(separator: " ", omittingEmptySubsequences: true)
                    .flatMap { $0.split(separator: "\t", omittingEmptySubsequences: true) }
                if pola.count >= 2, pola[0] == "path", let nazwa = biezacyMagazyn {
                    out[String(pola[1])] = NazwaMontowania(nazwa: nazwa, rodzaj: .magazyn)
                }
            } else if tekst.trimmingCharacters(in: .whitespaces).isEmpty {
                biezacyMagazyn = nil
            } else {
                // Nagłówek innego typu magazynu — kończy blok `dir:`.
                biezacyMagazyn = nil
            }
        }

        // 2. Podpięcia kontenerów: `<id> <ścieżka na hoście> <ścieżka w kontenerze>`.
        //    Bez tej mapy nie da się powiązać `path = /mnt/zasoby` z `smb.conf` kontenera
        //    z katalogiem na hoście — w środku kontenera ścieżka bywa zupełnie inna.
        var podpiecia: [String: [String: String]] = [:]      // ctid → (ścieżka w gościu → na hoście)
        for linia in (sekcje["BIND"] ?? "").split(separator: "\n") {
            let pola = linia.split(separator: " ", omittingEmptySubsequences: true)
            guard pola.count >= 3 else { continue }
            podpiecia[String(pola[0]), default: [:]][String(pola[2])] = String(pola[1])
        }

        // 3. Udziały Samby: sekcje `[Nazwa]` i ich `path =` z każdego kontenera.
        //    Nazwa udziału bywa ze spacją („Zdjecia Rodzinne"), więc bierzemy całą zawartość
        //    nawiasu, nie pierwsze słowo.
        var ct: String?
        var udzial: String?
        for linia in (sekcje["SMB"] ?? "").split(separator: "\n") {
            let tekst = linia.trimmingCharacters(in: .whitespaces)
            if tekst.hasPrefix("CT ") {
                ct = String(tekst.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                udzial = nil
            } else if tekst.hasPrefix("["), tekst.hasSuffix("]") {
                let nazwa = String(tekst.dropFirst().dropLast())
                // `[global]` to ustawienia serwera, nie udział.
                udzial = nazwa.lowercased() == "global" ? nil : nazwa
            } else if tekst.hasPrefix("path"), let nazwa = udzial, let id = ct {
                guard let znak = tekst.firstIndex(of: "=") else { continue }
                let wGosciu = tekst[tekst.index(after: znak)...].trimmingCharacters(in: .whitespaces)
                guard let naHoscie = podpiecia[id]?[wGosciu] else { continue }
                out[naHoscie] = NazwaMontowania(nazwa: nazwa, rodzaj: .udzial)
            }
        }

        return out
    }

    // MARK: Wiersze

    /// Składa listę „ile miejsca gdzie" z nazw i z sekcji `@@DF` zbiorczego odczytu.
    ///
    /// `df` przychodzi tą samą drogą, co reszta statystyk — nie ma tu żadnego dodatkowego
    /// wywołania SSH co turę. Nowy jest wyłącznie odczyt nazw, robiony raz na połączenie.
    static func udzialy(nazwy: [String: NazwaMontowania], df: String) -> [Udzial] {
        var out: [Udzial] = []
        for linia in df.split(separator: "\n") {
            let pola = linia.split(separator: " ", omittingEmptySubsequences: true)
            // Filesystem 1-blocks Used Available Capacity Mounted-on
            guard pola.count >= 6, let zajete = Int64(pola[2]), let wolne = Int64(pola[3]) else { continue }
            let sciezka = pola[5...].joined(separator: " ")
            guard sciezka.hasPrefix(przedrostek) else { continue }

            let opis = nazwy[sciezka] ?? NazwaMontowania(
                // Nikt tego nie nazwał — bierzemy ostatni człon ścieżki zamiast wymyślać.
                nazwa: String(sciezka.split(separator: "/").last ?? Substring(sciezka)),
                rodzaj: .katalog)

            out.append(Udzial(sciezka: sciezka,
                              nazwa: opis.nazwa,
                              rodzaj: opis.rodzaj,
                              zajete: zajete,
                              calosc: zajete + wolne))
        }

        // Najpełniejsze na górze — kafel ma odpowiadać na „gdzie się kończy miejsce",
        // a nie na „co jest alfabetycznie pierwsze". Ścieżka rozstrzyga remisy, żeby
        // kolejność nie skakała między odświeżeniami przy równej zajętości.
        return out.sorted { lewe, prawe in
            if lewe.procent != prawe.procent { return lewe.procent > prawe.procent }
            return lewe.sciezka < prawe.sciezka
        }
    }
}
