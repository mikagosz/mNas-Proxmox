import Testing
import Foundation
@testable import mNas

/// Testy listy mechanizmów hosta — odpowiedź na zgłoszenie z 2026-08-23:
/// *„w przebiegach nadal są rzeczy których już nie ma… wygląda tak jakbyś wpisywał
/// te dane do programu, a nie pobierały informacji prosto z proxmoxa"*.
///
/// Wejście to **zapisane wyjście `ServerCommands.mechanizmyHosta()` z serwera testowego, 2026-08-23**
/// — sprawdzone tego dnia znak w znak przeciw żywemu serwerowi. Najważniejszy test w tym
/// pliku to `wygaszoneZadanieNieIstnieje`: wyłączony wpis w cronie ma zniknąć z listy
/// **bez zmiany w aplikacji**.
@Suite("Mechanizmy hosta: cron, timery i ich dzienniki")
struct MechanizmyHostaTests {

    static let raw = """
    @@CRON
    alarm-dyskow\t# Alarm dyskow pve -> powiadomienie. Opis w dokumentacji.
    alarm-dyskow\tSHELL=/bin/sh
    alarm-dyskow\tPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
    alarm-dyskow\t*/10 * * * * root /usr/local/bin/alarm-dyskow.sh
    e2scrub_all\t30 3 * * 0 root test -e /run/systemd/system || SERVICE_MODE=1 /usr/libexec/e2fsprogs/e2scrub_all_cron
    kopia-konfiguracji-hosta\t# Kopia konfiguracji hosta Proxmox -> /mnt/backup/host. Opis w dokumentacji.
    kopia-konfiguracji-hosta\tSHELL=/bin/sh
    kopia-konfiguracji-hosta\tPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
    kopia-konfiguracji-hosta\t15 2 * * * root /usr/local/bin/kopia-konfiguracji-hosta.sh
    kopia-dokumentow-hdd\tSHELL=/bin/sh
    kopia-dokumentow-hdd\tPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
    kopia-dokumentow-hdd\t# WYLACZONE 2026-08-22 (Etap 5). Zrodlo /mnt/zasoby/Instalki jest ZAMROZONA MIGAWKA
    kopia-dokumentow-hdd\t#30 4 * * * root /usr/local/bin/kopia-dokumentow-na-hdd.sh
    kopia-zdjec\tSHELL=/bin/sh
    kopia-zdjec\tPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
    kopia-zdjec\t# Kopia 1 — folder zdjec na NAS (plaska, bez --delete)
    kopia-zdjec\t45 4 * * * root /usr/local/bin/kopia-zdjec-na-nas.sh
    kopia-zdjec\t# Kopia 2 — migawka dzienna na USB (--link-dest, sito na znaczniku)
    kopia-zdjec\t0 5 * * * root /usr/local/bin/kopia-zdjec-na-usb.sh
    sprzatanie-udzialow\t# Codziennie o 4:00 pilnuje kosza (.Trashes) i zdejmuje blokady (uchg) na udzialach Samby.
    sprzatanie-udzialow\t# Zalozony 2026-08-19, patrz dokumentacja uslug.
    sprzatanie-udzialow\t0 4 * * * root /usr/local/bin/sprzatanie-udzialow.sh 2>&1 | logger -t sprzatanie-udzialow
    vzdump\tPATH="/usr/sbin:/usr/bin:/sbin:/bin"
    @@TIMERY
    pomiar-ruchu.service\tProbka pomiaru ruchu co 10 s\t/usr/local/bin/pomiar-ruchu.sh\t
    kontrola-udzialow.service\tSprawdzanie udzialow co minute\t/usr/local/bin/kontrola-udzialow.sh\t
    @@LOGI
    ### /usr/local/bin/kopia-zdjec-na-nas.sh /var/log/kopia-zdjec-nas.log

    sent 4,389,419 bytes  received 19,515 bytes  1,763,573.60 bytes/sec
    total size is 8,417,683,282  speedup is 1,909.23
    2026-08-23 04:45:06  OK: 8.2G, 114056 plikow na media w 2s
    2026-08-23 04:45:07  UWAGA: brak URL do Kumy — kopia zrobiona, ale NIKT tego nie pilnuje
    ### /usr/local/bin/kopia-zdjec-na-usb.sh /var/log/kopia-zdjec-usb.log
    Total bytes received: 19,503

    sent 4,389,404 bytes  received 19,503 bytes  801,619.45 bytes/sec
    total size is 8,417,683,282  speedup is 1,909.24
    2026-08-23 05:00:10  OK: migawka 2026-08-23 (dowiazania do 2026-08-22), 8.2G w 5s; migawek 2, archiwum 8.3G, skasowano 0
    """

