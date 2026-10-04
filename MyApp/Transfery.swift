import Foundation

/// Monitor transferów — co płynie przez łącze i kto to ciągnie.
///
/// > [!info] Skąd to jest
/// > Decyzja [U] 2026-08-23:
/// > *„robimy do mnas bez dodatkowej strony www"*. Źródłem jest **RRD Proxmoksa**
/// > (`/nodes/{n}/rrddata`, `/nodes/{n}/lxc/{vmid}/rrddata`), czyli ta sama maszyna,
/// > z którą apka i tak rozmawia tokenem `root@pam!mnas`. **Żadnej nowej usługi na
/// > serwerze, żadnego SSH** — wcześniejsze źródło (`/var/log/pomiar-ruchu`, timer
/// > systemd co 10 s) [U] skasował 2026-08-29 i nie wraca.
///
/// > [!tip] 🟢 RRD podaje **prędkości**, nie liczniki narastające
/// > Zmierzone 2026-08-29 na serwerze testowym: host `netin=2726.63`, `netout=6083.32` — to bajty
/// > na sekundę już policzone przez Proxmoksa. Znika przez to cała arytmetyka różnic
/// > między próbkami, a razem z nią 🔴 **pułapka odwróconego kierunku na `veth`**, która
/// > 2026-08-23 kosztowała błędny wniosek o tym, kto zapisał 320 MB.
/// >
/// > `netin` znaczy **„do tego, kto stoi w nazwie"**, `netout` — „od niego". Dla hosta
/// > i dla kontenera tak samo, bez żadnego odwracania. Nie dokładaj go z powrotem.
///
/// > [!important] Host to **całe łącze**, nie „jeszcze jeden strumień"
/// > `pvestatd` sumuje do `netin`/`netout` węzła wyłącznie interfejsy, które przejdą
/// > `PVE::Network::ip_link_is_physical` — komentarz w źródle brzmi wprost
/// > *„traffic from/to physical interface cards”* (`pvestatd.pm:198`, odczytane
/// > 2026-08-29). Mostki i `veth` **nie wchodzą** do tej sumy, więc host jest
/// > mianownikiem udziału, a nie wierszem na liście. Stary kafel miał na to trzy
/// > osobne pojęcia (`nic0`, `vmbr0`, `veth…`); zostaje jedno.
///
/// > [!danger] 🔴 Czego to NIE odpowiada
/// > **„Która maszyna w domu ciągnie"** — RRD zna ruch kontenera, nie zna adresu klienta.
/// > Dawał to `conntrack` (Etap 2 planu), skasowany razem z licznikiem 2026-08-29.
/// > Pytanie zostaje otwarte i widok mówi to wprost, zamiast udawać odpowiedź.

// MARK: - Okno czasu

/// Okna, które RRD Proxmoksa naprawdę trzyma — nazwy i kroki **zmierzone**, nie założone.
///
/// Pomiar z 2026-08-29 (`pvesh get /nodes/pve/rrddata --timeframe …`):
/// `hour` 60 próbek co 60 s · `day` 1440 co 60 s · `week` 336 co 1800 s ·
/// `month` 1440 co 1800 s · `year` 1440 co 21600 s. Najstarsze kubełki bywają **puste**
/// (`netin` w ogóle nie ma w wierszu) i to jest brak pomiaru, nie zero — patrz `punkty`.
nonisolated enum OknoRRD: String, CaseIterable, Sendable, Identifiable {
    case hour, day, week, month, year

    var id: String { rawValue }

    var etykieta: String {
        switch self {
        case .hour:  return String(localized: "Godzina")
        case .day:   return String(localized: "Doba")
        case .week:  return String(localized: "Tydzień")
        case .month: return String(localized: "Miesiąc")
        case .year:  return String(localized: "Rok")
        }
    }

    /// Odstęp między próbkami. Służy tylko jako **wartość awaryjna** — realny krok
    /// bierzemy z danych (`TransferyParsers.krok`), bo prawdę ma pomiar, nie tabela.
    var krokSekund: Double {
        switch self {
        case .hour, .day:    return 60
        case .week, .month:  return 1_800
        case .year:          return 21_600
        }
    }

    var opisRozdzielczosci: String {
        switch self {
        case .hour, .day:   return String(localized: "próbka co minutę")
        case .week, .month: return String(localized: "próbka co pół godziny")
        case .year:         return String(localized: "próbka co sześć godzin")
        }
    }
}

