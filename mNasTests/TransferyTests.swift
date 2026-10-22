import Testing
import Foundation
@testable import mNas

/// Testy monitora transferów po przepięciu na RRD Proxmoksa (P12, 2026-08-29).
///
/// Wejście to **prawdziwa odpowiedź serwera testowego**, zdjęta tego dnia:
/// `pvesh get /nodes/pve/rrddata --timeframe hour` oraz to samo dla `lxc/104` (samba)
/// i `lxc/108` (nextcloud). Wartości oczekiwane policzone ręcznie z tych samych liczb,
/// żeby test mierzył arytmetykę, a nie powtarzał kod.
///
/// 🔴 Najważniejsza rzecz, której te testy pilnują: **RRD podaje gotowe prędkości**.
/// Poprzednie źródło dawało liczniki narastające i kazało liczyć różnice — razem z nimi
/// odeszła pułapka odwróconego kierunku na `veth`. Gdyby ktoś zaczął tu liczyć delty
/// albo odwracać kierunek dla kontenerów, testy niżej muszą tego nie przepuścić.
@Suite("Transfery: RRD daje prędkości, łącze jest mianownikiem")
struct TransferyTests {

    /// Pięć pierwszych próbek okna `hour`, węzeł pve. Skrócone do pól, które czytamy.
    static let jsonLacza = """
    [{"netin": 2726.62833333333, "netout": 6083.32, "time": 1788017640},
     {"netin": 3172.445, "netout": 5847.11666666667, "time": 1788017700},
     {"netin": 2650.25666666667, "netout": 5901.91, "time": 1788017760},
     {"netin": 3360.32166666667, "netout": 5797.99, "time": 1788017820},
     {"netin": 2925.28166666667, "netout": 5931.14833333333, "time": 1788017880}]
    """

    /// Te same chwile, kontener 104 (samba).
    static let jsonSamby = """
    [{"netin": 638.778333333334, "netout": 369.316666666667, "time": 1788017640},
     {"netin": 1067.42833333333, "netout": 15.3, "time": 1788017700},
     {"netin": 471.408333333333, "netout": 57.67, "time": 1788017760},
     {"netin": 1247.54833333333, "netout": 255.211666666667, "time": 1788017820},
     {"netin": 769.406666666667, "netout": 58.5816666666667, "time": 1788017880}]
    """

    /// Jeden wiersz w **pełnym** kształcie, jaki naprawdę przychodzi z węzła — dwadzieścia
    /// pól, z których obchodzą nas trzy.
    static let jsonPelnegoWiersza = """
    [{"arcsize":1440,"cpu":0.0302298137995792,"iowait":0.00179257143458032,
      "loadavg":0.329333333333333,"maxcpu":6,"memavailable":21533259434.6667,
      "memtotal":25025593344,"memused":3492333909.33333,"netin":739.328333333333,
      "netout":194.236666666667,"pressurecpusome":0,"pressureiofull":0.00233333333333333,
      "pressureiosome":0.00233333333333333,"pressurememoryfull":0,"pressurememorysome":0,
      "roottotal":89615622144,"rootused":12738215936,"swaptotal":8149528576,
      "swapused":209059840,"time":1788021120}]
    """

    private func wiersze(_ json: String) -> [WierszRRD] {
        try! JSONDecoder().decode([WierszRRD].self, from: Data(json.utf8))
    }

    private func lacze() -> Strumien {
        TransferyParsers.strumien(zrodlo: "host", kto: "pve", rodzaj: .lacze,
                                  wiersze: wiersze(Self.jsonLacza), okno: .hour)
    }

    private func samba() -> Strumien {
        TransferyParsers.strumien(zrodlo: "lxc/104", kto: "samba", rodzaj: .kontener(vmid: 104),
                                  wiersze: wiersze(Self.jsonSamby), okno: .hour)
    }

    // MARK: - Odczyt

    @Test("Odpowiedź rrddata dekoduje się na wiersze")
    func dekodowanie() {
        let w = wiersze(Self.jsonLacza)
        #expect(w.count == 5)
        #expect(w[0].time == 1788017640)
        #expect(w[0].netin == 2726.62833333333)
    }