    private func mechanizmy() -> [PrzebiegiParsers.MechanizmHosta] {
        PrzebiegiParsers.mechanizmyHosta(Self.raw)
    }

    private func przebiegi() -> [PrzebiegiParsers.MechanizmHosta] {
        mechanizmy().filter { !$0.czujka }
    }

    // MARK: - Sedno zgłoszenia

    /// 🔴 To jest sprawdzian z notatki: zadanie zdjęte z crona ma zniknąć z listy
    /// **bez dotykania kodu aplikacji**. Wpis `kopia-dokumentow-hdd` został wyłączony
    /// 2026-08-22 przy zmianie sposobu kopii i jest w pliku tylko jako komentarz.
    @Test("Wygaszone zadanie nie istnieje na liście")
    func wygaszoneZadanieNieIstnieje() {
        #expect(!mechanizmy().contains { $0.skrypt.contains("kopia-dokumentow-na-hdd") })
    }

    @Test("Zadania spoza /usr/local/bin nie wchodzą — to nie są mechanizmy użytkownika")
    func tylkoWlasneSkrypty() {
        #expect(mechanizmy().allSatisfy { $0.skrypt.hasPrefix("/usr/local/bin/") })
        #expect(!mechanizmy().contains { $0.skrypt.contains("e2scrub") })
    }

    // MARK: - Podział na przebiegi i czujki

    @Test("Czujka tykająca co 10 minut nie jest przebiegiem")
    func czujkaDyskowToNiePrzebieg() {
        let czujka = mechanizmy().first { $0.skrypt.hasSuffix("alarm-dyskow.sh") }
        #expect(czujka?.czujka == true)
        #expect(!przebiegi().contains { $0.skrypt.hasSuffix("alarm-dyskow.sh") })
    }

    /// Timer bez `OnCalendar` tyka w kółko (`OnUnitActiveUSec=10s`) — czujka, nie zadanie.
    @Test("Timer monotoniczny jest czujką, nie przebiegiem")
    func timerMonotonicznyToCzujka() {
        // 🔴 `allSatisfy(\.czujka)` **w środku `#expect` się nie kompiluje** — makro
        // rozbiera wywołanie i trafia w `rethrows` („call can throw, but it is not marked
        // with 'try'"). Ta sama funkcja z domknięciem przechodzi. Zmierzone 2026-08-23.
        let timery = mechanizmy().filter { $0.skad.hasPrefix("timer:") }
        #expect(!timery.isEmpty)
        #expect(timery.allSatisfy { $0.czujka })
        #expect(przebiegi().allSatisfy { $0.skad.hasPrefix("cron:") })
    }

