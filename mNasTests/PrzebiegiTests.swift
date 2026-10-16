import Testing
import Foundation
@testable import mNas

/// Testy warstwy przebiegów — mechanizmów, które się uruchamiają i kończą.
/// Wszystkie wejścia to **zapisane wyjście z serwera testowego**, nie treść wymyślona pod test:
/// log nocnego zadania `vzdump` z 2026-08-19, zapytanie do bazy Uptime Kumy
/// i log skryptu `kopia-laptopa.sh` z tego Maca.
@Suite("Przebiegi: postęp kopii, monitory Kumy, log kopii lokalnej")
struct PrzebiegiTests {

    // MARK: - Postęp vzdump

    @Test("Postęp nocnego zadania liczy się w kontenerach, bo procentów w logu nie ma")
    func postepLiczonyWKontenerach() {
        let p = PrzebiegiParsers.vzdumpPostep(log: FixturesPrzebiegi.vzdumpWTrakcie)
        // Pierwsza linia zadania wymienia osiem gości — stąd mianownik.
        #expect(p.wszystkich == 8)
        // Dwa `Finished Backup of VM` w tym wycinku.
        #expect(p.zrobionych == 2)
        #expect(p.biezacy == 103)
        #expect(p.bylBlad == false)
    }

    @Test("Faza bierze się z ostatniej linii, po polsku")
    func fazaZOstatniejLinii() {
        let p = PrzebiegiParsers.vzdumpPostep(log: FixturesPrzebiegi.vzdumpWTrakcie)
        #expect(p.faza == "pakowanie archiwum")
    }

    @Test("Zakończone zadanie ma komplet, bez bieżącego kontenera")
    func zadanieZakonczone() {
        let p = PrzebiegiParsers.vzdumpPostep(log: FixturesPrzebiegi.vzdumpKoniec)
        #expect(p.wszystkich == 8)
        #expect(p.zrobionych == 8)
        #expect(p.biezacy == nil)
        #expect(p.faza == nil)
    }

    @Test("Przełączniki po liście gości nie są liczone jako goście")
    func przelacznikiNieSaGoscmi() {
        // `--storage backup --mode snapshot --compress zstd` stoi w tej samej linii.
        // Bez przerwania na pierwszym `-` mianownik urósłby o same nazwy opcji.
        let p = PrzebiegiParsers.vzdumpPostep(log: [FixturesPrzebiegi.vzdumpWTrakcie[0]])
        #expect(p.wszystkich == 8)
    }

    @Test("Błąd w logu jest widoczny, zanim zadanie się skończy")
    func bladWLogu() {
        var log = FixturesPrzebiegi.vzdumpWTrakcie
        log.append("ERROR: Backup of VM 104 failed - command 'lxc-freeze' failed")
        let p = PrzebiegiParsers.vzdumpPostep(log: log)
        #expect(p.bylBlad)
    }

    // MARK: - Monitory Uptime Kumy

    @Test("Z bazy Kumy wchodzą wszystkie monitory, ale przebiegami są tylko push")
    func tylkoPushToPrzebieg() {
        let m = PrzebiegiParsers.kumaMonitory(FixturesPrzebiegi.kumaWiersze)
        #expect(m.count == 16)
        let przebiegi = m.filter(\.jestPrzebiegiem)
        // Cztery monitory push: dyski, dwie kopie programów i kopia na HDD.
        // Reszta to czujki stanu (`ping`, `http`, `port`) — nie zadania.
        #expect(przebiegi.count == 4)
        #expect(przebiegi.map(\.id) == [9, 14, 15, 16])
    }