    /// Węzeł oddaje dwadzieścia pól i będzie ich oddawał więcej z każdą wersją Proxmoksa.
    /// Dekoder ma brać swoje trzy i nie krztusić się resztą.
    @Test("Nieznane pola w wierszu nie psują odczytu")
    func pelnyWierszSieDekoduje() {
        let w = wiersze(Self.jsonPelnegoWiersza)
        #expect(w.count == 1)
        #expect(w[0].netout == 194.236666666667)
    }

    // MARK: - 🔴 Prędkości, nie liczniki

    /// Najważniejszy test w tym pliku. Wartość z RRD ma trafić na wykres **taka, jaka
    /// jest** — bez odejmowania próbki poprzedniej i bez dzielenia przez czas.
    @Test("Prędkość bierze się wprost z próbki, nie z różnicy między próbkami")
    func predkoscBezArytmetyki() {
        let p = TransferyParsers.punkty(wiersze(Self.jsonLacza))
        #expect(p.count == 5)
        #expect(p[0].doNiego == 2726.62833333333)
        #expect(p[0].odNiego == 6083.32)
        // Różnica pierwszej pary (3172,4 − 2726,6 = 445,8) nie ma prawa nigdzie wyjść.
        #expect(p[1].doNiego == 3172.445)
    }

    /// Odwracanie kierunku było potrzebne przy licznikach `veth` czytanych z punktu
    /// widzenia hosta. RRD kontenera jest już z punktu widzenia kontenera.
    @Test("Kierunku dla kontenera się nie odwraca")
    func kierunekKonteneraBezOdwracania() {
        let p = TransferyParsers.punkty(wiersze(Self.jsonSamby))
        #expect(p[0].doNiego == 638.778333333334)
        #expect(p[0].odNiego == 369.316666666667)
    }

    /// 🔴 Brak pomiaru to nie zero. W oknach `week`/`month`/`year` najstarsze kubełki
    /// przychodzą bez `netin` (zmierzone 2026-08-29: 1384 z 1440 wierszy roku).
    @Test("Wiersz bez pomiaru wypada, zamiast wchodzić jako cisza")
    func brakPomiaruNieJestZerem() {
        let json = """
        [{"time": 1788017640},
         {"netin": 100, "time": 1788017700},
         {"netin": 200, "netout": 50, "time": 1788017760}]
        """
        let p = TransferyParsers.punkty(wiersze(json))
        #expect(p.count == 1)
        #expect(p[0].doNiego == 200)
    }

    @Test("Ujemna prędkość to śmieć, nie pomiar")
    func ujemnaWypada() {
        let json = """
        [{"netin": -5, "netout": 10, "time": 1788017640},
         {"netin": 5, "netout": 10, "time": 1788017700}]
        """
        #expect(TransferyParsers.punkty(wiersze(json)).count == 1)
    }

    @Test("Punkty wracają rosnąco po czasie, niezależnie od kolejności w odpowiedzi")
    func punktyPosortowane() {
        let json = """
        [{"netin": 1, "netout": 1, "time": 1788017760},
         {"netin": 2, "netout": 2, "time": 1788017640},
         {"netin": 3, "netout": 3, "time": 1788017700}]
        """
        let p = TransferyParsers.punkty(wiersze(json))
        #expect(p.map { Int($0.czas.timeIntervalSince1970) } == [1788017640, 1788017700, 1788017760])
    }

    // MARK: - Krok próbki

    @Test("Krok liczony z danych, nie przepisany z tabeli")
    func krokZDanych() {
        #expect(lacze().krokSekund == 60)
    }

    /// Mediana, nie pierwsza różnica: jedna dziura w szeregu nie ma prawa przestawić
    /// kroku, bo po kroku liczymy sumę bajtów w oknie.
    @Test("Dziura w szeregu nie przestawia kroku")
    func dziuraNiePrzestawiaKroku() {
        let json = """
        [{"netin": 1, "netout": 1, "time": 1788017640},
         {"netin": 1, "netout": 1, "time": 1788017700},
         {"netin": 1, "netout": 1, "time": 1788018300},
         {"netin": 1, "netout": 1, "time": 1788018360}]
        """
        let p = TransferyParsers.punkty(wiersze(json))
        #expect(TransferyParsers.krok(p, domyslnie: 999) == 60)
    }