// MARK: - Wiersz RRD

/// Jeden wiersz odpowiedzi `rrddata` — dokładnie te trzy pola, które nas obchodzą.
///
/// `netin` i `netout` są `Optional` **celowo**: w dłuższych oknach kubełki sprzed
/// pierwszych danych przychodzą bez tych kluczy (zmierzone 2026-08-29: `week` 5 wierszy
/// z 336, `year` 1384 z 1440). Wstawienie tam zera narysowałoby ciszę tam, gdzie po
/// prostu nikt jeszcze nie mierzył.
/// Wiersz `/nodes/{node}/storage/{id}/rrddata` — pola zmierzone 2026-10-04: `time`, `total`, `used`.
nonisolated struct WierszMagazynuRRD: Decodable, Sendable, Hashable {
    var time: Int
    var total: Double?
    var used: Double?
}

nonisolated struct WierszRRD: Decodable, Sendable, Hashable {
    var time: Int
    var netin: Double?
    var netout: Double?
    /// PSI „some" dla I/O, w procentach — ile czasu **cokolwiek** czekało na dysk.
    ///
    /// Jest tylko w RRD **węzła**; kontenery tego nie mają. Zmierzone 2026-09-04
    /// na serwerze testowym w trakcie kopii 422 GB z NVMe na dysk USB: cisza 7–14%, kopia 42–57%,
    /// skok co do minuty zgodny ze startem `rsync`. To jedyny sygnał o ruchu dyskowym,
    /// jaki RRD w ogóle niesie — `diskread`/`diskwrite` węzeł, inaczej niż kontener,
    /// po prostu nie raportuje (sprawdzone: pełna lista pól RRD węzła ich nie zawiera).
    var pressureiosome: Double?

    // Historia CPU i RAM (od 1.2.13, `Historia.swift`). Pola zmierzone 2026-10-04 przez
    // `pvesh … rrddata`: węzeł ma `cpu` (ułamek 0–1), `loadavg`, `mem*`, `swap*`;
    // kontener — `cpu`, `mem`, `maxmem`.
    var cpu: Double?
    var loadavg: Double?
    var memused: Double?
    var memtotal: Double?
    var memavailable: Double?
    var swapused: Double?
    var mem: Double?
    var maxmem: Double?
}

// MARK: - Punkt szeregu

/// Prędkości w jednej próbce. Nazwy są **z punktu widzenia tego, kogo dotyczy strumień**.
nonisolated struct PunktTransferu: Sendable, Hashable {
    var czas: Date
    /// `netin` — bajty na sekundę **do** hosta / kontenera.
    var doNiego: Double
    /// `netout` — bajty na sekundę **od** niego.
    var odNiego: Double

    var razemNaSekunde: Double { doNiego + odNiego }
}

// MARK: - Strumień

