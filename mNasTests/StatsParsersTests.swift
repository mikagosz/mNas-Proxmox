import Testing
import Foundation
@testable import mNas

/// Testy czystych parserów. Nie dotykają sieci ani serwera — wejściem są zapisane,
/// realne odpowiedzi z `Fixtures`.
@Suite("Parsery statystyk")
struct StatsParsersTests {

    // MARK: - splitSections

    @Test("Rozbija zbiorcze wyjście SSH na sekcje po znacznikach @@")
    func splitsSections() {
        let s = StatsParsers.splitSections(Fixtures.liveStats)
        #expect(s.keys.sorted() == ["ARC", "GPU", "MEM", "SENSORS", "STAT"])
        #expect(s["ARC"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "4294967296")
        #expect(s["STAT"]?.contains("cpu0") == true)
        #expect(s["GPU"]?.contains("GTX 1650") == true)
    }

    @Test("Tekst bez znaczników nie daje żadnej sekcji")
    func splitsNothingWithoutMarkers() {
        #expect(StatsParsers.splitSections("zwykłe wyjście\nbez znaczników").isEmpty)
    }

    // MARK: - /proc/stat

    @Test("Pierwszy pomiar /proc/stat nie daje wyniku — nie ma z czym porównać")
    func procStatNeedsTwoSamples() {
        var prev: [String: CPUJiffies] = [:]
        let first = StatsParsers.procStat(Fixtures.procStatFirst, previous: &prev)
        #expect(first.aggregate == nil)
        #expect(first.perCore.isEmpty)
        #expect(prev.count == 5)          // cpu + cpu0…cpu3
    }

    @Test("Delta dwóch pomiarów daje 25 % zajętości agregatu")
    func procStatComputesDelta() {
        var prev: [String: CPUJiffies] = [:]
        _ = StatsParsers.procStat(Fixtures.procStatFirst, previous: &prev)
        let second = StatsParsers.procStat(Fixtures.procStatSecond, previous: &prev)
        // +1000 jiffies łącznie, z czego +750 idle → 25 % zajęte.
        #expect(second.aggregate == 25.0)
        #expect(second.perCore.count == 4)
        #expect(second.perCore.allSatisfy { (0...100).contains($0) })
    }

    @Test("Wiersz krótszy niż 5 kolumn jest pomijany zamiast wywalać indeksowanie")
    func procStatSkipsShortRows() {
        var prev: [String: CPUJiffies] = [:]
        let r = StatsParsers.procStat("cpu 1 2 3\ncpu0 1 2", previous: &prev)
        #expect(r.aggregate == nil)
        #expect(prev.isEmpty)
    }

    // MARK: - /proc/meminfo

    @Test("Rozbicie RAM: total, wolne, ARC i reszta jako usługi")
    func parsesMemory() throws {
        let arc = 4_294_967_296.0                       // 4 GiB
        let m = try #require(StatsParsers.memory(Fixtures.meminfo, arcBytes: arc))
        let total = try #require(m.total)
        let free = try #require(m.free)
        let zfs = try #require(m.zfsCache)
        let services = try #require(m.services)

        #expect(total == Int64(32_819_208) * 1024)      // kB z /proc/meminfo → bajty
        #expect(free == Int64(16_777_216) * 1024)       // MemAvailable ma pierwszeństwo nad MemFree
        #expect(zfs == Int64(arc))
        #expect(services == total - free - zfs)
        #expect(m.hasBreakdown)
    }

    @Test("Brak MemTotal → nil, żeby nie nadpisać poprawnych danych zerami")
    func memoryWithoutTotalIsNil() {
        #expect(StatsParsers.memory("Buffers: 100 kB", arcBytes: nil) == nil)
    }

    @Test("ARC większy niż cały RAM jest przycinany do total")
    func memoryClampsArc() throws {
        let m = try #require(StatsParsers.memory(Fixtures.meminfo, arcBytes: 1e18))
        #expect(m.zfsCache == m.total)
        #expect(try #require(m.services) == 0)
    }

    // MARK: - sensors -j

    @Test("Temperatury rdzeni wychodzą posortowane po numerze rdzenia")
    func parsesCoreTemps() throws {
        let r = try #require(StatsParsers.sensors(Fixtures.sensorsJSON))
        #expect(r.perCoreTemp == [41, 43, 39, 44])      // Core 0…3, kolejność z klucza
        #expect(r.packageTemp == 45)
    }

    @Test("Wentylatory zachowują numer z klucza fanN_input i są po nim posortowane")
    func parsesFansWithIndex() throws {
        // To jest sedno P2-06: `sensors -j` wraca jako słownik, więc kolejność obchodu
        // jest nieokreślona — numer musi pochodzić z klucza, nie z pozycji w tablicy.
        let r = try #require(StatsParsers.sensors(Fixtures.sensorsJSON))
        #expect(r.fans.map(\.index) == [1, 2, 3])
        #expect(r.fans.map(\.rpm) == [1234, 876, 0])
    }