    @Test("Bez dwóch próbek zostaje krok awaryjny okna")
    func krokAwaryjny() {
        #expect(TransferyParsers.krok([], domyslnie: OknoRRD.week.krokSekund) == 1_800)
        let jeden = TransferyParsers.punkty(wiersze("""
        [{"netin": 1, "netout": 1, "time": 1788017640}]
        """))
        #expect(TransferyParsers.krok(jeden, domyslnie: OknoRRD.year.krokSekund) == 21_600)
    }

    /// Kroki awaryjne mają odpowiadać temu, co RRD naprawdę zwraca — zmierzone 2026-08-29.
    @Test("Okna RRD mają zmierzone nazwy i kroki")
    func oknaZgodneZPomiarem() {
        #expect(OknoRRD.allCases.map(\.rawValue) == ["hour", "day", "week", "month", "year"])
        #expect(OknoRRD.hour.krokSekund == 60)
        #expect(OknoRRD.day.krokSekund == 60)
        #expect(OknoRRD.month.krokSekund == 1_800)
    }

    // MARK: - Podsumowania okna

    @Test("Teraz to ostatnia próbka, nie średnia")
    func terazToOstatnia() {
        // 2925,28 + 5931,15 = 8856,43
        #expect(abs(lacze().bajtyNaSekunde - 8856.43) < 0.01)
    }

    @Test("Szczyt i średnia liczone z całego okna")
    func szczytISrednia() {
        // Szczyt to czwarta próbka: 3360,32 + 5797,99 = 9158,31.
        #expect(abs(lacze().szczytNaSekunde - 9158.31) < 0.01)
        // Suma pięciu: 44 396,42 → średnia 8 879,28.
        #expect(abs(lacze().sredniaNaSekunde - 8879.28) < 0.01)
    }

    /// Bajty w oknie to prędkość razy czas, i nic więcej — RRD nie podaje sum.
    @Test("Suma bajtów to prędkość razy krok próbki")
    func sumaBajtow() {
        // 4950,65 B/s łącznie przez pięć minutowych kubełków = 297 039 B.
        #expect(samba().razemBajtow == 297_039)
        // Rozbicie na kierunki: netout 756,08 × 60, netin 4194,57 × 60.
        #expect(samba().odNiegoBajtow == 45_365)
        #expect(samba().doNiegoBajtow == 251_674)
        #expect(samba().sekundObjete == 300)
    }

    // MARK: - Łącze jako mianownik

    @Test("Łącze nie jest jednym ze strumieni, które je dzielą")
    func laczeNieJestStrumieniem() {
        let glosneLacze = TransferyParsers.strumien(
            zrodlo: "host", kto: "pve", rodzaj: .lacze,
            wiersze: wiersze("""
            [{"netin": 40000000, "netout": 100, "time": 1788017640},
             {"netin": 40000000, "netout": 100, "time": 1788017700}]
            """), okno: .hour)
        #expect(TransferyParsers.aktywne([glosneLacze, samba()]).isEmpty)
    }

    /// Kontener bez roboty i tak wymienia parę pakietów (ARP, ping z Kumy, keepalive SMB) —
    /// zmierzone 2026-08-29: bezczynna samba chodzi po 500–1200 B/s.
    @Test("Cisza odsiewana progiem — na tym wycinku nic nie płynie")
    func ciszaOdsiana() {
        #expect(TransferyParsers.aktywne([lacze(), samba()]).isEmpty)
    }