    @Test("Czas heartbeatu jest w UTC — inaczej każda kopia wyglądałaby na dwie godziny starszą")
    func czasWUTC() throws {
        let m = PrzebiegiParsers.kumaMonitory(FixturesPrzebiegi.kumaWiersze)
        let laptop = try #require(m.first { $0.id == 14 })
        let czas = try #require(laptop.czas)
        // W bazie stoi „2026-08-19 21:38:20", a skrypt na Macu zapisał ten sam przebieg
        // o 23:38:20 czasu lokalnego (UTC+2). Zgodność tych dwóch jest całym testem.
        var kalendarz = Calendar(identifier: .gregorian)
        kalendarz.timeZone = try #require(TimeZone(identifier: "UTC"))
        let s = kalendarz.dateComponents([.year, .month, .day, .hour, .minute, .second], from: czas)
        #expect(s.hour == 21)
        #expect(s.minute == 38)
        #expect(s.day == 19)
    }

    @Test("Ułamki sekund w znaczniku czasu nie wywalają odczytu")
    func ulamkiSekund() {
        let m = PrzebiegiParsers.kumaMonitory("1|Host pve|ping|1|1|2026-08-19 23:53:32.573|")
        #expect(m.first?.czas != nil)
    }

    @Test("Monitor push bez sygnału to cisza, nie błąd")
    func padnietyPushToCisza() {
        let m = PrzebiegiParsers.kumaMonitory("14|Kopia - laptop|push|1|0|2026-08-19 21:38:20|brak")
        #expect(m.first?.stan == .cisza)
    }

    @Test("Wyłączony monitor nie udaje, że coś wie")
    func wylaczonyMonitor() {
        let m = PrzebiegiParsers.kumaMonitory("14|Kopia laptopa|push|0|1|2026-08-19 21:38:20|OK")
        #expect(m.first?.stan == .nieznany)
    }

    @Test("Kontener bez bazy Kumy nie daje żadnych monitorów")
    func brakBazy() {
        #expect(PrzebiegiParsers.kumaMonitory("@@BRAK-BAZY").isEmpty)
    }

    // MARK: - Log nocnej kopii na Macu

    @Test("Ostatni wpis to ten z końca, nie pierwszy z brzegu")
    func ostatniWpisKopii() throws {
        let w = try #require(PrzebiegiParsers.ostatniaKopia(log: FixturesPrzebiegi.logKopii))
        #expect(w.stan == .udany)
        #expect(w.opis == "OK: kopia laptop gotowa w 6s")
    }

    @Test("Wyjście rsynca w logu nie jest brane za wpis stanu")
    func smieciZRsynca() throws {
        // Skrypt przekierowuje stdout rsynca do tego samego pliku — te linie nie mają
        // znacznika czasu i muszą zostać pominięte, inaczej ostatnią „kopią" byłaby
        // nazwa przypadkowego pliku.
        let log = FixturesPrzebiegi.logKopii + """

        sending incremental file list
        Xcode programy/mNas - Proxmox/MyApp/AppModel.swift
        """
        let w = try #require(PrzebiegiParsers.ostatniaKopia(log: log))
        #expect(w.opis == "OK: kopia laptop gotowa w 6s")
    }