    @Test("Na liście przebiegów zostają cztery zadania dobowe")
    func czteryZadaniaDobowe() {
        #expect(Set(przebiegi().map(\.skrypt)) == [
            "/usr/local/bin/kopia-konfiguracji-hosta.sh",
            "/usr/local/bin/kopia-zdjec-na-nas.sh",
            "/usr/local/bin/kopia-zdjec-na-usb.sh",
            "/usr/local/bin/sprzatanie-udzialow.sh"
        ])
    }

    @Test("Zadanie tygodniowe też jest przebiegiem, nie czujką")
    func zadanieTygodnioweToPrzebieg() {
        #expect(PrzebiegiParsers.czyCzujka("30 3 * * 0") == false)
        #expect(PrzebiegiParsers.czyCzujka("*/10 * * * *") == true)
        #expect(PrzebiegiParsers.czyCzujka("* * * * *") == true)
    }

    // MARK: - Nazwy

    @Test("Komentarz nad zadaniem jest jego nazwą — dwa zadania w jednym pliku, dwie nazwy")
    func komentarzNadZadaniemJestNazwa() {
        let media = przebiegi().first { $0.skrypt.hasSuffix("kopia-zdjec-na-nas.sh") }
        let talerz = przebiegi().first { $0.skrypt.hasSuffix("kopia-zdjec-na-usb.sh") }
        #expect(media?.nazwa == "Kopia 1 — folder zdjec na NAS (plaska, bez --delete)")
        #expect(talerz?.nazwa == "Kopia 2 — migawka dzienna na USB (--link-dest, sito na znaczniku)")
    }

    /// Blok komentarza kończy się na `SHELL=`/`PATH=`, więc nagłówek pliku nie udaje
    /// opisu zadania — nazwa spada wtedy na nazwę skryptu.
    @Test("Komentarz z nagłówka pliku nie jest nazwą zadania")
    func naglowekPlikuNieJestNazwa() {
        let konfig = przebiegi().first { $0.skrypt.hasSuffix("kopia-konfiguracji-hosta.sh") }
        #expect(konfig?.nazwa == "Kopia konfiguracji hosta")
    }

    @Test("Z bloku dwóch komentarzy bierzemy pierwszy — ten, który mówi co robi")
    func pierwszyKomentarzZBloku() {
        let kosz = przebiegi().first { $0.skrypt.hasSuffix("sprzatanie-udzialow.sh") }
        #expect(kosz?.nazwa == "Codziennie o 4:00 pilnuje kosza (.Trashes) i zdejmuje blokady (uchg) na udzialach Samby")
    }

    @Test("Cięcie komentarza po „. ”, nie po samej kropce")
    func opisZKomentarzaNieUrywaNaKropce() {
        #expect(PrzebiegiParsers.opisZKomentarza("# Alarm dyskow pve -> powiadomienie. Opis w dokumentacji.")
                == "Alarm dyskow pve")
        // `(.Trashes)` ma kropkę bez spacji — zdanie nie może się tu urwać.
        #expect(PrzebiegiParsers.opisZKomentarza("# Pilnuje kosza (.Trashes) i blokad.")
                == "Pilnuje kosza (.Trashes) i blokad")
    }

    @Test("Nazwa ze skryptu, gdy komentarza nie ma")
    func nazwaZeSkryptu() {
        #expect(PrzebiegiParsers.nazwaZeSkryptu("/usr/local/bin/kopia-zdjec-na-nas.sh")
                == "Kopia zdjec na nas")
    }

    // MARK: - Harmonogram

    @Test("Wyrażenie cron po ludzku")
    func harmonogramPoLudzku() {
        #expect(PrzebiegiParsers.harmonogramPoLudzku("45 4 * * *") == "codziennie 04:45")
        #expect(PrzebiegiParsers.harmonogramPoLudzku("0 5 * * *") == "codziennie 05:00")
        #expect(PrzebiegiParsers.harmonogramPoLudzku("*/10 * * * *") == "co 10 minut")
        #expect(PrzebiegiParsers.harmonogramPoLudzku("*/1 * * * *") == "co 1 minutę")
        #expect(PrzebiegiParsers.harmonogramPoLudzku("*/2 * * * *") == "co 2 minuty")
        // Nierozpoznany kształt wraca surowy — zły przekład jest gorszy niż gwiazdki.
        #expect(PrzebiegiParsers.harmonogramPoLudzku("30 3 * * 0") == "30 3 * * 0")
    }

    @Test("Kalendarz systemd po ludzku")
    func kalendarzPoLudzku() {
        #expect(PrzebiegiParsers.kalendarzPoLudzku("{ OnCalendar=*-*-* 00:00:00 ; next_elapse=Mon 2026-08-24 }")
                == "codziennie 00:00")
    }

    // MARK: - Dzienniki

    @Test("Ostatni wpis dziennika trafia do mechanizmu, razem z czasem")
    func dziennikTrafiaDoMechanizmu() {
        let talerz = przebiegi().first { $0.skrypt.hasSuffix("kopia-zdjec-na-usb.sh") }
        #expect(talerz?.ostatni?.stan == .udany)
        #expect(talerz?.ostatni?.opis.hasPrefix("OK: migawka 2026-08-23") == true)

        var kalendarz = Calendar(identifier: .gregorian)
        kalendarz.timeZone = .current
        let skladniki = kalendarz.dateComponents([.year, .month, .day, .hour, .minute],
                                                 from: talerz?.ostatni?.czas ?? .distantPast)
        #expect(skladniki.day == 23 && skladniki.hour == 5 && skladniki.minute == 0)
    }

    /// `UWAGA:` znaczy „kopia się udała, nie doszedł tylko sygnał do Kumy" — to nie jest
    /// błąd kopii i nie ma malować wiersza na czerwono.
    @Test("Wpis UWAGA liczy się jako udany, bo kopia przeszła")
    func uwagaToNieBlad() {
        let media = przebiegi().first { $0.skrypt.hasSuffix("kopia-zdjec-na-nas.sh") }
        #expect(media?.ostatni?.stan == .udany)
        #expect(media?.ostatni?.opis.hasPrefix("UWAGA:") == true)
    }

    @Test("Mechanizm bez własnego dziennika nie udaje, że mu się udało")
    func brakDziennikaToNieZielen() {
        let konfig = przebiegi().first { $0.skrypt.hasSuffix("kopia-konfiguracji-hosta.sh") }
        #expect(konfig?.ostatni == nil)
    }

    @Test("Puste wyjście nie wywraca parsera")
    func pusteWyjscie() {
        #expect(PrzebiegiParsers.mechanizmyHosta("").isEmpty)
        #expect(PrzebiegiParsers.mechanizmyHosta("@@CRON\n@@TIMERY\n@@LOGI").isEmpty)
    }
}