    @Test("Strumień powyżej progu zostaje na liście")
    func glosnyZostaje() {
        let glosny = TransferyParsers.strumien(
            zrodlo: "lxc/108", kto: "nextcloud", rodzaj: .kontener(vmid: 108),
            wiersze: wiersze("""
            [{"netin": 5000000, "netout": 1000, "time": 1788017640},
             {"netin": 5000000, "netout": 1000, "time": 1788017700}]
            """), okno: .hour)
        #expect(TransferyParsers.aktywne([lacze(), glosny, samba()]).map(\.id) == ["lxc/108"])
    }

    @Test("Udział liczony względem łącza, z całego okna")
    func udzialWzgledemLacza() {
        // 297 039 / 2 663 785 = 0,1115
        let u = TransferyParsers.udzial(samba(), wLaczu: lacze())
        #expect(abs((u ?? 0) - 0.1115) < 0.001)
    }

    @Test("Bez łącza udziału nie zmyślamy")
    func bezLaczaBrakUdzialu() {
        #expect(TransferyParsers.udzial(samba(), wLaczu: nil) == nil)
    }

    /// Kontener gadający z drugim kontenerem nie wychodzi na kartę fizyczną, więc jego
    /// ruch potrafi przebić łącze. To poprawny pomiar, ale „180 % łącza" na pasku nie jest.
    @Test("Udział przycięty do jedynki, gdy ruch nie wychodzi na kartę")
    func udzialPrzyciety() {
        let wewnetrzny = TransferyParsers.strumien(
            zrodlo: "lxc/109", kto: "sync", rodzaj: .kontener(vmid: 109),
            wiersze: wiersze("""
            [{"netin": 50000000, "netout": 0, "time": 1788017640},
             {"netin": 50000000, "netout": 0, "time": 1788017700}]
            """), okno: .hour)
        #expect(TransferyParsers.udzial(wewnetrzny, wLaczu: lacze()) == 1)
    }

    // MARK: - Wspólna skala

    /// Bez wspólnej skali strumień 200 kB/s wyglądałby jak ten na 40 MB/s i porównanie,
    /// po które się na ten widok przychodzi, nie miałoby sensu.
    @Test("Wspólna skala to najwyższy szczyt z zestawu")
    func wspolnaSkala() {
        #expect(abs(TransferyParsers.wspolnaSkala([lacze(), samba()]) - 9158.31) < 0.01)
        // Pusty zestaw nie dzieli przez zero.
        #expect(TransferyParsers.wspolnaSkala([]) == 1)
    }

    @Test("Strumień bez próbek nie udaje ciszy ani nie wywraca rachunku")
    func pustyStrumien() {
        let pusty = TransferyParsers.strumien(zrodlo: "lxc/107", kto: "zdjecia",
                                              rodzaj: .kontener(vmid: 107),
                                              wiersze: [], okno: .hour)
        #expect(pusty.teraz == nil)
        #expect(pusty.razemBajtow == 0)
        #expect(pusty.sekundObjete == 0)
        #expect(pusty.krokSekund == 60)
    }
}

/// Ruch na dyskach — to, czego łącze nie widzi.
///
/// Wejście to **prawdziwe wyjście serwera testowego** zdjęte 2026-09-04 w trakcie kopii folderu
/// `PROJEKTY` (452 GB, z NVMe na dysk USB). Ta sesja zaczęła się od zgłoszenia
/// użytkownika: kafel „Transfery" pokazywał 16 kB/s w chwili, gdy dyski robiły 90 MB/s — bo
/// kopia host→host nie przechodzi przez żadną kartę sieciową.
///
/// 🔴 Czego te testy pilnują przede wszystkim: **`rsync` to trzy procesy o identycznej
/// linii poleceń**. Jeden czyta, jeden pisze, jeden generuje listę. Bez grupowania kafel
/// pokazałby trzy wiersze tej samej kopii, w tym dwa z zerowym postępem.
@Suite("Transfery: ruch na dyskach i trwające kopie")
struct RuchDyskowTests {

    /// Prawdziwe wyjście `przeplywDyskow` z serwera testowego, w trakcie kopii.
    static let wyjscieDyskow = """
    nvme0n1 0 6225920
    nvme2n1 86016000 135168
    nvme1n1 0 0
    sdb 0 0
    sdc 0 0
    sda 0 0
    sdd 0 87379968
    """