    @Test("Nieudana kopia jest błędem, nieudany sygnał do Kumy — nie")
    func bladKontraSygnal() throws {
        let blad = try #require(PrzebiegiParsers.ostatniaKopia(
            log: "2026-08-19 03:00:12  BLAD: rsync zakończył się kodem 23 po 41s — Kumie NIE melduję"))
        #expect(blad.stan == .bledny)
        // „UWAGA" znaczy: pliki są na serwerze, nie doszedł tylko sygnał do Kumy.
        // Pokazanie tego jako błędu kopii byłoby nieprawdą.
        let uwaga = try #require(PrzebiegiParsers.ostatniaKopia(
            log: "2026-08-19 03:00:12  UWAGA: kopia się udała, ale nie dowiozłem sygnału do Kumy"))
        #expect(uwaga.stan == .udany)
    }

    // MARK: - Stan ikony w pasku menu

    @Test("Czerwony krzyżyk wygrywa z niebieskim play")
    func bladPrzedPraca() {
        // Gdyby wygrywała praca, awaria chowałaby się za normalnym przebiegiem —
        // dokładnie wtedy, gdy najbardziej trzeba ją zobaczyć.
        let stan = StanPaska(przebiegi: [
            Przebieg(id: "a", nazwa: "Kopia zapasowa", zrodlo: .serwer, stan: .trwa),
            Przebieg(id: "b", nazwa: "Kopia programów", zrodlo: .kuma, stan: .cisza)
        ], polaczony: true)
        #expect(stan.odznaka == .blad)
        #expect(stan.odznaka.symbol == "xmark")
        #expect(stan.trwajacych == 1)
        #expect(stan.alarmow == 1)
    }

    @Test("Trwający przebieg daje niebieski play")
    func trwaToPlay() {
        let stan = StanPaska(przebiegi: [
            Przebieg(id: "a", nazwa: "Kopia zapasowa", zrodlo: .serwer, stan: .trwa)
        ], polaczony: true)
        #expect(stan.odznaka == .praca)
        #expect(stan.odznaka.symbol == "play.fill")
    }

    @Test("Połączony i spokojny to zielony ptaszek")
    func spokojToPtaszek() {
        let stan = StanPaska(przebiegi: [
            Przebieg(id: "a", nazwa: "Kopia zapasowa", zrodlo: .serwer, stan: .udany)
        ], polaczony: true)
        #expect(stan.odznaka == .wporzadku)
        #expect(stan.odznaka.symbol == "checkmark")
    }

    @Test("Brak połączenia to brak ptaszka, nie czerwony krzyżyk")
    func niepolaczonyToBrakOdznaki() {
        // Krzyżyk znaczy „mechanizm padł". Brak połączenia znaczy „nic nie wiem" —
        // pokazanie tego jako awarii byłoby nieprawdą o serwerze.
        let stan = StanPaska(przebiegi: [], polaczony: false)
        #expect(stan.odznaka == .brak)
        #expect(stan.odznaka.symbol == nil)
    }

    @Test("Rozłączony z zapamiętanym błędem nadal pokazuje błąd")
    func rozlaczonyZBledem() {
        // Ostatnia znana nieudana kopia nie przestaje być nieudana dlatego, że
        // straciliśmy połączenie z serwerem.
        let stan = StanPaska(przebiegi: [
            Przebieg(id: "b", nazwa: "Kopia programów", zrodlo: .mak, stan: .bledny)
        ], polaczony: false)
        #expect(stan.odznaka == .blad)
    }

    @Test("Przebieg trwający zbyt długo zapala krzyżyk, nie zmieniając swojego stanu")
    func zaDlugoToBlad() {
        var p = Przebieg(id: "a", nazwa: "Kopia zapasowa", zrodlo: .serwer, stan: .trwa,
                         start: Date().addingTimeInterval(-3 * 3600))
        p.limitSekund = 45 * 60
        #expect(p.przekroczylCzas)
        #expect(p.stan == .trwa)          // nadal trwa — to ostrzeżenie, nie werdykt
        #expect(StanPaska(przebiegi: [p], polaczony: true).odznaka == .blad)
    }

    @Test("Chmurka pokazuje liczbę nieodczytanych i znika przy zerze")
    func chmurkaZLiczba() {
        let bez = StanPaska(przebiegi: [], polaczony: true, nieodczytane: 0)
        #expect(bez.nieodczytane == 0)
        let z = StanPaska(przebiegi: [], polaczony: true, nieodczytane: 3)
        #expect(z.nieodczytane == 3)
        // Od 2026-10-04 poprawna odmiana z katalogu tekstów: 1 nowa, 2–4 nowe, 5+ nowych.
        #expect(z.opis.contains("3 nowe wiadomości"))
        let jedna = StanPaska(przebiegi: [], polaczony: true, nieodczytane: 1)
        #expect(jedna.opis.contains("1 nowa wiadomość"))
    }

    @Test("Chmurka nie zmienia odznaki — to dwie niezależne informacje")
    func chmurkaNieRuszaOdznaki() {
        // „Coś się stało i tego nie widziałeś" to nie to samo co „coś nie działa".
        let stan = StanPaska(przebiegi: [
            Przebieg(id: "a", nazwa: "Kopia zapasowa", zrodlo: .serwer, stan: .udany)
        ], polaczony: true, nieodczytane: 5)
        #expect(stan.odznaka == .wporzadku)
        #expect(stan.nieodczytane == 5)
    }

    @Test("Cisza i błąd alarmują, udany i nieznany nie")
    func ktoreStanyAlarmuja() {
        #expect(Przebieg.Stan.bledny.alarmujacy)
        #expect(Przebieg.Stan.cisza.alarmujacy)
        #expect(!Przebieg.Stan.udany.alarmujacy)
        #expect(!Przebieg.Stan.trwa.alarmujacy)
        #expect(!Przebieg.Stan.nieznany.alarmujacy)
    }
}

