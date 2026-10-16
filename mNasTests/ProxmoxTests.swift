import Testing
import Foundation
@testable import mNas

/// Testy warstwy dopisanej przy przejściu z TrueNAS-a na Proxmoksa.
///
/// Świadomie **nie** testują tu HTTP: `ProxmoxClient` rozmawia z żywym węzłem, więc
/// sprawdzalne bez serwera jest to, co robi z odpowiedzią — parsowanie temperatur
/// z `smartctl` i przeliczenia pokazywane przy maszynach.
@Suite("Proxmox: temperatury dysków i goście")
struct ProxmoxTests {

    // MARK: - Temperatury dysków (smartctl -j, sekcje per dysk)

    /// Zapisane wyjście `diskTemperatures` dla trzech dysków: NVMe (działa),
    /// SATA (działa) i talerzowy w kieszeni USB, który **śpi** — `-n standby` zwraca
    /// wtedy JSON bez pola `temperature`.
    static let smartSections = """
    @@nvme0n1
    {"json_format_version":[1,0],"device":{"name":"/dev/nvme0n1"},"temperature":{"current":41}}
    @@sda
    {"json_format_version":[1,0],"device":{"name":"/dev/sda"},"temperature":{"current":33}}
    @@sdb
    {"json_format_version":[1,0],"device":{"name":"/dev/sdb"},"smartctl":{"messages":[{"string":"Device is in STANDBY mode, exit(2)"}]}}
    """

    @Test("Temperatury wychodzą per dysk, po nazwie urządzenia")
    func readsTemperaturesPerDisk() {
        let out = StatsParsers.diskTemperatures(Self.smartSections)
        #expect(out["nvme0n1"] == 41)
        #expect(out["sda"] == 33)
    }

    /// Kluczowe: uśpiony dysk ma **zniknąć z wyniku**, a nie dostać zero. Wpisanie 0
    /// kazałoby interfejsowi pokazać „0 °C" dla dysku, który po prostu śpi — czyli
    /// zmyślony, alarmująco wyglądający pomiar zamiast braku pomiaru.
    @Test("Uśpiony dysk nie dostaje zmyślonego zera")
    func sleepingDiskIsAbsent() {
        let out = StatsParsers.diskTemperatures(Self.smartSections)
        #expect(out["sdb"] == nil)
        #expect(out.count == 2)
    }

    @Test("Śmieci zamiast JSON-a nie wywracają parsera")
    func garbageIsIgnored() {
        let out = StatsParsers.diskTemperatures("@@sda\nbash: smartctl: command not found\n")
        #expect(out.isEmpty)
    }

    // MARK: - Kondycja SMART (ta sama ścieżka co temperatury)

    /// Wyjście `smartctl -A -H -n standby -j` dla trzech dysków: zdrowy NVMe, dysk
    /// z werdyktem **FAILED** i talerzowy, który **śpi** — wtedy `-n standby` nie zwraca
    /// `smart_status` w ogóle.
    static let smartKondycje = """
    @@nvme0n1
    {"json_format_version":[1,0],"smart_status":{"passed":true},"temperature":{"current":41}}
    @@sda
    {"json_format_version":[1,0],"smart_status":{"passed":false},"temperature":{"current":33}}
    @@sdd
    {"json_format_version":[1,0],"smartctl":{"messages":[{"string":"Device is in STANDBY mode, exit(2)"}]}}
    """

    @Test("Werdykt SMART wychodzi per dysk")
    func readsHealthPerDisk() {
        let out = StatsParsers.diskHealth(Self.smartKondycje)
        #expect(out["nvme0n1"] == "PASSED")
        #expect(out["sda"] == "FAILED")
    }

    /// 🔴 Najważniejszy test w tej grupie. Uśpiony dysk nie zwraca werdyktu i **musi**
    /// zniknąć z wyniku. Gdyby brak odpowiedzi zamienił się w `FAILED`, każde zaśnięcie
    /// talerza zapalałoby poważne ostrzeżenie „dysk zgłasza, że jest z nim źle" — fałszywy
    /// alarm o awarii dysku, który po prostu oszczędza prąd. Ta sama zasada co przy
    /// temperaturach i przy braku połączenia w pasku menu: brak wiedzy to nie awaria.
    @Test("Uśpiony dysk nie dostaje werdyktu FAILED")
    func sleepingDiskHasNoVerdict() {
        let out = StatsParsers.diskHealth(Self.smartKondycje)
        #expect(out["sdd"] == nil)
        #expect(out.count == 2)
    }

    @Test("Śmieci zamiast JSON-a nie robią werdyktu")
    func garbageGivesNoHealth() {
        #expect(StatsParsers.diskHealth("@@sda\nbash: smartctl: command not found\n").isEmpty)
    }

