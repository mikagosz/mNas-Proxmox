import Testing
import Foundation
@testable import mNas

/// Testy kafla „Miejsce".
///
/// Wszystkie wejścia to **zapisane wyjście z serwera testowego z 2026-08-23**: `/etc/pve/storage.cfg`,
/// wpisy `mp0:` z `/etc/pve/lxc/*.conf`, `grep` po `smb.conf` w trzech kontenerach Samby
/// i `df -B1 -P`. Nic tu nie jest wymyślone pod test — chodzi właśnie o to, żeby program
/// przestał pokazywać zdanie sklejone na serwerze i zaczął liczyć z wartości.
@Suite("Miejsce: nazwy udziałów i magazynów, zajętość liczona jak df")
struct MiejsceTests {

    // MARK: - Zapisane wyjście serwera

    static let nazwyRaw = """
    @@STORAGE
    dir: local
    \tpath /var/lib/vz
    \tcontent iso,vztmpl,import,backup

    lvmthin: local-lvm
    \tthinpool data
    \tvgname pve
    \tcontent images,rootdir

    dir: aplikacje
    \tpath /mnt/aplikacje
    \tcontent rootdir,images
    \tis_mountpoint yes

    dir: multimedia
    \tpath /mnt/multimedia
    \tcontent iso,vztmpl,rootdir,snippets,images,backup

    dir: backup
    \tpath /mnt/backup
    \tcontent backup
    \tis_mountpoint /mnt/backup
    \tprune-backups keep-daily=7,keep-weekly=4

    @@BIND
    104 /mnt/zasoby /mnt/zasoby
    105 /mnt/aplikacje/git /mnt/git
    106 /mnt/wspolny /mnt/wspolny
    107 /mnt/zdjecia /mnt/zdjecia
    109 /mnt/zasoby/Wspolne /mnt/zasoby/Wspolne
    @@SMB
    CT 100
    CT 101
    CT 103
    CT 104
    [global]
    [Pliki]
       path = /mnt/zasoby
    CT 105
    CT 106
    [global]
    [Wspolny]
       path = /mnt/wspolny
    CT 107
    [global]
    [Zdjecia Rodzinne]
       path = /mnt/zdjecia
    CT 108
    CT 109
    """

    /// `df -B1 -P` bez nagłówka — dokładnie to, co przychodzi w sekcji `@@DF`.
    static let dfRaw = """
    udev                  11205709824            0  11205709824       0% /dev
    tmpfs                  2502561792      2678784   2499883008       1% /run
    /dev/mapper/pve-root  89615622144  10578219008  74611007488      13% /
    /dev/nvme1n1p2         1071628288      9461760   1062166528       1% /boot/efi
    /dev/nvme0n1p1       983352680448 754597265408 221738639360      78% /mnt/zasoby
    /dev/nvme2n1p2       250899361792  24888721408 223433314304      11% /mnt/multimedia
    /dev/sdb1            244995190784 102907899904 139569934336      43% /mnt/zdjecia
    /dev/sdc1            235151441920     26570752 232707530752       1% /mnt/aplikacje
    /dev/sda1            210241560576  17765814272 192458969088       9% /mnt/backup
    /dev/sda2            771976777728  20880515072 751079485440       3% /mnt/archiwum
    /dev/fuse               134217728        28672    134189056       1% /etc/pve
    /dev/nvme2n1p1       250898313216   2724601856 245596397568       2% /mnt/wspolny
    """

    private func wiersze() -> [Udzial] {
        Miejsce.udzialy(nazwy: Miejsce.nazwy(Self.nazwyRaw), df: Self.dfRaw)
    }

    // MARK: - Nazwy