/// Zapisane wyjście z serwera testowego i z tego Maca — 2026-08-19/20.
enum FixturesPrzebiegi {

    /// Log nocnego zadania `vzdump`, urwany w trakcie kopiowania trzeciego kontenera.
    static let vzdumpWTrakcie: [String] = [
        "INFO: starting new backup job: vzdump 100 101 103 104 105 106 107 108 --storage backup --mode snapshot --compress zstd",
        "INFO: Starting Backup of VM 100 (lxc)",
        "INFO: Backup started at 2026-08-19 20:06:31",
        "INFO: status = running",
        "INFO: CT Name: tailscale",
        "INFO: including mount point rootfs ('/') in backup",
        "INFO: backup mode: snapshot",
        "INFO: create storage snapshot 'vzdump'",
        "INFO: creating vzdump archive '/mnt/backup/dump/vzdump-lxc-100-2026_08_19-20_06_31.tar.zst'",
        "INFO: Total bytes written: 862330880 (823MiB, 121MiB/s)",
        "INFO: archive file size: 294MB",
        "INFO: prune older backups with retention: keep-daily=7, keep-weekly=4",
        "INFO: pruned 0 backup(s)",
        "INFO: Finished Backup of VM 100 (00:00:07)",
        "INFO: Backup finished at 2026-08-19 20:06:38",
        "INFO: Starting Backup of VM 101 (lxc)",
        "INFO: creating vzdump archive '/mnt/backup/dump/vzdump-lxc-101-2026_08_19-20_06_38.tar.zst'",
        "INFO: Finished Backup of VM 101 (00:00:26)",
        "INFO: Starting Backup of VM 103 (lxc)",
        "INFO: create storage snapshot 'vzdump'",
        "INFO: creating vzdump archive '/mnt/backup/dump/vzdump-lxc-103-2026_08_19-20_07_04.tar.zst'"
    ]

    /// To samo zadanie, dobiegnięte do końca — wszystkie osiem kontenerów.
    static let vzdumpKoniec: [String] = {
        var l = ["INFO: starting new backup job: vzdump 100 101 103 104 105 106 107 108 --storage backup --mode snapshot --compress zstd"]
        for id in [100, 101, 103, 104, 105, 106, 107, 108] {
            l.append("INFO: Starting Backup of VM \(id) (lxc)")
            l.append("INFO: creating vzdump archive '/mnt/backup/dump/vzdump-lxc-\(id).tar.zst'")
            l.append("INFO: Finished Backup of VM \(id) (00:00:07)")
        }
        l.append("INFO: Backup job finished successfully")
        l.append("TASK OK")
        return l
    }()