nonisolated struct Strumien: Identifiable, Sendable, Hashable {

    enum Rodzaj: Sendable, Hashable {
        /// Węzeł — suma kart fizycznych, czyli **całe łącze**.
        case lacze
        case kontener(vmid: Int)
        case maszyna(vmid: Int)

        var opis: String {
            switch self {
            case .lacze:     return String(localized: "całe łącze")
            case .kontener:  return String(localized: "kontener")
            case .maszyna:   return String(localized: "maszyna")
            }
        }
    }

    /// Ścieżka źródła w API — jednocześnie tożsamość wiersza: `host`, `lxc/104`, `qemu/200`.
    var zrodlo: String
    /// Nazwa po ludzku — hostname kontenera, gdy jest znany.
    var kto: String
    var rodzaj: Rodzaj
    /// Próbki rosnąco po czasie, każda z **gotową** prędkością.
    var punkty: [PunktTransferu]
    /// Realny odstęp próbek, policzony z danych. Potrzebny tylko do sumy bajtów w oknie.
    var krokSekund: Double

    var id: String { zrodlo }

    /// Ostatnia próbka. `nil` znaczy „nie ma pomiaru", a nie „zero".
    var teraz: PunktTransferu? { punkty.last }

    var bajtyNaSekunde: Double { teraz?.razemNaSekunde ?? 0 }
    var doNiegoNaSekunde: Double { teraz?.doNiego ?? 0 }
    var odNiegoNaSekunde: Double { teraz?.odNiego ?? 0 }

    var szczytNaSekunde: Double { punkty.map(\.razemNaSekunde).max() ?? 0 }

    var sredniaNaSekunde: Double {
        guard !punkty.isEmpty else { return 0 }
        return punkty.reduce(0) { $0 + $1.razemNaSekunde } / Double(punkty.count)
    }

    /// Ile czasu realnie objęły próbki, które mają pomiar — puste kubełki nie liczą się
    /// jako cisza, tylko wypadają z okna.
    var sekundObjete: Double { Double(punkty.count) * krokSekund }

    var razemBajtow: Int64 { bajty(\.razemNaSekunde) }
    var doNiegoBajtow: Int64 { bajty(\.doNiego) }
    var odNiegoBajtow: Int64 { bajty(\.odNiego) }

    private func bajty(_ pole: KeyPath<PunktTransferu, Double>) -> Int64 {
        Int64((punkty.reduce(0) { $0 + $1[keyPath: pole] } * krokSekund).rounded())
    }
}

// MARK: - Ruch na dyskach

/// Ile jeden dysk czyta i zapisuje **teraz**, w bajtach na sekundę.
///
/// > [!info] Po co to istnieje obok strumieni sieciowych
/// > Kafel „Transfery" mierzył wyłącznie łącze i to było poprawne — ale mylące.
/// > Kopia z dysku na dysk **wewnątrz serwera** nie przechodzi przez żadną kartę
/// > sieciową, więc kafel pokazywał ciszę w chwili, gdy dyski robiły 90 MB/s.
/// > Zgłoszone przez [U] 2026-09-04 przy kopii folderu `PROJEKTY`: *„kafelek transfery
/// > nie widzi aktualnego kopiowania"*.
/// >
/// > Zmierzone wtedy w tej samej sekundzie: `vmbr0` 7–65 kB/s, `nvme2n1` odczyt
/// > 93 MB/s, `sdd` zapis 97 MB/s. Kafel nie kłamał — po prostu nie o tym mówił.
nonisolated struct PrzeplywDysku: Identifiable, Sendable, Hashable {
    /// Nazwa urządzenia blokowego: `sda`, `nvme0n1`.
    var nazwa: String
    var odczytNaSekunde: Double
    var zapisNaSekunde: Double

    var id: String { nazwa }
    var razemNaSekunde: Double { odczytNaSekunde + zapisNaSekunde }
}

// MARK: - Kopia w toku

