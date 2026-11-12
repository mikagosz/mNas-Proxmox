import Testing
import Foundation
@testable import mNas

/// Naprawy po audycie dynamicznym 2026-11-12 (mNas 1.2.48). Każda grupa z kontrolą,
/// która pokazuje, że test widzi poprawny przypadek — zero bez kontroli nic nie mówi.
@Suite("Naprawy po audycie dynamicznym 2026-11-12")
struct NaprawyDynamiczneTests {

    // MARK: - D-S-P2-01: liczby z serwera poza zakresem

    @Test("Pamięć: inf, 1e19 i liczba ponad Int64 dają brak odczytu, nie koniec programu",
          arguments: ["inf", "1e19", "99999999999999999999", "1e999"])
    func pamiecPozaZakresem(_ total: String) {
        #expect(StatsParsers.memory("MemTotal: \(total) kB\nMemAvailable: 200 kB\n", arcBytes: nil) == nil)
    }

    @Test("Pamięć: kontrola — zwykły odczyt dalej działa, wolne poza zakresem przycięte")
    func pamiecKontrola() throws {
        let m = try #require(StatsParsers.memory("MemTotal: 8000000 kB\nMemAvailable: inf kB\n", arcBytes: .nan))
        #expect(m.total == 8_192_000_000)
        #expect(m.free == 8_192_000_000)
    }