    @Test("Udział Samby daje nazwę widoczną w Finderze, nie ścieżkę montowania")
    func nazwyUdzialow() {
        let n = Miejsce.nazwy(Self.nazwyRaw)
        #expect(n["/mnt/zasoby"] == NazwaMontowania(nazwa: "Pliki", rodzaj: .udzial))
        #expect(n["/mnt/wspolny"] == NazwaMontowania(nazwa: "Wspolny", rodzaj: .udzial))
        // Nazwa udziału bywa ze spacją — brany jest cały nawias, nie pierwsze słowo.
        #expect(n["/mnt/zdjecia"] == NazwaMontowania(nazwa: "Zdjecia Rodzinne", rodzaj: .udzial))
    }

    @Test("Magazyn Proxmoksa daje nazwę z storage.cfg")
    func nazwyMagazynow() {
        let n = Miejsce.nazwy(Self.nazwyRaw)
        #expect(n["/mnt/multimedia"] == NazwaMontowania(nazwa: "multimedia", rodzaj: .magazyn))
        #expect(n["/mnt/backup"] == NazwaMontowania(nazwa: "backup", rodzaj: .magazyn))
        #expect(n["/mnt/aplikacje"] == NazwaMontowania(nazwa: "aplikacje", rodzaj: .magazyn))
        // `local` też jest magazynem, choć leży poza /mnt — mapa go zna, kafel odsieje.
        #expect(n["/var/lib/vz"]?.nazwa == "local")
    }

    @Test("[global] nie jest udziałem")
    func globalNieJestUdzialem() {
        let n = Miejsce.nazwy(Self.nazwyRaw)
        #expect(!n.values.contains { $0.nazwa.lowercased() == "global" })
    }

    @Test("Magazyn bez punktu montowania (lvmthin) nie wchodzi do mapy")
    func lvmthinBezSciezki() {
        let n = Miejsce.nazwy(Self.nazwyRaw)
        #expect(!n.values.contains { $0.nazwa == "local-lvm" })
    }

    /// 🔴 Dwie połówki jednego dysku (udział sieciowy i magazyn Proxmoksa) nazywają się
    /// prawie tak samo. Rodzaj jest jedyną rzeczą, która je w kaflu rozróżnia.
    @Test("Dwie połówki udziału „media” różnią się rodzajem, nie tylko wielkością litery")
    func dwiePolowkiMediow() {
        let n = Miejsce.nazwy(Self.nazwyRaw)
        #expect(n["/mnt/wspolny"]?.rodzaj == .udzial)
        #expect(n["/mnt/multimedia"]?.rodzaj == .magazyn)
        #expect(n["/mnt/wspolny"]?.nazwa != n["/mnt/multimedia"]?.nazwa)
    }

    @Test("Katalog, którego nikt nie nazwał, dostaje ostatni człon ścieżki")
    func katalogBezNazwy() {
        let u = wiersze().first { $0.sciezka == "/mnt/archiwum" }
        #expect(u?.nazwa == "archiwum")
        #expect(u?.rodzaj == .katalog)
    }

    // MARK: - Zakres

    @Test("Do kafla wchodzi tylko to, co siedzi pod /mnt")
    func tylkoMnt() {
        let sciezki = wiersze().map(\.sciezka)
        #expect(sciezki.count == 7)
        #expect(!sciezki.contains("/"))
        #expect(!sciezki.contains("/boot/efi"))
        #expect(!sciezki.contains("/etc/pve"))
        #expect(!sciezki.contains("/dev"))
    }

    // MARK: - Procenty

    /// 🔴 Kontrola przeciw rozjazdowi z serwerem. `df` zaokrągla **w górę**; przy zwykłym
    /// zaokrągleniu `/mnt/zasoby` wychodziłby 77% wobec 78% w `df` i w panelu Proxmoksa.
    @Test("Każdy procent zgadza się co do jednego z kolumną Capacity z df")
    func procentyJakWDf() {
        let oczekiwane = ["/mnt/zasoby": 78, "/mnt/multimedia": 11, "/mnt/zdjecia": 43,
                          "/mnt/aplikacje": 1, "/mnt/backup": 9, "/mnt/archiwum": 3,
                          "/mnt/wspolny": 2]
        for u in wiersze() {
            #expect(u.procent == oczekiwane[u.sciezka], "\(u.sciezka): \(u.procent)%")
        }
    }