    @Test("Wynik jest stabilny mimo nieokreślonej kolejności słownika JSON")
    func fanOrderIsStableAcrossRuns() throws {
        // Ten sam wynik przy wielu przebiegach — gdyby numer był brany z kolejności
        // obchodu, ten test potrafiłby raz przejść, raz nie.
        let expected = try #require(StatsParsers.sensors(Fixtures.sensorsJSON)).fans
        for _ in 0..<50 {
            let again = try #require(StatsParsers.sensors(Fixtures.sensorsJSON))
            #expect(again.fans == expected)
        }
    }

    @Test("Niepoprawny JSON nie wywraca parsera")
    func sensorsRejectsGarbage() {
        #expect(StatsParsers.sensors("to nie jest JSON") == nil)
        #expect(StatsParsers.sensors("") == nil)
    }

    // MARK: - nvidia-smi

    @Test("CSV z nvidia-smi wypełnia wszystkie sześć pól")
    func parsesGPU() throws {
        let g = try #require(StatsParsers.gpu(Fixtures.nvidiaCSV, into: GPUStats()))
        #expect(g.name == "NVIDIA GeForce GTX 1650")
        #expect(g.utilization == 12)
        #expect(g.temperature == 45)
        #expect(g.memoryUsed == 512)
        #expect(g.memoryTotal == 3903)
        #expect(g.powerWatts == 24.35)
    }

    @Test("Puste wyjście (sterownik nieaktywny) nie kasuje znanej nazwy karty")
    func gpuKeepsNameWhenDriverInactive() {
        var known = GPUStats()
        known.name = "NVIDIA GeForce GTX 1650"
        #expect(StatsParsers.gpu("", into: known) == nil)
        #expect(StatsParsers.gpu("\n  \n", into: known) == nil)
    }

    // MARK: - SMART

