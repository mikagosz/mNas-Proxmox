import Testing
import Foundation
import SwiftUI
@testable import mNas

/// Aktualizacje serwera przez `pve-update-check` (od 1.2.30): odczyt plików stanu,
/// walidacja tego, co idzie do komend, i zgodność wersji zasobów.
@Suite("Aktualizacje serwera: pve-update-check")
struct AktualizacjeSerweraTests {

    /// Skrót prawdziwego odczytu z serwera (2026-10-16) — host i CT 108 z Nextcloudem.
    static let odczyt = #"""
    @@WERSJA pve-update-check 2.7
    @@STAN
    {
       "format" : 1,
       "host" : "pve",
       "maszyny" : [
          { "aplikacje" : 0, "bezpieczenstwo" : 1, "bledy" : [], "etykieta" : "Host pve", "id" : "host",
            "lista_pakietow" : [ { "bezpieczenstwo" : true, "na" : "2.9.0-1~deb13u1", "nazwa" : "libexpat1", "z" : "2.8.3-1~deb13u1" } ],
            "nextcloud_serwer" : false, "nowe_wersje" : [], "pakiety" : 1, "restart" : false,
            "sprawdzono" : "2026-10-16T09:26:04+02:00", "system" : "Debian GNU/Linux 13 (trixie)", "typ" : "host", "wolne_mb" : 70000 },
          { "aplikacje" : 1, "bezpieczenstwo" : 3, "bledy" : [ "mało miejsca na dysku: 285 MB wolne" ], "etykieta" : "CT 108 nextcloud", "id" : "108",
            "lista_pakietow" : [ { "bezpieczenstwo" : true, "na" : "8.14.1-2+deb13u7", "nazwa" : "curl", "z" : "8.14.1-2+deb13u5" } ],
            "nextcloud_serwer" : true,
            "nowe_wersje" : [ "Nextcloud: Nextcloud 34.0.5 is available. Get more information on how to update at https://docs.nextcloud.com/server/34/admin_manual/maintenance/upgrade.html.",
                              "Nextcloud: Update for calendar to version 5.5.2 is available." ],
            "pakiety" : 3, "restart" : false, "sprawdzono" : "2026-10-16T09:26:04+02:00",
            "system" : "Debian GNU/Linux 13 (trixie)", "typ" : "ct", "wolne_mb" : 285 },
          { "aplikacje" : 0, "bezpieczenstwo" : 0, "bledy" : [], "etykieta" : "CT 100 tailscale", "id" : "100",
            "lista_pakietow" : [], "nextcloud_serwer" : false, "nowe_wersje" : [], "pakiety" : 0, "restart" : false,
            "sprawdzono" : "2026-10-16T09:26:04+02:00", "system" : "Debian", "typ" : "ct", "wolne_mb" : null }
       ],
       "sprawdzono" : "2026-10-16T09:26:04+02:00",
       "wersja" : "2.2"
    }
    @@POSTEP
    {
       "etap" : "CT 108 nextcloud: pakiety (2/3)", "koniec" : null,
       "log" : "/var/log/pve-update-check/aktualizacja-20261016-101203.log",
       "maszyna" : "108", "pid" : 4242, "podsumowanie" : null, "postep" : 41, "stan" : "trwa",
       "start" : "2026-10-16T10:12:03+02:00", "wyniki" : [], "zakres" : "wszystko"
    }
    @@KONIEC
    @@JEDNOSTKA active
    @@LOG
    Unpacking curl (8.14.1-2+deb13u7) over (8.14.1-2+deb13u5) ...
    Setting up curl (8.14.1-2+deb13u7) ...
    """#

    @Test("Odczyt: wersja, maszyny, postęp, jednostka i koniec logu")
    func odczytPelny() throws {
        let o = AktualizacjeParsers.odczyt(Self.odczyt)
        #expect(o.narzedzie == .staraWersja("2.7"))   // na serwerze 2.7, mNas od 1.2.36 wiezie 2.8
        let stan = try #require(o.stan)
        #expect(stan.maszyny.count == 3)
        #expect(stan.doAktualizacji.map(\.id) == ["host", "108"])
        let nc = try #require(stan.maszyny.first { $0.id == "108" })
        #expect(nc.nextcloudSerwer && nc.wolneMb == 285 && nc.bezpieczenstwo == 3)
        #expect(nc.noweWersjeKrotko.count == 2)
        #expect(nc.noweWersjeKrotko[0].contains("34.0.5"))
        #expect(nc.noweWersjeKrotko[1].contains("calendar 5.5.2"))
        #expect(stan.maszyny.first { $0.id == "100" }?.wolneMb == nil)
        let p = try #require(o.postep)
        #expect(p.trwa && p.postep == 41 && abs(p.ulamek - 0.41) < 0.001)
        #expect(o.zajete && !o.sprawdzaTeraz)
        #expect(o.ogonLogu.count == 2 && o.ogonLogu[1].hasPrefix("Setting up curl"))
    }

    /// Prawdziwy stan serwera po zawieszonej aktualizacji hosta (2026-10-16 20:24): „trwa”,
    /// a procesu 1032336 już nie było — mNas pokazywał pasek 61% bez końca.
    static let trwaMartwy = #"""
    @@WERSJA pve-update-check 2.7
    @@STAN
    @@BRAK
    @@POSTEP
    {
       "etap" : "Host pve: pakiety (1/1)",
       "koniec" : null,
       "log" : "/var/log/pve-update-check/aktualizacja-20261016-202436.log",
       "maszyna" : "host",
       "pid" : 1032336,
       "podsumowanie" : null,
       "postep" : 61,
       "stan" : "trwa",
       "start" : "2026-10-16T20:24:36+02:00",
       "wyniki" : [],
       "zakres" : "wszystko"
    }
    @@KONIEC
    @@MARTWY
    @@LOG
    Unpacking linux-libc-dev (6.12.113-1) over (6.12.111-1) ...
    Setting up linux-libc-dev (6.12.113-1) ...
    """#

    @Test("„trwa” z martwym pid = przerwana aktualizacja z logiem, nie pasek bez końca")
    func trwaZMartwymPid() throws {
        let o = AktualizacjeParsers.odczyt(Self.trwaMartwy)
        let p = try #require(o.postep)
        #expect(p.przerwana && p.przerwanaBezWyniku && !p.trwa)
        #expect(p.log == "/var/log/pve-update-check/aktualizacja-20261016-202436.log")
        #expect(o.ogonLogu.last?.hasPrefix("Setting up linux-libc-dev") == true)   // @@MARTWY nie zjada sekcji logu
        // bez @@MARTWY to dalej trwająca aktualizacja
        let zywy = AktualizacjeParsers.odczyt(Self.trwaMartwy.replacingOccurrences(of: "@@MARTWY\n", with: ""))
        #expect(zywy.postep?.trwa == true)
        // @@MARTWY przy zakończonym wyniku niczego nie zmienia
        let ok = AktualizacjeParsers.odczyt(Self.trwaMartwy.replacingOccurrences(of: #""stan" : "trwa""#, with: #""stan" : "ok""#))
        #expect(ok.postep?.stan == "ok")
    }

    @Test("Przerwanie złapane przez narzędzie (2.8): stan „przerwana” z końcem")
    func przerwanaZNarzedzia() throws {
        let json = #"{"stan":"przerwana","zakres":"wszystko","start":"2026-10-16T20:24:36+02:00","koniec":"2026-10-16T20:40:00+02:00","podsumowanie":"Przerwane: sygnał SIGINT. Wynik niepełny – sprawdź log: /var/log/pve-update-check/aktualizacja-20261016-202436.log","wyniki":[],"log":"/var/log/pve-update-check/aktualizacja-20261016-202436.log","postep":100}"#
        let p = try JSONDecoder().decode(PostepAktualizacji.self, from: Data(json.utf8))
        #expect(p.przerwana && !p.przerwanaBezWyniku && !p.trwa)
    }

    @Test("Odczyt pyta serwer, czy proces z pid żyje i jest narzędziem")
    func odczytSprawdzaPid() {
        let c = ServerCommands.poleceniOdczytuAktualizacji()
        #expect(c.contains("kill -0 \"$pid\"") && c.contains("@@MARTWY"))
        #expect(c.contains("grep -qF /usr/local/bin/pve-update-check"))
    }

    @Test("Skrypt: apt bez dostępu do tty i zapis wyniku przy przerwaniu")
    func skryptBezTty() {
        let u = NarzedzieAktualizacji.zasob("puc-upgrade.sh")
        #expect(u.contains(#"host) timeout "$UPGRADE_TIMEOUT" sh -c "$script" </dev/null 2>&1 ;;"#))
        #expect(u.contains(#"pct exec "$id" -- sh -c "$script" </dev/null 2>&1 ;;"#))
        #expect(u.contains("trap 'up_przerwij EXIT $?' EXIT") && u.contains("up_state przerwana"))
    }

    @Test("Nowa wersja główna Nextclouda: maszyna aktualna, kropka niebieska")
    func wersjaGlowna() throws {
        let json = #"{"typ":"ct","id":"108","etykieta":"CT 108 nextcloud","pakiety":0,"bezpieczenstwo":0,"aplikacje":1,"nowe_wersje":["Nextcloud: Nextcloud 35.0.2 is available. Get more information on how to update at https://docs.nextcloud.com/server/35/admin_manual/maintenance/upgrade.html."],"nextcloud_serwer":true,"restart":false,"bledy":[],"nextcloud_zainstalowany":"34.0.5","nextcloud_glowna":true}"#
        let m = try JSONDecoder().decode(MaszynaAktualizacji.self, from: Data(json.utf8))
        #expect(m.tylkoWersjaGlowna && m.pilnosc == .wersjaGlowna)
        #expect(m.noweWersjeKrotko == ["nowa wersja główna Nextcloud 35.0.2"])
        #expect(OknoAktualizacji.kolor(m) == .blue)
        var zPakietami = m; zPakietami.pakiety = 2
        #expect(zPakietami.pilnosc == .aktualizacje && OknoAktualizacji.kolor(zPakietami) == .yellow)
        var bezp = zPakietami; bezp.bezpieczenstwo = 1
        #expect(bezp.pilnosc == .pilne)
        var lataNaLinii = m; lataNaLinii.nextcloudGlowna = false
        #expect(lataNaLinii.pilnosc == .aktualizacje)
        // stan z narzędzia 2.3 — bez nowych pól, zachowanie jak dotąd
        let stary = json.replacingOccurrences(of: #","nextcloud_zainstalowany":"34.0.5","nextcloud_glowna":true"#, with: "")
        #expect(try JSONDecoder().decode(MaszynaAktualizacji.self, from: Data(stary.utf8)).pilnosc == .aktualizacje)
    }

    @Test("Usługi ze starymi bibliotekami: pojedynczo albo cały kontener")
    func restart() throws {
        let json = #"{"typ":"ct","id":"108","etykieta":"CT 108 nextcloud","pakiety":0,"bezpieczenstwo":0,"aplikacje":0,"nowe_wersje":[],"nextcloud_serwer":false,"restart":false,"bledy":[],"uslugi_do_restartu":["apache2.service","dbus.service"]}"#
        let m = try JSONDecoder().decode(MaszynaAktualizacji.self, from: Data(json.utf8))
        #expect(m.uslugiPojedynczo == ["apache2.service"])
        #expect(m.wymagaRestartuKontenera && m.wymagaRestartu && m.pilnosc == .aktualizacje)
        var tylkoDbus = m; tylkoDbus.uslugiDoRestartu = ["dbus.service"]
        #expect(tylkoDbus.uslugiPojedynczo.isEmpty && tylkoDbus.wymagaRestartuKontenera)
        var nic = m; nic.uslugiDoRestartu = []
        #expect(!nic.wymagaRestartu && nic.pilnosc == .aktualne)
        let s = StanAktualizacji(format: 1, wersja: "2.5", host: "x", sprawdzono: "", maszyny: [m, nic])
        #expect(s.doAktualizacji.map(\.id) == ["108"])
        #expect(ServerCommands.poleceniRestartu(id: "108", calyKontener: false)?.contains("-R 108 -y") == true)
        #expect(ServerCommands.poleceniRestartu(id: "108", calyKontener: true)?.contains("-B 108 -y") == true)
        #expect(ServerCommands.poleceniRestartu(id: "108;reboot", calyKontener: true) == nil)
    }

    @Test("Host: nowe jądro i gotowość DKMS")
    func jadroHosta() throws {
        let json = #"{"typ":"host","id":"host","etykieta":"Host pve","pakiety":0,"bezpieczenstwo":0,"aplikacje":0,"nowe_wersje":[],"nextcloud_serwer":false,"restart":true,"bledy":[],"jadro_uruchomione":"7.0.14-19-pve","jadro_nowe":"7.0.14-24-pve","dkms_gotowe":true}"#
        let m = try JSONDecoder().decode(MaszynaAktualizacji.self, from: Data(json.utf8))
        #expect(m.czekaNoweJadro && m.dkmsGotowe == true && m.wymagaRestartu)
        var to = m; to.jadroNowe = "7.0.14-19-pve"
        #expect(!to.czekaNoweJadro)
        let c = ServerCommands.poleceniRestartuHosta()
        #expect(c.contains(" -H -y") && c.contains("@@ZAJETE") && c.contains("systemd-run --unit=pve-update-check-mnas "))
    }

    @Test("Brak narzędzia i brak plików stanu")
    func brak() {
        let o = AktualizacjeParsers.odczyt("@@WERSJA \n@@STAN\n@@BRAK\n@@POSTEP\n@@BRAK\n@@KONIEC\n")
        #expect(o.narzedzie == .brak && o.stan == nil && o.postep == nil && !o.zajete)
    }

    @Test("Starsza wersja narzędzia na serwerze")
    func staraWersja() {
        #expect(AktualizacjeParsers.odczyt("@@WERSJA pve-update-check 2.1\n").narzedzie == .staraWersja("2.1"))
        #expect(AktualizacjeParsers.odczyt("@@WERSJA pve-update-check 2.10\n").narzedzie == .jest("2.10"))
    }

    @Test("Wynik po błędzie daje się cofnąć, po cofnięciu — już nie")
    func cofanie() throws {
        let json = #"{"stan":"bledy","zakres":"wszystko","wyniki":[{"typ":"ct","id":"108","etykieta":"CT 108","wynik":"blad","snapshot":null,"problemy":"Nextcloud;","kopia":"local:backup/vzdump-lxc-108-2026_10_16-10_12_03.tar.zst"}]}"#
        let p = try JSONDecoder().decode(PostepAktualizacji.self, from: Data(json.utf8))
        #expect(p.moznaCofnac?.kopia?.hasPrefix("local:backup/") == true)
        var po = p; po.zakres = "cofniecie"
        #expect(po.moznaCofnac == nil)
    }

    @Test("„Cofnij…” znika, gdy serwer skasował kopię albo snapshot")
    func cofanieBezKopii() throws {
        let json = #"{"stan":"bledy","zakres":"wszystko","wyniki":[{"typ":"ct","id":"108","etykieta":"CT 108","wynik":"blad","snapshot":null,"problemy":"Nextcloud;","kopia":"local:backup/vzdump-lxc-108-2026_10_16-10_12_03.tar.zst"}]}"#
        let tekst = "@@WERSJA pve-update-check 2.8\n@@STAN\n@@BRAK\n@@POSTEP\n\(json)\n@@KONIEC\n"
        // plik kopii jest — przycisk zostaje
        let jest = AktualizacjeParsers.odczyt(tekst + "@@COFNIJ 108 1\n")
        #expect(jest.postep?.moznaCofnac?.id == "108")
        // plik skasowany — nie ma do czego wrócić
        let brak = AktualizacjeParsers.odczyt(tekst + "@@COFNIJ 108 0\n")
        #expect(brak.postep?.moznaCofnac == nil)
        // starsze odczyty bez @@COFNIJ — jak dawniej
        #expect(AktualizacjeParsers.odczyt(tekst).postep?.moznaCofnac?.id == "108")
    }

    @Test("Odczyt i skrypt sprawdzają, czy kopia jeszcze istnieje")
    func cofanieSprawdzaKopie() {
        let c = ServerCommands.poleceniOdczytuAktualizacji()
        #expect(c.contains("@@COFNIJ") && c.contains("pvesm path") && c.contains("listsnapshot"))
        let skrypt = NarzedzieAktualizacji.zasob("puc-upgrade.sh")
        #expect(skrypt.contains(#"p=$(pvesm path "$vol" 2>/dev/null); [[ -n $p && -e $p ]] || vol="""#))
    }

    @Test("Weryfikacja przed sprzątaniem: ostrzeżenia i lista do ręcznego skasowania")
    func ostrzezeniaSprzatania() throws {
        let json = #"{"stan":"ok","zakres":"wszystko","wyniki":[{"typ":"ct","id":"108","etykieta":"CT 108 nextcloud","wynik":"ok","snapshot":null,"problemy":null,"kopia":"local:backup/x.tar.zst","ostrzezenia":["Nextcloud po aktualizacji: jest w trybie konserwacji; stare kopie updatera nie zostały skasowane"],"do_sprzatania":["nc /var/lib/nextcloud/dane/updater-a/backups/nextcloud-34.0.3.2-1789257946","apt"]}]}"#
        let p = try JSONDecoder().decode(PostepAktualizacji.self, from: Data(json.utf8))
        let w = try #require(p.doSprzatania)
        #expect(w.doSprzataniaOpis.count == 2)
        #expect(w.doSprzataniaOpis[0].contains("nextcloud-34.0.3.2-1789257946"))
        #expect(w.doSprzataniaOpis[1].contains("apt"))
        var po = p; po.zakres = "sprzatanie"
        #expect(po.doSprzatania == nil && po.moznaCofnac == nil)
        // starsze narzędzie (2.2) nie ma tych pól — dekodowanie dalej działa
        let stary = #"{"stan":"ok","wyniki":[{"typ":"ct","id":"108","etykieta":"CT 108","wynik":"ok"}]}"#
        #expect(try JSONDecoder().decode(PostepAktualizacji.self, from: Data(stary.utf8)).doSprzatania == nil)
        let c = try #require(ServerCommands.poleceniSprzatania(id: "108"))
        #expect(c.contains("-c 108 -y") && c.contains("@@ZAJETE"))
        #expect(ServerCommands.poleceniSprzatania(id: "108 /etc") == nil)
    }

    @Test("ID maszyny: tylko cyfry, bez wstrzyknięć")
    func walidacjaID() {
        #expect(AktualizacjeParsers.poprawneID("108"))
        for zle in ["", "host", "0", "108;reboot", "1 2", "-1", "١٠٨", "1234567890"] {
            #expect(!AktualizacjeParsers.poprawneID(zle), "\(zle)")
        }
        #expect(ServerCommands.poleceniStartuAktualizacji(id: "108; reboot", zakres: .wszystko, serwerNextcloud: false) == nil)
        #expect(ServerCommands.poleceniCofniecia(id: "$(id)") == nil)
    }

    @Test("Komenda startu: zakres, serwer Nextclouda, jednostka w tle")
    func komendaStartu() throws {
        let c = try #require(ServerCommands.poleceniStartuAktualizacji(id: "108", zakres: .aplikacje, serwerNextcloud: true))
        #expect(c.contains("systemd-run --unit=pve-update-check-mnas "))
        #expect(c.contains("-u -y -t 108 -o aplikacje -S"))
        #expect(c.contains("@@ZAJETE"))
        let p = try #require(ServerCommands.poleceniStartuAktualizacji(id: "108", zakres: .pakiety, serwerNextcloud: true))
        #expect(p.contains("-o pakiety") && !p.contains(" -S"))
        let w = try #require(ServerCommands.poleceniStartuAktualizacji(id: "101", zakres: .wszystko, serwerNextcloud: false))
        #expect(w.contains("-u -y -t 101 >") && !w.contains(" -o "))
        #expect(ServerCommands.poleceniCofniecia(id: "108")?.contains("-r 108 -y") == true)
    }

    @Test("Log bez sekwencji sterujących updatera Nextclouda")
    func logBezSterujacych() {
        let linia = "[ ] Downloading ...   0%\u{1B}[5D   2%\u{1B}[5D 100%\u{1B}[2K[✔] Downloading\r"
        #expect(AktualizacjeParsers.bezSterujacych(linia) == "[ ] Downloading ...   0%   2% 100%[✔] Downloading")
        #expect(OknoAktualizacji.czas(od: Date(timeIntervalSince1970: 0), do: Date(timeIntervalSince1970: 252)).contains("4"))
    }

    @Test("Log tylko z katalogu narzędzia")
    func log() {
        #expect(AktualizacjeParsers.poprawnyLog("/var/log/pve-update-check/aktualizacja-20261016-101203.log"))
        #expect(!AktualizacjeParsers.poprawnyLog("/var/log/pve-update-check/../../etc/shadow"))
        #expect(!AktualizacjeParsers.poprawnyLog("/etc/shadow"))
        #expect(!AktualizacjeParsers.poprawnyLog("/var/log/pve-update-check/a;b.log"))
    }

    @Test("Zasoby są w paczce, a wersja w kodzie zgadza się ze skryptem")
    func zasoby() {
        for p in NarzedzieAktualizacji.pliki {
            #expect(!NarzedzieAktualizacji.zasob(p.zasob).isEmpty, "\(p.zasob)")
        }
        let skrypt = NarzedzieAktualizacji.zasob("puc-pve-update-check.sh")
        #expect(skrypt.contains("\nVERSION=\(NarzedzieAktualizacji.wersja)\n"))
        let instalacja = ServerCommands.poleceniInstalacjiNarzedziaAktualizacji()
        #expect(instalacja.contains("[ -f /etc/pve-update-check/config ] ||"))
        #expect(instalacja.contains("enable --now pve-update-check.timer"))
        #expect(!instalacja.contains("pve-update-check-upgrade.timer >/dev/null"))   // automat zostaje wyłączony
    }
}