    /// Ta sama pułapka co przy temperaturach: litery `sd*` przetasowują się po przepięciu
    /// kieszeni USB, więc werdykt musi iść za **serialem**, nie za literą. Na serwerze testowym dwa
    /// talerze mają identyczną pojemność 931,5 G i tylko serial je rozróżnia.
    @MainActor
    @Test("Werdykt SMART nie wędruje razem z literą po przepięciu kieszeni")
    func healthFollowsSerialNotLetter() {
        let hdd = Disk(name: "sda", model: "DYSK_HDD1000A", serial: "TESTSN00000005", type: "HDD")
        let wd = Disk(name: "sdd", model: "DYSK_HDD1000B", serial: "WD-TESTSN000007", type: "HDD")

        var mapa: [String: String] = [:]
        AppModel.nalozKondycje(["sda": "FAILED"], dyski: [hdd], na: &mapa)
        #expect(mapa["TESTSN00000005"] == "FAILED")

        // Po przepięciu: DYSK stoi pod `sdd`, a WD pod `sda`.
        var poZamianie = [Disk(name: "sdd", model: hdd.model, serial: hdd.serial, type: "HDD"),
                          Disk(name: "sda", model: wd.model, serial: wd.serial, type: "HDD")]
        AppModel.nalozKondycje(mapa, na: &poZamianie)
        #expect(poZamianie[0].health == "FAILED")   // DYSK zabiera werdykt ze sobą
        #expect(poZamianie[1].health == nil)        // WD nie dziedziczy cudzego
    }

    /// Dysk, który zasnął, **zatrzymuje** ostatni znany werdykt. Gdyby pusty odczyt
    /// kasował mapę, kafel gubiłby kondycję za każdym razem, gdy talerz pójdzie spać —
    /// czyli po wprowadzeniu `skipsmart=1` praktycznie zawsze.
    @MainActor
    @Test("Zaśnięcie dysku nie kasuje znanej kondycji")
    func sleepKeepsLastKnownHealth() {
        let hdd = Disk(name: "sda", model: "DYSK_HDD1000A", serial: "TESTSN00000005", type: "HDD")
        var mapa: [String: String] = [:]
        AppModel.nalozKondycje(["sda": "PASSED"], dyski: [hdd], na: &mapa)
        AppModel.nalozKondycje([:], dyski: [hdd], na: &mapa)   // tura, w której dysk spał
        #expect(mapa["TESTSN00000005"] == "PASSED")
    }

    // MARK: - Przeliczenia maszyn i kontenerów

    private func guest(running: Bool, cpu: Double?, mem: Int64?, maxMem: Int64?) -> Guest {
        Guest(vmid: 100, name: "test", kind: .container, running: running,
              cpuFraction: cpu, maxCPU: 2, memoryUsed: mem, memoryTotal: maxMem,
              diskUsed: nil, diskTotal: nil, uptimeSeconds: nil)
    }

    @Test("CPU gościa: ułamek z API zamieniony na procent")
    func cpuPercentFromFraction() {
        #expect(guest(running: true, cpu: 0.5, mem: nil, maxMem: nil).cpuPercent == 50)
        #expect(guest(running: true, cpu: 0, mem: nil, maxMem: nil).cpuPercent == 0)
    }

    /// Proxmox potrafi zwrócić chwilowo wartość ponad 1.0. Bez zacisku kafel pokazałby
    /// „137 %", a pasek wyszedłby poza ramkę.
    @Test("Chwilowy skok powyżej 100 % jest przycięty")
    func cpuPercentIsClamped() {
        #expect(guest(running: true, cpu: 1.37, mem: nil, maxMem: nil).cpuPercent == 100)
    }

    /// Zgaszona maszyna raportuje same zera. Pokazanie „RAM 0 %" sugerowałoby pomiar
    /// tam, gdzie nie ma czego mierzyć — dlatego `nil`, a interfejs pisze „zgaszona".
    @Test("Zgaszona maszyna nie ma procentu RAM, zamiast mieć zero")
    func stoppedGuestHasNoMemoryPercent() {
        #expect(guest(running: false, cpu: 0, mem: 0, maxMem: 536_870_912).memoryPercent == nil)
        #expect(guest(running: true, cpu: 0, mem: 268_435_456, maxMem: 536_870_912).memoryPercent == 50)
    }

    @Test("Kontener i maszyna mają różne etykiety i ikony")
    func kindsAreDistinct() {
        #expect(Guest.Kind.container.label == "Kontener")
        #expect(Guest.Kind.virtualMachine.label == "Maszyna")
        #expect(Guest.Kind.container.symbol != Guest.Kind.virtualMachine.symbol)
    }