    /// Wynik zapytania do bazy Uptime Kumy z CT 101, 2026-08-20.
    /// Monitora 11 nie ma celowo — to skasowany AdGuard.
    static let kumaWiersze = """
    1|Host pve|ping|1|1|2026-08-19 23:53:32.573|
    2|Brama — router|ping|1|1|2026-08-19 23:53:33.381|
    3|Internet|ping|1|1|2026-08-19 23:53:33.994|
    4|CT 100 VPN|ping|1|1|2026-08-19 23:53:34.866|
    5|Panel Proxmox|http|1|1|2026-08-19 23:53:35.269|200 - OK
    6|CT 104 Udzial plikow|port|1|1|2026-08-19 23:53:36.159|0 ms
    7|CT 105 Repozytoria git|http|1|1|2026-08-19 23:53:37.122|200 - OK
    8|CT 106 Udzial wspolny|port|1|1|2026-08-19 23:53:37.906|0 ms
    9|Dyski pve — miejsce i SMART|push|1|1|2026-08-19 23:50:01.292|/mnt/zasoby 77%,/mnt/wspolny 1% /mnt/multimedia 5%,/mnt/backup 2%
    10|CT 107 Udzial zdjec|port|1|1|2026-08-19 23:53:39.168|0 ms
    12|CT 103 Panel www|http|1|1|2026-08-19 23:53:40.163|200 - OK
    13|CT 108 Chmura plikow|http|1|1|2026-08-19 23:53:40.478|200 - OK
    14|Kopia - laptop|push|1|1|2026-08-19 21:38:20.792|Kopia laptop OK w 6s
    15|Kopia - komputer|push|1|1|2026-08-19 21:45:57.567|Kopia komputer OK w 40s
    16|Kopia dokumentow na HDD|push|1|1|2026-08-19 19:31:22.472|Dokumenty na HDD: 6.7G w 106s
    17|Nowy monitor bez sygnalu|http|1|-1||
    """

    /// `/proc/meminfo` z serwera testowego, ten sam moment co odczyt z API wyżej.
    static let meminfo = """
    MemTotal:        7960864 kB
    MemFree:          444984 kB
    MemAvailable:    5382952 kB
    Buffers:         1246008 kB
    Cached:          3366236 kB
    Shmem:            128032 kB
    SReclaimable:     769600 kB
    """

    /// `~/Library/Logs/kopia-laptopa.log` z laptopa.
    static let logKopii = """
    2026-08-18 03:00:41  OK: kopia laptop gotowa w 587s
    2026-08-19 23:38:20  OK: kopia laptop gotowa w 6s
    """
}

/// Testy paska postępu i prędkości — dołożonych 2026-08-20 na prośbę
/// („mogę widzieć pasek postępu i prędkość?").
@Suite("Postęp i prędkość kopii")
struct PostepIPredkoscTests {

    @Test("Ścieżka rosnącego archiwum wychodzi z logu")
    func sciezkaArchiwum() {
        let p = PrzebiegiParsers.vzdumpPostep(log: FixturesPrzebiegi.vzdumpWTrakcie)
        #expect(p.sciezkaArchiwum == "/mnt/backup/dump/vzdump-lxc-103-2026_08_19-20_07_04.tar.zst")
    }

    @Test("Prędkość z linii „Total bytes written” czytana wprost")
    func predkoscZTotalBytes() throws {
        let p = PrzebiegiParsers.vzdumpPostep(log: [
            "INFO: starting new backup job: vzdump 100 --storage backup",
            "INFO: Total bytes written: 862330880 (823MiB, 121MiB/s)"
        ])
        let v = try #require(p.predkoscZLogu)
        // 121 MiB/s = 126 877 696 B/s
        #expect(abs(v - 121 * 1_048_576) < 1)
    }

    @Test("Prędkość synchronizacji przeliczana z bajtów i sekund")
    func predkoscZSync() throws {
        let p = PrzebiegiParsers.vzdumpPostep(log: [
            "INFO: starting new backup job: vzdump 105 --storage backup",
            "INFO: first sync finished - transferred 930.28M bytes in 7s"
        ])
        let v = try #require(p.predkoscZLogu)
        let oczekiwane = 930.28 * 1_048_576 / 7
        #expect(abs(v - oczekiwane) < 1)
    }

