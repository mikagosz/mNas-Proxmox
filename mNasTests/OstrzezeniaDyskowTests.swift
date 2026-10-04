import Testing
import Foundation
@testable import mNas

/// Testy treści ostrzeżeń o dyskach.
///
/// Wejścia to **zmierzone wartości z serwera testowego** (`pvesh get /nodes/pve/disks/list`,
/// 2026-08-23), nie liczby wymyślone pod test. Trzy NVMe zgłaszają `wearout` 100/98/99
/// przy `Percentage Used` 0%/2%/1%, dyski SATA — `N/A`.
@Suite("Ostrzeżenia o dyskach: który nośnik, jaki wskaźnik, jaka wartość, jaki próg")
struct OstrzezeniaDyskowTests {

    private let czas = Date(timeIntervalSince1970: 1_787_000_000)

    /// Trzy NVMe serwera testowego tak, jak podaje je API — razem z talerzem, który nie zna żywotności.
    private func dyskiTestowe() -> [Disk] {
        [
            Disk(name: "nvme0n1", model: "SSD NVME1000-C", serial: "TESTSN000002",
                 type: "NVME", size: FlexibleInt(1_000_204_886_016),
                 health: "PASSED", wearout: FlexibleInt(100)),
            Disk(name: "nvme1n1", model: "SSD NVME256-A", serial: "TESTSN00000006",
                 type: "NVME", size: FlexibleInt(256_060_514_304),
                 health: "PASSED", wearout: FlexibleInt(98)),
            Disk(name: "nvme2n1", model: "SSD_NVME512-B", serial: "TESTSN00000000004",
                 type: "NVME", size: FlexibleInt(512_110_190_592),
                 health: "PASSED", wearout: FlexibleInt(99)),
            // `wearout: "N/A"` z API dekoduje się na `nil` — talerz nie zna zużycia komórek.
            Disk(name: "sda", model: "DYSK_HDD1000A", serial: "TESTSN00000005",
                 type: "HDD", size: FlexibleInt(1_000_204_886_016),
                 health: "PASSED", wearout: FlexibleInt(nil))
        ]
    }

    // MARK: - Stan zdrowy

    @Test("Zmierzony pve nie zapala ani jednego ostrzeżenia")
    func zdrowySerwerMilczy() {
        let o = OstrzezeniaDyskow.zbierz(
            disks: dyskiTestowe(),
            temperatures: ["nvme0n1": 40, "nvme1n1": 44, "nvme2n1": 45],
            czas: czas)
        #expect(o.isEmpty)
    }

    // MARK: - Zużycie komórek

    /// 🔴 Kontrola kierunku. `wearout` z Proxmoksa to **pozostała** żywotność, nie zużycie.
    /// Pomylenie tego zapaliłoby ostrzeżenie na każdym zdrowym dysku — 98 wyglądałoby
    /// jak „98% zużycia" przy realnym 2%.
    @Test("wearout to pozostała żywotność, więc 98 znaczy 2% zużycia")
    func wearoutLiczySieOdwrotnie() {
        let dysk = Disk(name: "nvme1n1", model: "SSD NVME", serial: nil, type: "NVME",
                        size: FlexibleInt(256_060_514_304), health: "PASSED", wearout: FlexibleInt(98))
        #expect(dysk.zuzycieProcent == 2)
    }

    @Test("Zużycie powyżej progu zapala poważne ostrzeżenie z wartością i progiem")
    func zuzyciePowyzejProgu() {
        let dysk = Disk(name: "nvme1n1", model: "SSD NVME256-A", serial: nil,
                        type: "NVME", size: FlexibleInt(256_060_514_304),
                        health: "PASSED", wearout: FlexibleInt(15))   // czyli 85% zużycia
        let o = OstrzezeniaDyskow.zbierz(disks: [dysk], temperatures: [:], czas: czas)
        #expect(o.count == 1)
        #expect(o[0].nosnik == "nvme1n1")
        #expect(o[0].wskaznik == "Zużycie komórek")
        #expect(o[0].wartosc == "85%")
        #expect(o[0].prog == "80%")
        #expect(o[0].poziom == .powazne)
        #expect(o[0].czas == czas)
    }

    @Test("Dokładnie na progu ostrzeżenie już się pali")
    func rownoNaProgu() {
        let dysk = Disk(name: "nvme1n1", model: nil, serial: nil, type: "NVME",
                        size: nil, health: "PASSED", wearout: FlexibleInt(20))  // 80% zużycia
        let o = OstrzezeniaDyskow.zbierz(disks: [dysk], temperatures: [:], czas: czas)
        #expect(o.count == 1)
        #expect(o[0].wartosc == "80%")
    }

    @Test("Dysk bez żywotności (N/A) nie zgłasza zużycia")
    func brakZywotnosciNieJestOstrzezeniem() {
        let talerz = Disk(name: "sda", model: "DYSK", serial: nil, type: "HDD",
                          size: nil, health: "PASSED", wearout: FlexibleInt(nil))
        let o = OstrzezeniaDyskow.zbierz(disks: [talerz], temperatures: ["sda": 38], czas: czas)
        #expect(o.isEmpty)
        #expect(talerz.zuzycieProcent == nil)
    }