    @Test("Zajęte i całość idą w bajtach, nie w procentach")
    func bajtyNieProcenty() {
        let dane = wiersze().first { $0.sciezka == "/mnt/zasoby" }
        #expect(dane?.zajete == 754_597_265_408)
        // Całość to zajęte + dostępne, nie rozmiar systemu plików (983 352 680 448).
        //
        // 🔴 Suma stoi w osobnej stałej z jawnym `Int64` **celowo**. Wpisana wprost
        // w `#expect` (`... == 754_597_265_408 + 221_738_639_360`) daje `false`, mimo że
        // makro drukuje po obu stronach tę samą liczbę: literały po prawej biorą typ
        // `Int`, lewa jest `Int64?` i porównanie idzie między różnymi typami.
        // Zmierzone 2026-08-23.
        let calosc: Int64 = 754_597_265_408 + 221_738_639_360
        #expect(dane?.calosc == calosc)
        #expect(dane?.wolne == 221_738_639_360)
    }

    @Test("Próg zajętości jest ten sam co w czujce na serwerze")
    func progZgodnyZCzujka() {
        // `PROG_PROCENT=90` w /usr/local/bin/alarm-dyskow.sh
        #expect(Miejsce.progZajetosci == 90)
        #expect(wiersze().allSatisfy { !$0.przekroczylProg })   // pve 2026-08-23: nic nie krzyczy
    }

    @Test("Pusty df nie wywraca parsera")
    func pustyDf() {
        #expect(Miejsce.udzialy(nazwy: Miejsce.nazwy(Self.nazwyRaw), df: "").isEmpty)
    }

    @Test("Bez mapy nazw wiersze i tak powstają — lepiej ścieżka niż nic")
    func brakNazwNieGasiKafla() {
        let bez = Miejsce.udzialy(nazwy: [:], df: Self.dfRaw)
        #expect(bez.count == 7)
        #expect(bez.allSatisfy { $0.rodzaj == .katalog })
    }

    // MARK: - Kolejność

    @Test("Najpełniejszy stoi pierwszy — kafel odpowiada, gdzie kończy się miejsce")
    func najpelniejszyNaGorze() {
        let lista = wiersze()
        #expect(lista.first?.sciezka == "/mnt/zasoby")
        #expect(lista.first?.procent == 78)
        #expect(lista.last?.procent == 1)
    }

    // MARK: - Odsiew spisu miejsca z podpisu przebiegu

    /// Dokładnie ta wiadomość, którą użytkownik zobaczył 2026-08-23 o 11:57.
    @Test("Spis procentów z czujki znika z podpisu przebiegu")
    func spisMiejscaOdsiany() {
        let msg = "/mnt/zasoby 78%,/mnt/wspolny 2% /mnt/multimedia 11%,/mnt/backup 9%"
        #expect(PrzebiegiParsers.opisJestSpisemMiejsca(msg))
    }

    /// 🔴 Kontrola dodatnia w drugą stronę: prawdziwa treść ma **zostać**.
    /// Zmierzone w bazie Kumy 2026-08-23, monitor „Kopia dokumentow na HDD".
    @Test("Wiadomość z treścią zostaje na miejscu")
    func trescNieJestSpisem() {
        #expect(!PrzebiegiParsers.opisJestSpisemMiejsca("Sync na talerz: migawka 2026-08-23, 8.2G w 5s, migawek 2"))
        #expect(!PrzebiegiParsers.opisJestSpisemMiejsca("No heartbeat in the time window"))
        #expect(!PrzebiegiParsers.opisJestSpisemMiejsca(""))
    }

    @Test("Lista problemów z czujki nie jest spisem miejsca — ma zostać widoczna")
    func listaProblemowZostaje() {
        let msg = "/mnt/backup zajety w 91%\n/dev/nvme2n1 SMART nie zdal"
        #expect(!PrzebiegiParsers.opisJestSpisemMiejsca(msg))
    }
}