    @Test("„MiB” nie może zostać zjedzone przez przyrostek „M”")
    func mibPrzedM() throws {
        // Gdyby „M" sprawdzało się przed „MiB", zostałoby „823Mi", `Double` zwróciłby
        // `nil` i prędkość zniknęłaby po cichu — bez błędu i bez pustego miejsca.
        let p = PrzebiegiParsers.vzdumpPostep(log: [
            "INFO: Total bytes written: 1 (823MiB, 10MiB/s)"
        ])
        #expect(p.predkoscZLogu != nil)
    }

    @Test("Zerowy czas synchronizacji nie robi dzielenia przez zero")
    func zeroSekund() {
        let p = PrzebiegiParsers.vzdumpPostep(log: [
            "INFO: final sync finished - transferred 0 bytes in 0s"
        ])
        #expect(p.predkoscZLogu == nil)
    }

    @Test("Trwająca pozycja liczy się jako pół — pasek nie stoi w miejscu")
    func trwajacaPozycjaToPol() throws {
        var p = Przebieg(id: "a", nazwa: "Kopia", zrodlo: .serwer, stan: .trwa)
        p.zrobionych = 3
        p.wszystkich = 8
        let ulamek = try #require(p.postepUlamek)
        #expect(abs(ulamek - 3.5 / 8) < 0.0001)
    }

    @Test("Zakończony przebieg ma pasek pełny, bez doliczania połówki")
    func zakonczonyPelny() throws {
        var p = Przebieg(id: "a", nazwa: "Kopia", zrodlo: .serwer, stan: .udany)
        p.zrobionych = 8
        p.wszystkich = 8
        #expect(try #require(p.postepUlamek) == 1)
    }

    @Test("Pasek nigdy nie przekracza pełni")
    func niePrzekraczaPelni() throws {
        var p = Przebieg(id: "a", nazwa: "Kopia", zrodlo: .serwer, stan: .trwa)
        p.zrobionych = 8
        p.wszystkich = 8
        #expect(try #require(p.postepUlamek) == 1)
    }

    @Test("Bez znanej liczby pozycji nie ma paska, zamiast paska na oko")
    func brakPozycjiBrakPaska() {
        let p = Przebieg(id: "a", nazwa: "Kopia", zrodlo: .serwer, stan: .trwa)
        #expect(p.postepUlamek == nil)
    }
}

/// Osobno, bo to jest pułapka: ścieżka archiwum musi wygasać razem z kontenerem.
@Suite("Ścieżka archiwum wygasa po zakończeniu kontenera")
struct SciezkaArchiwumTests {

    @Test("Skończony kontener nie zostawia ścieżki do mierzenia")
    func skonczonyNieZostawiaSciezki() {
        // Bez tego w fazie synchronizacji następnego kontenera mierzylibyśmy
        // **nieruchomy** plik poprzedniego i meldowali „0 B/s” jako pomiar bieżący.
        let p = PrzebiegiParsers.vzdumpPostep(log: [
            "INFO: starting new backup job: vzdump 104 105 --storage backup",
            "INFO: Starting Backup of VM 104 (lxc)",
            "INFO: creating vzdump archive '/mnt/backup/dump/vzdump-lxc-104.tar.zst'",
            "INFO: Finished Backup of VM 104 (00:00:15)",
            "INFO: Starting Backup of VM 105 (lxc)",
            "INFO: starting first sync /proc/1/root/ to /mnt/backup/dump/vzdump-lxc-105.tmp"
        ])
        #expect(p.sciezkaArchiwum == nil)
        #expect(p.biezacy == 105)
        #expect(p.zrobionych == 1)
        #expect(p.faza == "pierwsza synchronizacja")
    }