    @Test("Pule LVM: nan, inf i 1e308 nie kończą programu", arguments: [("nan", "10"), ("inf", "10"), ("1e308", "100"), ("1000", "nan")])
    func pulaPozaZakresem(_ wartosci: (String, String)) {
        let lvm = "PV /dev/sda3 pve\nPOOL pve \(wartosci.0) \(wartosci.1)\n"
        let u = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: lvm)
        #expect(!u.isEmpty)
    }

    @Test("Pule LVM: kontrola — zwykła pula dalej liczona")
    func pulaKontrola() {
        let bez = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: "")
        let z = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: Fixtures.lvmReport)
        #expect(z.values.map(\.used).reduce(0, +) > bez.values.map(\.used).reduce(0, +))
    }

    @Test("RAPL: znaczniki czasu i liczniki na granicach Int64 dają brak odczytu")
    func raplGranice() throws {
        let a = try #require(StatsParsers.raplSample("-9223372036854775807\npackage-0 100 1000"))
        let b = try #require(StatsParsers.raplSample("9223372036854775807\npackage-0 200 1000"))
        #expect(StatsParsers.watts(from: a, to: b).isEmpty)
        let c = try #require(StatsParsers.raplSample("1000000000\npackage-0 -9223372036854775807 0"))
        let d = try #require(StatsParsers.raplSample("2000000000\npackage-0 9223372036854775807 0"))
        #expect(StatsParsers.watts(from: c, to: d).isEmpty)
        let e = try #require(StatsParsers.raplSample("1000000000\npackage-0 -5 9223372036854775807"))
        let f = try #require(StatsParsers.raplSample("2000000000\npackage-0 -9223372036854775807 9223372036854775807"))
        _ = StatsParsers.watts(from: e, to: f)   // przewinięcie z przepełnieniem — tylko bez pułapki
    }

    @Test("RAPL: kontrola — zwykła próbka i przewinięcie licznika dalej liczone")
    func raplKontrola() throws {
        let a = try #require(StatsParsers.raplSample(Fixtures.raplFirst))
        let b = try #require(StatsParsers.raplSample(Fixtures.raplSecond))
        #expect(StatsParsers.watts(from: a, to: b)["package-0"] != nil)
        let w1 = try #require(StatsParsers.raplSample(Fixtures.raplBeforeWrap))
        let w2 = try #require(StatsParsers.raplSample(Fixtures.raplAfterWrap))
        #expect(!StatsParsers.watts(from: w1, to: w2).isEmpty)
    }

    // MARK: - D-B-P2-01: adres narzędzia z wnętrza kontenera

    @Test("Narzędzia: adres, który nie jest IP, nie daje linku",
          arguments: ["evil.example", "user@evil.example", "10.0.0.5/admin?x=", "10.0.0.5:9999", "1"])
    func adresNieIP(_ ip: String) {
        let s = StatsParsers.webServices("@@CT 101 nextcloud\nIP \(ip)\nLISTEN 0.0.0.0:443\n")
        #expect(s.isEmpty, "\(s.map { $0.url?.absoluteString ?? "nil" })")
    }

    @Test("Narzędzia: kontrola — IPv4 i IPv6 dalej dają link", arguments: ["10.0.0.5", "[fe80::1]", "fd00::5"])
    func adresIP(_ ip: String) {
        let s = StatsParsers.webServices("@@CT 101 nextcloud\nIP \(ip)\nLISTEN 0.0.0.0:443\n")
        #expect(s.count == 1)
        #expect(s.first?.label == "Nextcloud")
    }

    // MARK: - D-B-P3-01: konto SSH zaczynające się od „-”

    @Test("SSH: konto albo adres wyglądające jak opcja są odrzucane",
          arguments: [("-oProxyCommand=touch x", "127.0.0.1"), ("root", "-oProxyCommand=x"), ("ro ot", "pve"),
                      ("root", "x -oProxyCommand=y"), ("", "pve"), ("root;id", "pve"), ("root", "")])
    func celOdrzucony(_ c: (String, String)) {
        #expect(!SSHRunner.poprawnyCel(host: c.1, user: c.0))
    }

    @Test("SSH: kontrola — zwykłe konta i adresy przechodzą",
          arguments: [("root", "pve"), ("root", "192.168.10.40"), ("admin_1", "serwer.local"), ("root", "[fe80::1]")])
    func celPoprawny(_ c: (String, String)) {
        #expect(SSHRunner.poprawnyCel(host: c.1, user: c.0))
    }

    @Test("SSH: polecenie z kontem-opcją nie uruchamia niczego, a polecenie do Terminala ma `--`")
    func sshNieWykonuje() async {
        let znacznik = FileManager.default.temporaryDirectory.appendingPathComponent("mnas-znacznik-\(UUID().uuidString)")
        let r = await SSHRunner(host: "127.0.0.1", user: "-oProxyCommand=touch \(znacznik.path)").run("true", timeout: 3)
        #expect(r.code == -1)
        #expect(!FileManager.default.fileExists(atPath: znacznik.path + "@127.0.0.1"))
        #expect(SSHRunner.polecenieTerminala(host: "pve", user: "root", komenda: "true").contains(" -- 'root@pve'"))
    }

    // MARK: - D-B-P1-01: jeden zepsuty wpis maszyny nie gasi stanu

    @Test("Stan aktualizacji: maszyna z rozjechanym wpisem pominięta, reszta zostaje")
    func stanZZepsutaMaszyna() throws {
        let json = """
        {"format":1,"wersja":"2.9","host":"pve","sprawdzono":"2026-11-12T20:00:00+00:00","maszyny":[
         {"typ":"host","id":"host","etykieta":"Host pve","system":"Debian","pakiety":2,"bezpieczenstwo":1,"aplikacje":0,
          "nextcloud_serwer":false,"restart":false,"nowe_wersje":[],"bledy":[],"lista_pakietow":[],"sprawdzono":"2026-11-12T20:00:00+00:00"},
         {"typ":"ct","id":"301","etykieta":"CT 301","system":"Zly","pakiety":"nie-liczba","bezpieczenstwo":[],"aplikacje":{},
          "nextcloud_serwer":"tak","restart":7,"nowe_wersje":5,"bledy":"x","lista_pakietow":"y","sprawdzono":1}
        ]}
        """
        let stan = try JSONDecoder().decode(StanAktualizacji.self, from: Data(json.utf8))
        #expect(stan.maszyny.map(\.id) == ["host"])
    }

    @Test("Stan aktualizacji: kontrola — prawdziwy odczyt dalej ma wszystkie maszyny")
    func stanKontrola() {
        let o = AktualizacjeParsers.odczyt(AktualizacjeSerweraTests.odczyt)
        #expect(o.stan?.maszyny.count == 3)
    }

    @Test("Skrypt na serwerze czyści separatory i sprawdza liczbę pól (wersja 2.9)")
    func skryptCzysci() {
        let s = NarzedzieAktualizacji.zasob("puc-pve-update-check.sh")
        #expect(s.contains(#"line=${line//[$'\t\x1f\r']/ }"#))
        #expect(s.contains("next unless @pola == 18;"))
        #expect(s.contains("VERSION=\(NarzedzieAktualizacji.wersja)"))
    }
}