/// Trwające kopiowanie na serwerze — co, dokąd, ile już przeszło i ile zostało.
///
/// > [!info] Skąd biorą się liczby
/// > Postęp to `write_bytes` z `/proc/<pid>/io`, czyli ile ten proces **naprawdę
/// > zapisał** — licznik jądra, nie deklaracja programu. Całość to `du -sb` źródła.
/// > Jedno i drugie jest tanie: `du` na 51 393 plikach i 422 GiB zajęło **303 ms**,
/// > bo czyta metadane, a nie dane (zmierzone 2026-09-04 na serwerze testowym).
///
/// > [!tip] 🟢 Sprawdzone kontrolą krzyżową
/// > W trakcie kopii `PROJEKTY` 2026-09-04: `/proc/<pid>/io` dawało **49,9%**, a sam
/// > `rsync` w tej samej chwili raportował **49%**. Liczymy to samo, co on, tylko
/// > bez zaglądania mu w log — działa więc dla `cp` i `mv`, które nic nie wypisują.
nonisolated struct KopiaWToku: Identifiable, Sendable, Hashable {
    /// Najniższy PID z grupy — `rsync` forkuje się na trzy procesy o tej samej linii.
    var pid: Int
    /// Nazwa narzędzia: `rsync`, `cp`, `mv`, `dd`, `tar`.
    var narzedzie: String
    var sekundTrwa: Double
    /// Bajty zapisane przez proces, który realnie pisze.
    var zapisano: Int64
    /// Bajty odczytane przez proces, który realnie czyta.
    var odczytano: Int64
    /// Rozmiar źródła z `du -sb`. Zero znaczy „nie udało się policzyć".
    var calosc: Int64
    var zrodlo: String
    var cel: String

    var id: Int { pid }

    /// Ułamek `0…1`. `nil`, gdy nie znamy całości — i wtedy widok pokazuje same
    /// megabajty zamiast zmyślonego procentu.
    var postep: Double? {
        guard calosc > 0 else { return nil }
        return min(1, Double(zapisano) / Double(calosc))
    }

    var zostaloBajtow: Int64? {
        guard calosc > 0 else { return nil }
        return max(0, calosc - zapisano)
    }

    /// Średnia od początku kopii — nie prędkość chwilową.
    ///
    /// Chwilową pokazuje już sekcja dysków; tutaj średnia jest uczciwsza jako podstawa
    /// szacunku, ile jeszcze zostało.
    var sredniaNaSekunde: Double {
        guard sekundTrwa > 0 else { return 0 }
        return Double(zapisano) / sekundTrwa
    }

    /// Ile jeszcze potrwa, przy dotychczasowym tempie. `nil`, gdy nie ma podstaw.
    var szacowaneSekundy: Double? {
        guard let zostalo = zostaloBajtow, sredniaNaSekunde > 0 else { return nil }
        return Double(zostalo) / sredniaNaSekunde
    }

    /// Krótko: `PROJEKTY → dysk-kopii`. Pełne ścieżki zostają w podpowiedzi.
    var skrot: String {
        func ostatni(_ p: String) -> String {
            p.split(separator: "/").last.map(String.init) ?? p
        }
        return "\(ostatni(zrodlo)) → \(ostatni(cel))"
    }
}

/// Powód, dla którego nie udało się przeczytać transferów — do pokazania wprost w oknie.
/// Osobny typ, bo `String` nie jest w Swifcie typem błędu i `Result` go nie przyjmie.
nonisolated struct BladTransferow: Error, Sendable, Hashable {
    var opis: String
}

// MARK: - Parsery