    @Test("Kontener w fazie pakowania ma swoją ścieżkę")
    func pakowanyMaSciezke() {
        let p = PrzebiegiParsers.vzdumpPostep(log: [
            "INFO: starting new backup job: vzdump 104 105 --storage backup",
            "INFO: Starting Backup of VM 104 (lxc)",
            "INFO: creating vzdump archive '/mnt/backup/dump/vzdump-lxc-104.tar.zst'",
            "INFO: Finished Backup of VM 104 (00:00:15)",
            "INFO: Starting Backup of VM 105 (lxc)",
            "INFO: creating vzdump archive '/mnt/backup/dump/vzdump-lxc-105.tar.zst'"
        ])
        #expect(p.sciezkaArchiwum == "/mnt/backup/dump/vzdump-lxc-105.tar.zst")
    }
}

/// Historia przebiegów do okna kafla „Przebiegi” (spec 2026-10-04). Wiersze logów zdjęte
/// z serwera testowego tego dnia (kopia PROJEKTY → WD, zadania vzdump do katalogu i do PBS).
@Suite("Przebiegi: historia z zadań i logów")
struct HistoriaPrzebiegowTests {
    @Test func historiaLoguBierzeKazdyOkIBlad() {
        let log = """
        2026-10-04 00:01:38  OK: lustro PROJEKTY -> WD w 102s, na WD 429G
        sent 7,128,416,626 bytes
        2026-10-04 00:02:32  OK: bez zmian — WD nie ruszam
        2026-10-05 06:00:01  BLAD: /mnt/dysk-kopii niezamontowany, montowanie nie wyszlo (dysku brak?)
        2026-10-05 06:00:01  INFO: /mnt/dysk-kopii nie byl zamontowany — zamontowalem
        """
        let w = PrzebiegiParsers.historiaLogu(log, mechanizm: "Kopia PROJEKTY")
        #expect(w.map(\.stan) == [.bledny, .udany, .udany])           // najnowsze pierwsze
        #expect(w.first?.opis?.hasPrefix("BLAD:") == true)
        #expect(w.allSatisfy { $0.mechanizm == "Kopia PROJEKTY" })
        #expect(Set(w.map(\.id)).count == 3)
    }

    @Test func szczegolyVzdumpDlaKatalogu() {
        let log = [
            "INFO: starting new backup job: vzdump 100 104 --mode snapshot --compress zstd --storage backup --quiet 1",
            "INFO: Starting Backup of VM 104 (lxc)",
            "INFO: archive file size: 335MB",
            "INFO: Finished Backup of VM 104 (00:00:13)",
        ]
        let s = PrzebiegiParsers.szczegolyVzdump(log)
        #expect(s.magazyn == "backup")
        #expect(s.goscie == [.init(vmid: 104, czas: "00:00:13", rozmiar: "335MB")])
    }

    @Test func szczegolyVzdumpDlaPBSBezRozmiaru() {
        let log = [
            "INFO: starting new backup job: vzdump 104 --mode snapshot --storage pbs-kopie --notes-template '{{guestname}}'",
            "INFO: Starting Backup of VM 104 (lxc)",
            "INFO: root.ppxar: backup was done incrementally, reused 3.894 MiB (0.5%)",
            "INFO: Finished Backup of VM 104 (00:00:20)",
        ]
        let s = PrzebiegiParsers.szczegolyVzdump(log)
        #expect(s.magazyn == "pbs-kopie")
        #expect(s.goscie == [.init(vmid: 104, czas: "00:00:20", rozmiar: nil)])
    }

    @Test func historiaZadanStanyIKolejnosc() {
        let z = [TaskEntry(upid: "U1", type: "vzdump", id: nil, status: "OK", starttime: 100, endtime: 200),
                 TaskEntry(upid: "U2", type: "vzdump", id: nil, status: "job errors", starttime: 300, endtime: 400),
                 TaskEntry(upid: "U3", type: "vzdump", id: nil, status: nil, starttime: 500, endtime: nil)]
        let w = PrzebiegiParsers.historiaZadan(z)
        #expect(w.map(\.stan) == [.trwa, .bledny, .udany])
        #expect(w.last?.czasTrwania == 100)
        #expect(w.first?.upid == "U3")
    }
}
