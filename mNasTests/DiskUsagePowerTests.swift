import Testing
import Foundation
@testable import mNas

/// Testy trzech rzeczy zgłoszonych przez użytkownika 2026-08-19 po obejrzeniu apki
/// na żywo: pusty SMART dysku USB, martwe nazwy narzędzi i brak zajętości dysków.
/// Każdy przypadek stoi na wyjściu zapisanym z serwera testowego, nie na wymyślonym.
@Suite("Zajętość nośników, pobór mocy i rozpoznawanie narzędzi")
struct DiskUsagePowerTests {

    // MARK: - Zajętość nośników

    @Test("Dysk spoza magazynów Proxmoksa też ma zajętość")
    func daneNaNvme0() throws {
        let u = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: Fixtures.lvmReport)
        // /mnt/zasoby nie jest magazynem Proxmoksa — przez API był niewidoczny.
        let dane = try #require(u["nvme0n1"])
        #expect(dane.used == 822_684_856_320)
        // Mianownikiem jest pojemność nośnika — „ile mam miejsca" znaczy „ile mam na dysku".
        #expect(dane.capacity == 1_000_204_886_016)
        #expect(dane.mountpoints == ["/mnt/zasoby"])
        let frac = try #require(dane.fraction)
        #expect((frac * 100).rounded() == 82)
    }

    @Test("Zajętość woluminu LVM trafia na nośnik, na którym stoi")
    func lvmDoNvme1() throws {
        let u = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: Fixtures.lvmReport)
        // `/` to /dev/mapper/pve-root → dm-1 → nvme1n1p3 → nvme1n1.
        let system = try #require(u["nvme1n1"])
        #expect(system.mountpoints.contains("/"))
        #expect(system.mountpoints.contains("/boot/efi"))
        // `/` + `/boot/efi` z `df` **plus** cienka pula LVM (19,07 % ze 151 GB),
        // której `df` nie widzi.
        let pula = Int64(151_586_340_864.0 * 19.07 / 100)
        #expect(system.used == 9_685_651_456 + 9_461_760 + pula)
        #expect(system.capacity == 256_060_514_304)
    }

    @Test("Dwie partycje jednego nośnika sumują się")
    func dwiePartycje() throws {
        let u = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: Fixtures.lvmReport)
        let media = try #require(u["nvme2n1"])
        #expect(media.mountpoints.count == 2)
        #expect(media.used == 2_445_312 + 10_526_826_496)
    }

    @Test("Nośnik bez zamontowanego systemu plików nie udaje pustego")
    func niezamontowany() throws {
        let u = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: Fixtures.lvmReport)
        let sdb = try #require(u["sdb"])
        #expect(sdb.isMeasured == false)
        #expect(sdb.used == 0)
        // Pojemność liczy się do sumy nośników nawet bez montowania — dysk fizycznie jest.
        #expect(sdb.capacity == 1_000_204_886_016)
    }

    @Test("Kieszeń USB jest rozpoznana po kolumnie TRAN")
    func transportUSB() throws {
        let u = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: Fixtures.lvmReport)
        #expect(u["sdd"]?.transport == "usb")
        #expect(u["nvme0n1"]?.transport == "nvme")
    }

    @Test("Model z nazwą wieloczłonową nie rozwala parsowania par KLUCZ=\"wartość\"")
    func modelZeSpacja() throws {
        let u = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: Fixtures.lvmReport)
        // DYSK HDD1000A ma spację w nazwie — dzielenie po spacjach gubiłoby SIZE.
        #expect(u["sdb"]?.capacity == 1_000_204_886_016)
    }

    @Test("Obrazy loop nie są nośnikami")
    func bezLoopow() throws {
        let u = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes, lvm: Fixtures.lvmReport)
        #expect(u["loop0"] == nil)
    }

    @Test("Wolumeny maszyn nie są liczone drugi raz obok puli")
    func bezPodwojnegoLiczenia() throws {
        let zSamaPula = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes,
                                               lvm: Fixtures.lvmReport)
        let zWolumenami = StatsParsers.diskUsage(lsblk: Fixtures.lsblkPairs, df: Fixtures.dfBytes,
                                                 lvm: Fixtures.lvmReportZWolumenami)
        let a = try #require(zSamaPula["nvme1n1"]?.used)
        let b = try #require(zWolumenami["nvme1n1"]?.used)
        // Gdyby odsiewanie po `lv_attr` wypadło z komendy, ta różnica wróci.
        #expect(b > a)
        #expect(a == 9_685_651_456 + 9_461_760 + Int64(151_586_340_864.0 * 19.07 / 100))
    }

    // MARK: - Pobór mocy

    @Test("Waty liczone z różnicy dwóch liczników energii")
    func watyZRoznicy() throws {
        let a = try #require(StatsParsers.raplSample(Fixtures.raplFirst))
        let b = try #require(StatsParsers.raplSample(Fixtures.raplSecond))
        let w = StatsParsers.watts(from: a, to: b)
        #expect(abs((w["package-0"] ?? 0) - 10.4) < 0.01)
        #expect(abs((w["core"] ?? 0) - 7.9) < 0.01)
        #expect(abs((w["dram"] ?? 0) - 0.5) < 0.01)
    }

    @Test("Przewinięcie licznika nie daje ujemnych watów")
    func przewinięcieLicznika() throws {
        let b = try #require(StatsParsers.raplSample(Fixtures.raplBeforeWrap))
        let c = try #require(StatsParsers.raplSample(Fixtures.raplAfterWrap))
        let w = StatsParsers.watts(from: b, to: c)
        let pkg = try #require(w["package-0"])
        // Te same 10,4 W co przed przewinięciem — licznik skoczył, pobór nie.
        #expect(abs(pkg - 10.4) < 0.01)
    }

    @Test("Za krótki odstęp nie produkuje liczb rzędu kilowatów")
    func zaKrotkiOdstep() throws {
        let a = try #require(StatsParsers.raplSample(Fixtures.raplFirst))
        var b = try #require(StatsParsers.raplSample(Fixtures.raplSecond))
        b.timestampNanos = a.timestampNanos + 1_000_000      // 1 ms
        #expect(StatsParsers.watts(from: a, to: b).isEmpty)
    }

    // MARK: - Narzędzia w kontenerach

    @Test("Port 3000 pokazuje kontener, który go zajmuje, a nie skasowany AdGuard")
    func forgejoNiePodszywaSie() throws {
        let uslugi = StatsParsers.webServices(Fixtures.pctListen)
        let na3000 = try #require(uslugi.first { $0.port == 3000 })
        #expect(na3000.label == "Forgejo")
        #expect(na3000.guestName == "forgejo")
        #expect(uslugi.contains { $0.label == "AdGuard Home" } == false)
    }

    @Test("Udziały sieciowe SMB nie robią się kaflami z linkiem http")
    func sambaOdsiana() throws {
        let uslugi = StatsParsers.webServices(Fixtures.pctListen)
        #expect(uslugi.contains { $0.port == 139 || $0.port == 445 } == false)
    }

    @Test("Baza danych na pętli zwrotnej też odpada")
    func bazaOdsiana() throws {
        let uslugi = StatsParsers.webServices(Fixtures.pctListen)
        #expect(uslugi.contains { $0.port == 3306 } == false)
    }

    @Test("Nazwa kontenera wygrywa, ale port nadal ustala HTTPS")
    func nazwaIProtokol() throws {
        let uslugi = StatsParsers.webServices(Fixtures.pctListen)
        let kuma = try #require(uslugi.first { $0.port == 3001 })
        #expect(kuma.label == "Uptime Kuma")
        #expect(kuma.secure == false)
        #expect(kuma.url?.absoluteString == "http://192.168.10.42:3001")
    }

    // MARK: - SMART dysku bez wskaźników krytycznych

    @Test("Dysk USB bez ani jednego wskaźnika krytycznego nie pokazuje pustki")
    func ssdUsbMaWskazniki() throws {
        let data = Fixtures.smartctlSsdUsb.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let r = StatsParsers.smart(obj)
        #expect(r.ok)
        #expect(r.model == "NONAME S100")
        #expect(r.passed == true)
        // Dziewięć wskaźników z dysku; żaden nie należy do listy krytycznej.
        #expect(r.attributes.count == 9)
        #expect(r.attributes.allSatisfy { !$0.critical })
        #expect(r.temperature == nil)          // ten dysk nie ma czujnika — i tak ma być
    }

    @Test("Wskaźnik bez nazwy dostaje numer, a nie zmyśloną etykietę")
    func nienazwanyWskaznik() throws {
        let data = Fixtures.smartctlSsdUsb.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let r = StatsParsers.smart(obj)
        #expect(r.attributes.contains { $0.name == "Wskaźnik 168 (nienazwany)" })
        #expect(r.attributes.contains { $0.name == "Zapisano łącznie (LBA)" && $0.value == "28001" })
    }

    @Test("Identyfikatory wskaźników są unikalne mimo powtórzonych etykiet")
    func unikalneId() throws {
        let data = Fixtures.smartctlSsdUsb.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let r = StatsParsers.smart(obj)
        #expect(Set(r.attributes.map(\.id)).count == r.attributes.count)
    }
}