    // MARK: - Wykrywanie narzędzi w kontenerach

    /// **Prawdziwe** wyjście `discoverWebServices()` z serwera testowego, zdjęte 2026-08-16.
    ///
    /// Celowo nie jest to wymyślony przykład: wersja pisana z głowy nie zawierała
    /// losowych, wysokich portów demona Tailscale'a — a to właśnie one robiły
    /// z sekcji „Narzędzia" śmietnik.
    static let discovery = """
    @@CT 100 tailscale
    IP 192.168.10.41
    LISTEN 100.64.0.10:34151
    LISTEN 127.0.0.1:25
    LISTEN [fd7a:115c:a1e0::10]:63440
    LISTEN *:22
    LISTEN [::1]:25
    @@CT 101 kuma
    IP 192.168.10.42
    LISTEN 0.0.0.0:3001
    LISTEN 127.0.0.1:25
    LISTEN [::1]:25
    LISTEN *:22
    @@CT 102 adguard
    IP 192.168.10.43
    LISTEN 127.0.0.1:25
    LISTEN [::1]:25
    LISTEN *:3000
    LISTEN *:53
    LISTEN *:22
    """

    @Test("Narzędzia dostają adres z kontenera i nazwę rozpoznaną po porcie")
    func discoversKnownTools() {
        let found = StatsParsers.webServices(Self.discovery)
        let kuma = found.first { $0.port == 3001 }
        let adguard = found.first { $0.port == 3000 }
        #expect(kuma?.toolName == "Uptime Kuma")
        #expect(kuma?.url?.absoluteString == "http://192.168.10.42:3001")
        #expect(adguard?.toolName == "AdGuard Home")
        #expect(adguard?.url?.absoluteString == "http://192.168.10.43:3000")
    }

    /// SSH, DNS i poczta na pętli zwrotnej to nie są narzędzia z panelem.
    @Test("SSH, DNS i pętla zwrotna nie tworzą kafli")
    func filtersOutNoise() {
        let found = StatsParsers.webServices(Self.discovery)
        #expect(found.count == 2)
        #expect(!found.contains { $0.port == 22 })
        #expect(!found.contains { $0.port == 53 })
        #expect(!found.contains { $0.port == 25 })
    }

    /// Regresja z żywego serwera: demon Tailscale'a nasłuchuje na losowanych portach
    /// (`34151`, `63440`), zmienianych przy każdym starcie. Robiły się z nich kafle
    /// prowadzące donikąd — a kontener `tailscale` nie ma żadnego panelu web.
    @Test("Losowe wysokie porty demona nie udają narzędzi")
    func ignoresEphemeralPorts() {
        let found = StatsParsers.webServices(Self.discovery)
        #expect(!found.contains { $0.port == 34_151 })
        #expect(!found.contains { $0.port == 63_440 })
        #expect(!found.contains { $0.vmid == 100 })
    }

    /// Usługa słuchająca i na IPv4, i na IPv6 wraca z `ss` dwa razy — a jest jedna.
    @Test("Podwójny nasłuch IPv4/IPv6 daje jeden kafel")
    func deduplicatesDualStack() {
        let found = StatsParsers.webServices("""
        @@CT 101 kuma
        IP 192.168.10.42
        LISTEN *:3001
        LISTEN [::]:3001
        """)
        #expect(found.filter { $0.port == 3001 }.count == 1)
    }

    @Test("Nierozpoznany port zostaje, ale pod nazwą kontenera")
    func unknownPortKeepsGuestName() {
        let found = StatsParsers.webServices("""
        @@CT 200 testy
        IP 192.168.10.44
        LISTEN 0.0.0.0:7777
        """)
        #expect(found.count == 1)
        #expect(found.first?.toolName == nil)
        #expect(found.first?.label == "testy")
    }

    /// Od 1.2.11 kontenery są pytane równolegle, więc bloki `@@CT` przychodzą w kolejności,
    /// w jakiej skończyły się `pct exec`, a nie po numerze kontenera.
    @Test("Bloki kontenerów w dowolnej kolejności dają ten sam wynik")
    func discoveryIgnoresBlockOrder() {
        let bloki = Self.discovery.components(separatedBy: "@@CT ")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
        let odwrotnie = bloki.reversed().map { "@@CT " + $0 }.joined(separator: "\n")
        #expect(bloki.count == 3)
        #expect(StatsParsers.webServices(odwrotnie) == StatsParsers.webServices(Self.discovery))
    }

    @Test("Puste wyjście (brak kontenerów) nie wywraca parsera")
    func emptyDiscoveryIsSafe() {
        #expect(StatsParsers.webServices("").isEmpty)
    }

    // MARK: - Konto SSH kontra identyfikator tokenu