    /// Prawdziwe wyjście `kopieWToku` — trzy procesy jednego `rsync`.
    static let wyjscieKopii = [
        "3360447\t2921\trsync\t2834432\t233076830208\t452428723128\t/mnt/zasoby/PROJEKTY/\t/mnt/dysk-kopii/PROJEKTY/",
        "3360449\t2921\trsync\t0\t57344\t452428723128\t/mnt/zasoby/PROJEKTY/\t/mnt/dysk-kopii/PROJEKTY/",
        "3360455\t2921\trsync\t233106214912\t8192\t452428723128\t/mnt/zasoby/PROJEKTY/\t/mnt/dysk-kopii/PROJEKTY/",
    ].joined(separator: "\n")

    @Test("Przepływy dyskowe wracają posortowane, od najbardziej obciążonego")
    func sortowanie() {
        let d = TransferyParsers.przeplywyDyskow(Self.wyjscieDyskow)
        #expect(d.count == 7)
        #expect(d[0].nazwa == "sdd")          // 87,4 MB/s zapisu
        #expect(d[1].nazwa == "nvme2n1")      // 86,0 MB/s odczytu
    }

    @Test("Odczyt i zapis nie mieszają się ze sobą")
    func kierunki() {
        let d = TransferyParsers.przeplywyDyskow(Self.wyjscieDyskow)
        let zrodlo = try! #require(d.first { $0.nazwa == "nvme2n1" })
        let cel = try! #require(d.first { $0.nazwa == "sdd" })
        #expect(zrodlo.odczytNaSekunde == 86_016_000)
        #expect(zrodlo.zapisNaSekunde == 135_168)
        #expect(cel.odczytNaSekunde == 0)
        #expect(cel.zapisNaSekunde == 87_379_968)
    }

    @Test("Dyski w spoczynku wypadają z listy pracujących")
    func progTla() {
        let pracujace = TransferyParsers.pracujace(
            TransferyParsers.przeplywyDyskow(Self.wyjscieDyskow))
        // Trzy, nie dwa: dysk systemowy nvme0n1 pisał w tej chwili 5,9 MB/s (RRD
        // i dzienniki samego Proxmoksa), czyli powyżej progu 1 MB/s. Cztery pozostałe
        // stały na zerze i wypadają.
        #expect(pracujace.count == 3)
        #expect(Set(pracujace.map(\.nazwa)) == ["sdd", "nvme2n1", "nvme0n1"])
        #expect(!pracujace.contains { $0.nazwa == "sda" })
    }

    @Test("KONTROLA DODATNIA: bez progu widać wszystkie siedem dysków")
    func kontrolaDodatnia() {
        // Gdyby parser gubił wiersze, poprzedni test przeszedłby z tego samego powodu,
        // z którego przechodzi teraz. Ten pilnuje, że filtruje próg, a nie parser.
        #expect(TransferyParsers.przeplywyDyskow(Self.wyjscieDyskow).count == 7)
    }

    @Test("Śmieciowy wiersz wypada, zamiast wchodzić jako zero")
    func smieci() {
        let d = TransferyParsers.przeplywyDyskow("sda 100 200\nzepsute\nsdb x y\nsdc 5 6")
        #expect(d.map(\.nazwa) == ["sda", "sdc"])
    }

    @Test("Trzy procesy jednego rsynca to JEDNA kopia")
    func grupowanie() {
        let k = TransferyParsers.kopie(Self.wyjscieKopii)
        #expect(k.count == 1)
    }

    @Test("Postęp bierze się z procesu, który naprawdę pisze")
    func postep() {
        let k = try! #require(TransferyParsers.kopie(Self.wyjscieKopii).first)
        #expect(k.zapisano == 233_106_214_912)     // maksimum z trzech, nie pierwszy z brzegu
        #expect(k.odczytano == 233_076_830_208)
        #expect(k.pid == 3_360_447)                // najniższy z grupy
        let p = try! #require(k.postep)
        // 233,1 GB z 452,4 GB. Sam rsync mówił w tej chwili 49% — zgodne.
        #expect(abs(p - 0.5152) < 0.001)
    }