    @Test("extractJSON wycina blok spomiędzy banera MOTD i „Connection closed”")
    func extractsJSONFromNoisyOutput() throws {
        let json = try #require(StatsParsers.extractJSON(Fixtures.smartctlWithBanner))
        #expect(json.hasPrefix("{"))
        #expect(json.hasSuffix("}"))
        let data = try #require(json.data(using: .utf8))
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])
    }

    @Test("Wyjście bez nawiasów klamrowych daje nil zamiast śmieci")
    func extractJSONRejectsNonJSON() {
        #expect(StatsParsers.extractJSON("smartctl: command not found") == nil)
    }

    @Test("SMART dysku ATA: werdykt, temperatura i wagi wskaźników krytycznych")
    func parsesAtaSmart() throws {
        let json = try #require(StatsParsers.extractJSON(Fixtures.smartctlWithBanner))
        let data = try #require(json.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let r = StatsParsers.smart(obj)

        #expect(r.ok)
        #expect(r.passed == true)
        #expect(r.temperature == 38)
        #expect(r.powerOnHours == 21453)
        #expect(r.model == "WDC WD40EFRX-68N32N0")
        #expect(r.selfTestStatus == "completed without error")

        // Kontrakt zmieniony 2026-08-19: parser zwraca **wszystkie** wskaźniki dysku,
        // a nie tylko sześć wybranych. Dysk bez ani jednego wskaźnika z listy krytycznej
        // (NONAME S100 przez USB) pokazywał wcześniej pustą sekcję — patrz
        // `DiskUsagePowerTests.ssdUsbMaWskazniki`.
        // Krytycznych nadal cztery; reszta jedzie jako informacyjne, bez oceny.
        #expect(r.attributes.filter(\.critical).count == 4)
        #expect(r.attributes.count > 4)
        #expect(r.attributes.contains { $0.name == "Temperatura" && !$0.critical })
        #expect(r.attributes.first { $0.name == "Sektory przydzielone ponownie" }?.severity == .ok)
        // 198 = sektory nieodwracalne, krytyczne przy każdej wartości > 0.
        #expect(r.attributes.first { $0.name == "Sektory nieodwracalne" }?.severity == .crit)
        // 199 = błędy CRC (kabel SATA) — niepokojące, ale nie krytyczne.
        #expect(r.attributes.first { $0.name == "Błędy CRC (kabel SATA)" }?.severity == .warn)
    }

    @Test("SMART dysku NVMe: zużycie z osobnego logu zdrowia")
    func parsesNVMeSmart() throws {
        let data = try #require(Fixtures.smartctlNVMe.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let r = StatsParsers.smart(obj)

        #expect(r.temperature == 41)
        #expect(r.powerOnHours == 8123)
        #expect(r.attributes.first { $0.name == "Zużycie SSD" }?.value == "73%")
        #expect(r.attributes.first { $0.name == "Zużycie SSD" }?.severity == .warn)   // 70…89 %
        #expect(r.attributes.first { $0.name == "Ostrzeżenia krytyczne" }?.severity == .ok)
    }

    @Test("Identyfikatory wskaźników SMART są stabilne między odczytami")
    func smartAttributeIDsAreStable() throws {
        let data = try #require(Fixtures.smartctlNVMe.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Przy `id = UUID()` te dwa odczyty miałyby różne tożsamości i ForEach
        // przebudowywałby całą listę przy każdym odświeżeniu.
        #expect(StatsParsers.smart(obj).attributes.map(\.id) == StatsParsers.smart(obj).attributes.map(\.id))
    }

    // MARK: - Kanały PWM

    @Test("Kanały PWM: ścieżka, wartość i tryb; wiersz ze średnikiem odrzucony")
    func parsesPWMChannels() {
        let rows = StatsParsers.pwmChannels(Fixtures.pwmChannels)
        #expect(rows.count == 2)
        #expect(rows.map(\.path) == ["/sys/class/hwmon/hwmon2/pwm1", "/sys/class/hwmon/hwmon2/pwm2"])
        #expect(rows[0].value == 128)
        #expect(rows[0].mode == "1")
        #expect(rows[1].mode == "2")
        // Wstrzyknięcie `…/pwm1;reboot` nie może przejść walidacji (P3-01).
        #expect(!rows.contains { $0.path.contains(";") })
    }

    @Test("id kanału PWM to ścieżka — suwak nie resetuje pozycji przy odświeżeniu")
    func pwmChannelIDIsPath() {
        let rows = StatsParsers.pwmChannels(Fixtures.pwmChannels)
        #expect(rows.map(\.id) == rows.map(\.path))
    }

    // MARK: - Tłumaczenie błędów sterownika

    @Test("Secure Boot rozpoznany po komunikacie jądra")
    func explainsSecureBoot() {
        let out = "modprobe: ERROR: could not insert 'nvidia': Key was rejected by service"
        #expect(StatsParsers.driverError(out)?.contains("Secure Boot") == true)
    }

    @Test("Nierozpoznany błąd nie dostaje zmyślonego wyjaśnienia")
    func doesNotInventExplanations() {
        #expect(StatsParsers.driverError("modprobe: coś zupełnie innego") == nil)
    }

    // MARK: - lscpu (charakterystyka procesora)

    /// Wejście skrócone z prawdziwego `LC_ALL=C lscpu` na serwerze testowym (i5-8500T).
    private static let lscpuOutput = """
    Architecture:                       x86_64
    CPU op-mode(s):                     32-bit, 64-bit
    CPU(s):                             6
    On-line CPU(s) list:                0-5
    Model name:                         Intel(R) Core(TM) i5-8500T CPU @ 2.10GHz
    Thread(s) per core:                 1
    Core(s) per socket:                 6
    Socket(s):                          1
    CPU max MHz:                        3500.0000
    CPU min MHz:                        800.0000
    Virtualization:                     VT-x
    L2 cache:                           1.5 MiB (6 instances)
    L3 cache:                           9 MiB (1 instance)
    """

    @Test("lscpu wyciąga wątki, rdzenie, gniazda i taktowanie")
    func lscpuReadsCoreFacts() {
        let d = StatsParsers.lscpu(Self.lscpuOutput)
        #expect(d.threads == 6)
        #expect(d.coresPerSocket == 6)
        #expect(d.threadsPerCore == 1)
        #expect(d.sockets == 1)
        #expect(d.maxMHz == 3500)
        #expect(d.minMHz == 800)
        #expect(d.architecture == "x86_64")
        #expect(d.virtualization == "VT-x")
        #expect(d.isEmpty == false)
    }

    /// Nawias z liczbą instancji rozpycha wiersz w kaflu, a odpowiedzią na pytanie
    /// „ile jest cache'u" jest sam rozmiar.
    @Test("Rozmiar cache jest bez dopisku o liczbie instancji")
    func lscpuTrimsCacheInstances() {
        let d = StatsParsers.lscpu(Self.lscpuOutput)
        #expect(d.l3 == "9 MiB")
        #expect(d.l2 == "1.5 MiB")
    }

    /// `lscpu` zmienił nazwę klucza w util-linux 2.38 — parser bierze pierwszy pasujący
    /// prefiks, więc obie formy muszą dawać ten sam wynik.
    @Test("Nowa nazwa klucza L3 cache (sum) też jest rozpoznawana")
    func lscpuAcceptsSumKey() {
        let d = StatsParsers.lscpu("L3 cache (sum):   16 MiB (2 instances)")
        #expect(d.l3 == "16 MiB")
    }

    @Test("Puste wyjście daje pusty wynik, a nie wartości z sufitu")
    func lscpuEmptyStaysEmpty() {
        let d = StatsParsers.lscpu("")
        #expect(d.isEmpty)
        #expect(d.threads == nil)
        #expect(d.l3 == nil)
    }

}