    /// Jedno pole w interfejsie obsługuje oba kanały: REST dostaje `root@pam!mnas`,
    /// SSH — samo `root`. Rozjechanie się tych dwóch było najłatwiejszą pomyłką
    /// przy przepinaniu apki, więc jest przypięte testem.
    @MainActor
    @Test("Konto SSH to część tokenu przed znakiem @")
    func sshUserIsDerivedFromToken() {
        let model = AppModel()
        model.username = "root@pam!mnas"
        #expect(model.sshUser == "root")
        model.username = "monitor@pve!odczyt"
        #expect(model.sshUser == "monitor")
    }

    // MARK: - Dysk bez czujnika kontra dysk uśpiony

    /// Trzy odpowiedzi, które z zewnątrz wyglądają podobnie, a znaczą co innego:
    /// NVMe z odczytem, NONAME S100 z pełną tablicą ATA **bez** atrybutu `194`
    /// i talerzowy, który śpi pod `-n standby`.
    static let smartTrzyPrzypadki = """
    @@nvme0n1
    {"json_format_version":[1,0],"device":{"name":"/dev/nvme0n1"},"temperature":{"current":41},"nvme_smart_health_information_log":{"temperature":41}}
    @@sdb
    {"json_format_version":[1,0],"device":{"name":"/dev/sdb"},"ata_smart_attributes":{"table":[{"id":9,"name":"Power_On_Hours","raw":{"value":20000}},{"id":241,"name":"Total_LBAs_Written","raw":{"value":28006}}]}}
    @@sdc
    {"json_format_version":[1,0],"device":{"name":"/dev/sdc"},"smartctl":{"messages":[{"string":"Device is in STANDBY mode, exit(2)"}]}}
    """

    @Test("Dysk bez czujnika to co innego niż dysk uśpiony")
    func distinguishesMissingSensorFromSleep() {
        let out = StatsParsers.diskTemperatureReports(Self.smartTrzyPrzypadki)
        #expect(out["nvme0n1"] == .wartosc(41))
        #expect(out["sdb"] == .brakCzujnika)      // tablica przyszła, temperatury w niej nie ma
        #expect(out["sdc"] == .brakOdpowiedzi)    // śpi, więc nic nie wiemy
    }

    /// Regresja ze zgłoszenia 2026-09-06: po restarcie serwera przy NONAME-ie C50
    /// pojawiło się 50 °C, choć ten dysk temperatury nie podaje w ogóle. Litery `sd*`
    /// przetasowały się i stara wartość poprzedniego lokatora `sdb` została pokazana
    /// przy nowym. Klucz po serialu plus kasowanie przy `brakCzujnika` to zamykają.
    @MainActor
    @Test("Temperatura nie wędruje razem z literą po restarcie serwera")
    func temperatureFollowsSerialNotDeviceLetter() {
        let ssdUsb = Disk(name: "sdb", model: "NONAME_S100", serial: "TESTSN0000000000003", type: "SSD")
        let hdd = Disk(name: "sda", model: "DYSK_HDD1000A", serial: "TESTSN00000005", type: "HDD")

        // Przed restartem: DYSK siedzi pod literą `sdb` i ma 50 °C.
        var mapa: [String: Double] = [:]
        let przed = Disk(name: "sdb", model: hdd.model, serial: hdd.serial, type: "HDD")
        AppModel.nalozRaporty(["sdb": .wartosc(50)], dyski: [przed], na: &mapa)
        #expect(mapa["TESTSN00000005"] == 50)

        // Po restarcie: `sdb` to już NONAME, DYSK przesunął się na `sda`.
        AppModel.nalozRaporty(["sdb": .brakCzujnika, "sda": .wartosc(39)],
                              dyski: [ssdUsb, hdd], na: &mapa)
        #expect(mapa["TESTSN0000000000003"] == nil)   // NONAME nie dostaje cudzej liczby
        #expect(mapa["TESTSN00000005"] == 39)          // DYSK zabiera swoją ze sobą
    }

    /// Uśpiony dysk **zatrzymuje** ostatni pomiar — inaczej kafel migałby przy każdym
    /// uśpieniu kieszeni USB. To druga połowa rozróżnienia z testu wyżej.
    @MainActor
    @Test("Uśpiony dysk zatrzymuje ostatnią zmierzoną wartość")
    func sleepingDiskKeepsLastReading() {
        let mx500 = Disk(name: "sdc", model: "SSD250SATA1", serial: "TESTSN000001", type: "SSD")
        var mapa: [String: Double] = ["TESTSN000001": 43]
        AppModel.nalozRaporty(["sdc": .brakOdpowiedzi], dyski: [mx500], na: &mapa)
        #expect(mapa["TESTSN000001"] == 43)
    }
}