    @Test("Ile zostało i jak długo — z tych samych liczb")
    func pozostalo() {
        let k = try! #require(TransferyParsers.kopie(Self.wyjscieKopii).first)
        let oczekiwane: Int64 = 219_322_508_216
        #expect(k.calosc == 452_428_723_128)
        #expect(k.zapisano == 233_106_214_912)
        #expect(k.zostaloBajtow == oczekiwane)
        let srednia = try! #require(k.sredniaNaSekunde as Double?)
        #expect(abs(srednia - 233_106_214_912.0 / 2921.0) < 1)
        let eta = try! #require(k.szacowaneSekundy)
        #expect(eta > 0)
    }

    @Test("Bez rozmiaru źródła nie zmyślamy procentu")
    func brakCalosci() {
        let bez = "999\t10\tcp\t500\t500\t0\t/a\t/b"
        let k = try! #require(TransferyParsers.kopie(bez).first)
        #expect(k.postep == nil)
        #expect(k.zostaloBajtow == nil)
        #expect(k.szacowaneSekundy == nil)
    }

    @Test("Ścieżka ze spacją przeżywa parsowanie")
    func spacjeWSciezkach() {
        // Dlatego wiersze są rozdzielone tabulatorem, a nie spacją.
        let ze = "1\t5\tcp\t10\t10\t100\t/mnt/zasoby/Stare Filmy\t/mnt/dysk-kopii/kopia zapasowa"
        let k = try! #require(TransferyParsers.kopie(ze).first)
        #expect(k.zrodlo == "/mnt/zasoby/Stare Filmy")
        #expect(k.cel == "/mnt/dysk-kopii/kopia zapasowa")
        #expect(k.skrot == "Stare Filmy → kopia zapasowa")
    }

    @Test("Ciśnienie I/O bierze ostatnią próbkę, a brak pomiaru to nie zero")
    func cisnienieIO() {
        let zPomiarem = [
            WierszRRD(time: 1, netin: 1, netout: 1, pressureiosome: 8.4),
            WierszRRD(time: 2, netin: 1, netout: 1, pressureiosome: 49.9),
        ]
        #expect(TransferyParsers.obciazenieIO(zPomiarem) == 49.9)

        let bez = [WierszRRD(time: 1, netin: 1, netout: 1, pressureiosome: nil)]
        #expect(TransferyParsers.obciazenieIO(bez) == nil)
    }

    @Test("Próg obciążenia leży w luce między ciszą a kopią")
    func progWLuce() {
        // Zmierzone 2026-09-04: cisza 7–14%, kopia 42–57%. Próg musi leżeć między nimi,
        // inaczej kafel albo przespałby kopię, albo krzyczał przy bezczynnym serwerze.
        #expect(TransferyParsers.progObciazeniaIO > 14)
        #expect(TransferyParsers.progObciazeniaIO < 42)
    }

    /// Od 1.2.44: w oknach od tygodnia szczyt z `cf=MAX`, sumy bajtów dalej ze średnich.
    @Test func szczytZMaksimowSumaZeSrednich() {
        let sr = [WierszRRD(time: 0, netin: 100, netout: 0), WierszRRD(time: 1800, netin: 200, netout: 0)]
        let mx = [WierszRRD(time: 1800, netin: 9_000, netout: 50)]
        let s = TransferyParsers.strumien(zrodlo: "host", kto: "x", rodzaj: .lacze, wiersze: sr, maksima: mx, okno: .week)
        #expect(s.punkty.map(\.szczyt) == [nil, 9_050])
        #expect(s.szczytNaSekunde == 9_050)
        #expect(s.sredniaNaSekunde == 150)
        #expect(s.razemBajtow == Int64(300 * 1800))
        let bez = TransferyParsers.strumien(zrodlo: "host", kto: "x", rodzaj: .lacze, wiersze: sr, okno: .week)
        #expect(bez.szczytNaSekunde == 200)
    }
}