    @Test("Próg zużycia jest ten sam co w czujce na serwerze")
    func progZgodnyZCzujka() {
        // `PROG_ZUZYCIE=80` w /usr/local/bin/alarm-dyskow.sh na serwerze testowym.
        // Dwa różne progi znaczyłyby, że ntfy dzwoni, a apka milczy.
        #expect(OstrzezeniaDyskow.progZuzycia == 80)
    }

    // MARK: - Kondycja SMART

    @Test("FAILED zapala poważne ostrzeżenie także na zimnym dysku")
    func smartFailedNiezaleznieOdTemperatury() {
        let dysk = Disk(name: "sdb", model: "SSD250SATA1", serial: nil, type: "HDD",
                        size: nil, health: "FAILED", wearout: FlexibleInt(nil))
        let o = OstrzezeniaDyskow.zbierz(disks: [dysk], temperatures: ["sdb": 31], czas: czas)
        #expect(o.count == 1)
        #expect(o[0].wskaznik == "Kondycja SMART")
        #expect(o[0].wartosc == "FAILED")
        #expect(o[0].prog == "PASSED")
        #expect(o[0].poziom == .powazne)
        #expect(o[0].opisNosnika == "SSD250SATA1")
    }

    @Test("UNKNOWN nie jest awarią — to brak odczytu, nie werdykt")
    func nieznanaKondycjaNieAlarmuje() {
        let dysk = Disk(name: "sdc", model: "NONAME_S100", serial: nil, type: "HDD",
                        size: nil, health: "UNKNOWN", wearout: FlexibleInt(nil))
        #expect(OstrzezeniaDyskow.zbierz(disks: [dysk], temperatures: [:], czas: czas).isEmpty)
    }

    // MARK: - Temperatura

    @Test("Temperatura powyżej progu niesie nazwę nośnika, wartość i próg")
    func temperaturaPowyzejProgu() {
        let o = OstrzezeniaDyskow.zbierz(
            disks: dyskiTestowe(),
            temperatures: ["nvme0n1": 40, "nvme1n1": 44, "nvme2n1": 57],
            czas: czas)
        #expect(o.count == 1)
        #expect(o[0].nosnik == "nvme2n1")
        #expect(o[0].opisNosnika == "SSD_NVME512-B")
        #expect(o[0].wskaznik == "Temperatura")
        #expect(o[0].wartosc == "57 °C")
        #expect(o[0].prog == "55 °C")
        #expect(o[0].poziom == .uwaga)
    }

    @Test("Linijka do kafla mówi nośnik, wskaźnik, wartość i próg naraz")
    func jednaLinijkaNiesieKomplet() {
        let o = OstrzezeniaDyskow.zbierz(
            disks: dyskiTestowe(),
            temperatures: ["nvme2n1": 57],
            czas: czas)
        #expect(o[0].jednymZdaniem == "SSD_NVME512-B · temperatura 57 °C · próg 55 °C")
    }

    // MARK: - Kolejność i tożsamość

    @Test("Poważne stoją przed uwagami")
    func powazneNaGorze() {
        var dyski = dyskiTestowe()
        dyski[1].health = "FAILED"                      // nvme1n1 — poważne
        let o = OstrzezeniaDyskow.zbierz(
            disks: dyski,
            temperatures: ["nvme0n1": 61, "nvme1n1": 30],  // nvme0n1 — uwaga
            czas: czas)
        #expect(o.count == 2)
        #expect(o[0].poziom == .powazne)
        #expect(o[0].nosnik == "nvme1n1")
        #expect(o[1].poziom == .uwaga)
        #expect(o[1].nosnik == "nvme0n1")
    }

    /// Lista przelicza się co pięć sekund. Tożsamość z `UUID()` kazałaby `ForEach`
    /// przebudowywać wiersze przy każdym odświeżeniu — ta sama pułapka co przy `Alert`.
    @Test("Tożsamość wpisu jest stała między turami odświeżania")
    func tozsamoscZDanychNieZLosowania() {
        let temps = ["nvme2n1": 57.0]
        let pierwsza = OstrzezeniaDyskow.zbierz(disks: dyskiTestowe(), temperatures: temps, czas: czas)
        let druga = OstrzezeniaDyskow.zbierz(disks: dyskiTestowe(), temperatures: temps,
                                             czas: czas.addingTimeInterval(5))
        #expect(pierwsza[0].id == druga[0].id)
        #expect(pierwsza[0].id == "nvme2n1|Temperatura")
    }

    @Test("Jeden dysk potrafi zgłosić dwie różne rzeczy naraz")
    func dwaWskaznikiJednegoDysku() {
        let dysk = Disk(name: "nvme1n1", model: "SSD NVME", serial: nil, type: "NVME",
                        size: nil, health: "FAILED", wearout: FlexibleInt(5))  // 95% zużycia
        let o = OstrzezeniaDyskow.zbierz(disks: [dysk], temperatures: ["nvme1n1": 58], czas: czas)
        #expect(o.count == 3)
        #expect(Set(o.map(\.wskaznik)) == ["Kondycja SMART", "Zużycie komórek", "Temperatura"])
        // Wszystkie trzy mają różne `id`, więc żaden nie wypada z listy.
        #expect(Set(o.map(\.id)).count == 3)
    }
}