nonisolated enum TransferyParsers {

    /// Poniżej tej prędkości strumień uznajemy za ciszę, nie za transfer.
    ///
    /// Kontener, który nic nie robi, i tak wymienia parę pakietów na minutę (ARP, ping
    /// z Kumy, keepalive SMB) — zmierzone 2026-08-29: bezczynna samba chodzi po
    /// 500–1200 B/s. Bez progu lista „co teraz płynie" miałaby zawsze komplet wierszy.
    static let progCiszyBajtowNaSekunde: Double = 4096

    /// Wiersze RRD → punkty szeregu, rosnąco po czasie.
    ///
    /// 🔴 Wiersz bez `netin`/`netout` **wypada**, zamiast wchodzić jako zero: to kubełek
    /// sprzed pierwszych danych, czyli brak pomiaru. Zero narysowałoby ciszę, której
    /// nikt nie zmierzył — a odróżnianie „nie wiem" od „nic nie płynęło" jest w tym
    /// projekcie regułą, nie ozdobą.
    static func punkty(_ wiersze: [WierszRRD]) -> [PunktTransferu] {
        wiersze
            .compactMap { w -> PunktTransferu? in
                guard let doNiego = w.netin, let odNiego = w.netout else { return nil }
                // Ujemnej prędkości RRD nie podaje; gdyby podał, jest to śmieć, nie pomiar.
                guard doNiego >= 0, odNiego >= 0 else { return nil }
                return PunktTransferu(czas: Date(timeIntervalSince1970: Double(w.time)),
                                      doNiego: doNiego, odNiego: odNiego)
            }
            .sorted { $0.czas < $1.czas }
    }

    /// Odstęp próbek policzony z danych — mediana różnic.
    ///
    /// Mediana, a nie pierwsza różnica: pojedyncza dziura w szeregu (kontener chwilę nie
    /// żył) przesunęłaby jedną różnicę, a mediana tego nie zauważy. Przy mniej niż dwóch
    /// punktach nie ma czego mierzyć i zostaje wartość awaryjna z `OknoRRD`.
    static func krok(_ punkty: [PunktTransferu], domyslnie: Double) -> Double {
        guard punkty.count >= 2 else { return domyslnie }
        let roznice = zip(punkty.dropFirst(), punkty)
            .map { $0.czas.timeIntervalSince($1.czas) }
            .filter { $0 > 0 }
            .sorted()
        guard !roznice.isEmpty else { return domyslnie }
        return roznice[roznice.count / 2]
    }

    /// Składa strumień z odpowiedzi RRD dla jednego źródła.
    static func strumien(zrodlo: String,
                         kto: String,
                         rodzaj: Strumien.Rodzaj,
                         wiersze: [WierszRRD],
                         okno: OknoRRD) -> Strumien {
        let p = punkty(wiersze)
        return Strumien(zrodlo: zrodlo,
                        kto: kto,
                        rodzaj: rodzaj,
                        punkty: p,
                        krokSekund: krok(p, domyslnie: okno.krokSekund))
    }

    /// Strumienie, które naprawdę coś przesyłają — bez łącza i bez ciszy.
    ///
    /// Łącze wypada, bo ono **jest** zasobem, który reszta dzieli, a nie jednym
    /// z dzielących. Zostaje osobno, jako mianownik.
    static func aktywne(_ strumienie: [Strumien]) -> [Strumien] {
        strumienie.filter { s in
            if case .lacze = s.rodzaj { return false }
            return s.bajtyNaSekunde >= progCiszyBajtowNaSekunde
        }
    }

    /// Udział strumienia w łączu, `0…1`, liczony z **całego okna**, nie z ostatniej próbki.
    ///
    /// Suma udziałów bywa nieco mniejsza niż 1 (narzuty ramek) i to jest poprawne —
    /// dopychanie jej do równej jedynki byłoby zmyślaniem. Bywa też **większa** od
    /// pojedynczego udziału 1, gdy kontener gada z drugim kontenerem bez wychodzenia
    /// na kartę — dlatego wynik jest przycięty do jedynki.
    static func udzial(_ s: Strumien, wLaczu lacze: Strumien?) -> Double? {
        guard let lacze, lacze.razemBajtow > 0 else { return nil }
        return min(1, Double(s.razemBajtow) / Double(lacze.razemBajtow))
    }

    // MARK: Dyski

    /// Poniżej tej prędkości ruch na dysku uznajemy za tło, nie za kopiowanie.
    ///
    /// System pisze bez przerwy drobiazgi — dzienniki, `atime`, metadane RRD samego
    /// Proxmoksa. Zmierzone 2026-09-04 na bezczynnym serwerze testowym: dysk systemowy chodził
    /// po kilkadziesiąt–kilkaset kB/s, gdy nikt nic nie kopiował. Próg 1 MB/s odcina
    /// to tło, a nie odcina niczego, co człowiek nazwałby kopiowaniem.
    static let progTlaDyskowBajtowNaSekunde: Double = 1_048_576

    /// Wyjście polecenia `ServerCommands.przeplywDyskow` → lista dysków.
    ///
    /// Format to trzy pola w wierszu: `nazwa odczytBajtowNaSekunde zapisBajtowNaSekunde`.
    /// Liczby są **już** różnicą dwóch próbek `/proc/diskstats` odległych o sekundę,
    /// przeliczoną z sektorów (512 B) na bajty — arytmetyka siedzi po stronie serwera,
    /// bo tam są obie próbki i tam jest znany odstęp.
    ///
    /// 🔴 Wiersz, którego nie da się rozebrać, **wypada** zamiast wchodzić jako zero.
    /// Ta sama zasada co przy `punkty(_:)`: brak pomiaru to nie cisza.
    static func przeplywyDyskow(_ tekst: String) -> [PrzeplywDysku] {
        tekst.split(whereSeparator: \.isNewline).compactMap { linia -> PrzeplywDysku? in
            let pola = linia.split(separator: " ", omittingEmptySubsequences: true)
            guard pola.count == 3,
                  let odczyt = Double(pola[1]), let zapis = Double(pola[2]),
                  odczyt >= 0, zapis >= 0 else { return nil }
            return PrzeplywDysku(nazwa: String(pola[0]),
                                 odczytNaSekunde: odczyt, zapisNaSekunde: zapis)
        }
        .sorted { $0.razemNaSekunde > $1.razemNaSekunde }
    }

    /// Dyski, które naprawdę pracują — posortowane, bez tła.
    static func pracujace(_ dyski: [PrzeplywDysku]) -> [PrzeplywDysku] {
        dyski.filter { $0.razemNaSekunde >= progTlaDyskowBajtowNaSekunde }
    }

    /// Suma ruchu na wszystkich dyskach — jedna liczba do nagłówka kafla.
    static func sumaDyskow(_ dyski: [PrzeplywDysku]) -> Double {
        dyski.reduce(0) { $0 + $1.razemNaSekunde }
    }

    /// Wyjście `ServerCommands.kopieWToku` → lista trwających kopii.
    ///
    /// Wiersz ma osiem pól rozdzielonych **tabulatorem**, nie spacją — ścieżki potrafią
    /// zawierać spacje i przy dzieleniu po spacji rozpadłyby się na kawałki.
    ///
    /// 🔴 `rsync` uruchamia **trzy procesy** o identycznej linii poleceń: jeden czyta,
    /// jeden zapisuje, jeden generuje listę. Bez grupowania kafel pokazałby trzy wiersze
    /// tej samej kopii, w tym dwa z zerowym postępem. Grupujemy po parze `źródło → cel`
    /// i bierzemy **maksimum** z każdego licznika — bo to ten proces, który naprawdę
    /// pisze, i ten, który naprawdę czyta.
    static func kopie(_ tekst: String) -> [KopiaWToku] {
        var grupy: [String: KopiaWToku] = [:]

        for linia in tekst.split(whereSeparator: \.isNewline) {
            let p = linia.split(separator: "\t", omittingEmptySubsequences: false)
            guard p.count == 8,
                  let pid = Int(p[0]), let sekundy = Double(p[1]),
                  let zapis = Int64(p[3]), let odczyt = Int64(p[4]),
                  let calosc = Int64(p[5]) else { continue }

            let zrodlo = String(p[6]), cel = String(p[7])
            guard zrodlo != "?" , cel != "?" else { continue }

            let klucz = "\(p[2])\u{1}\(zrodlo)\u{1}\(cel)"
            if var istniejaca = grupy[klucz] {
                istniejaca.pid = min(istniejaca.pid, pid)
                istniejaca.zapisano = max(istniejaca.zapisano, zapis)
                istniejaca.odczytano = max(istniejaca.odczytano, odczyt)
                istniejaca.sekundTrwa = max(istniejaca.sekundTrwa, sekundy)
                grupy[klucz] = istniejaca
            } else {
                grupy[klucz] = KopiaWToku(pid: pid, narzedzie: String(p[2]),
                                          sekundTrwa: sekundy, zapisano: zapis,
                                          odczytano: odczyt, calosc: calosc,
                                          zrodlo: zrodlo, cel: cel)
            }
        }
        return grupy.values.sorted { $0.zapisano > $1.zapisano }
    }

    /// Ostatnie znane ciśnienie I/O z RRD węzła, w procentach.
    ///
    /// Zapasowe źródło na wypadek wyłączonego SSH: nie poda megabajtów ani nie wskaże
    /// dysku, ale odróżnia pracę od ciszy. `nil` znaczy „nie wiem", nie „zero".
    static func obciazenieIO(_ wiersze: [WierszRRD]) -> Double? {
        wiersze.compactMap(\.pressureiosome).last
    }

    /// Próg, powyżej którego ciśnienie I/O uznajemy za realną pracę dysków.
    ///
    /// Wyznaczony pomiarem z 2026-09-04, nie zgadnięty: cisza trzymała się 7–14%,
    /// kopia 42–57%. Trzydzieści leży w środku tej luki, z zapasem po obu stronach.
    static let progObciazeniaIO: Double = 30

    /// Największa prędkość w całym zestawie — wspólna skala osi Y dla wykresów.
    ///
    /// Bez niej strumień 200 kB/s wyglądałby jak ten na 40 MB/s i porównanie, po które
    /// się na ten widok przychodzi, nie miałoby sensu.
    static func wspolnaSkala(_ strumienie: [Strumien]) -> Double {
        max(strumienie.map(\.szczytNaSekunde).max() ?? 1, 1)
    }
}
