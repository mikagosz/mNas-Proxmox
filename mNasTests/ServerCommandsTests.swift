import Testing
import Foundation
import SwiftUI
@testable import mNas

/// Testy higieny wejścia — wszystko, co trafia do powłoki roota na serwerze.
@Suite("Budowanie komend serwera")
struct ServerCommandsTests {

    @Test("safeName przepuszcza tylko litery, cyfry, podkreślenie i myślnik")
    func safeNameFiltersShellMetacharacters() {
        #expect(ServerCommands.safeName("tank") == "tank")
        #expect(ServerCommands.safeName("pool-1_backup") == "pool-1_backup")
        #expect(ServerCommands.safeName("tank; rm -rf /") == "tankrm-rf")
        #expect(ServerCommands.safeName("$(whoami)") == "whoami")
        #expect(ServerCommands.safeName("`id`") == "id")
    }

    @Test("shellQuote domyka apostrofy wewnątrz cytowanego łańcucha")
    func shellQuoteEscapesQuotes() {
        #expect(ServerCommands.shellQuote("zpool status") == "'zpool status'")
        // Klasyczna ucieczka z pojedynczego cytowania: zamknij, wstaw \', otwórz z powrotem.
        #expect(ServerCommands.shellQuote("it's") == "'it'\\''s'")
        #expect(ServerCommands.shellQuote("a'; rm -rf /; '") == "'a'\\''; rm -rf /; '\\'''")
    }

    // MARK: - Walidacja ścieżki PWM (P3-01)

    @Test("Poprawne ścieżki sysfs przechodzą")
    func acceptsRealPWMPaths() {
        #expect(ServerCommands.isValidPWMPath("/sys/class/hwmon/hwmon2/pwm1"))
        #expect(ServerCommands.isValidPWMPath("/sys/class/hwmon/hwmon0/pwm3"))
    }

    @Test("Sam przedrostek nie wystarczy — metaznaki powłoki są odrzucane")
    func rejectsInjectionAttempts() {
        // To był realny problem: guard sprawdzał tylko hasPrefix + contains("pwm"),
        // więc taka ścieżka trafiała prosto do `echo 1 > …` w powłoce roota.
        #expect(!ServerCommands.isValidPWMPath("/sys/class/hwmon/hwmon2/pwm1;reboot"))
        #expect(!ServerCommands.isValidPWMPath("/sys/class/hwmon/hwmon2/pwm1 && reboot"))
        #expect(!ServerCommands.isValidPWMPath("/sys/class/hwmon/hwmon2/pwm1$(id)"))
        #expect(!ServerCommands.isValidPWMPath("/sys/class/hwmon/hwmon2/pwm1`id`"))
        #expect(!ServerCommands.isValidPWMPath("/sys/class/hwmon/hwmon2/pwm1|tee /etc/passwd"))
    }

    @Test("Ścieżki spoza hwmon i bez „pwm” są odrzucane")
    func rejectsUnrelatedPaths() {
        #expect(!ServerCommands.isValidPWMPath("/etc/shadow"))
        #expect(!ServerCommands.isValidPWMPath("/sys/class/hwmon/hwmon2/temp1_input"))
        #expect(!ServerCommands.isValidPWMPath("/sys/class/net/eth0/pwm1"))
        #expect(!ServerCommands.isValidPWMPath(""))
    }

    // MARK: - Progi PWM (P1-04)

    @Test("Dolny próg jest realną wartością, przy której wentylator jeszcze kręci")
    func pwmThresholdIsSane() {
        #expect(PWM.minimum > 0)
        #expect(PWM.minimum < PWM.maximum)
        #expect(PWM.maximum == 255)
        #expect(PWM.manualMode == 1)
    }
}

/// Stabilne tożsamości modeli — regresja tutaj oznacza migoczące listy w interfejsie.
///
/// `Alert` piszemy z nazwą modułu: SwiftUI ma własny typ o tej nazwie. W kodzie aplikacji
/// wygrywa typ z tego samego modułu, ale tutaj oba są zewnętrzne i nazwa jest niejednoznaczna.
@Suite("Tożsamości modeli")
struct ModelIdentityTests {

    @Test("Alert bierze id z uuid serwera")
    func alertUsesServerUUID() throws {
        let json = """
        [{"uuid": "abc-123", "level": "WARNING", "formatted": "Pula tank jest zdegradowana", "dismissed": false}]
        """
        let alerts = try JSONDecoder().decode([mNas.Alert].self, from: #require(json.data(using: .utf8)))
        #expect(alerts.first?.id == "abc-123")
    }

    @Test("Bez uuid id jest wyliczane z treści — i nadal takie samo po ponownym dekodowaniu")
    func alertIDIsStableWithoutUUID() throws {
        let json = """
        [{"level": "INFO", "formatted": "Scrub zakończony", "klass": "ScrubFinished"}]
        """
        let data = try #require(json.data(using: .utf8))
        let first = try JSONDecoder().decode([mNas.Alert].self, from: data)
        let second = try JSONDecoder().decode([mNas.Alert].self, from: data)
        // Przy `let id = UUID()` te dwa dekodowania dawały różne tożsamości, więc
        // ForEach przebudowywał całą listę alertów co 5 sekund.
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.first?.id == "ScrubFinished|Scrub zakończony")
    }

    @Test("Segment donuta ma id z etykiety, nie losowe")
    func donutSegmentIDIsLabel() {
        let a = DonutSegment(value: 10, color: .green, label: "Wolne")
        let b = DonutSegment(value: 20, color: .green, label: "Wolne")
        #expect(a.id == b.id)
    }

    @Test("Wentylator ma id równe numerowi czujnika")
    func fanIDIsSensorIndex() {
        #expect(FanReading(index: 2, rpm: 900).id == 2)
    }

    // MARK: - Zbieracz historii

    @Test("Instalacja zbieracza jest kompletna i niczego nie kasuje")
    func instalacjaZbieraczaJestKompletnaIBezpieczna() {
        let p = ServerCommands.poleceniInstalacjiZbieracza()
        #expect(p.contains("apt-get install -y rrdtool"))
        #expect(p.contains("base64 -d > /usr/local/bin/mnas-historia"))
        #expect(p.contains("/etc/systemd/system/mnas-historia.timer"))
        #expect(p.contains("systemctl enable --now mnas-historia.timer"))
        #expect(!p.contains("rm "))
        #expect(!p.contains(HistoriaZbieracz.katalog + "/"))   // pliki .rrd to cała historia
    }

    @Test("Wgrany skrypt to dokładnie zasób z programu")
    func instalacjaWgrywaZasobBezZmian() throws {
        let p = ServerCommands.poleceniInstalacjiZbieracza()
        let b64 = Data(HistoriaZbieracz.skrypt.utf8).base64EncodedString()
        #expect(!HistoriaZbieracz.skrypt.isEmpty)
        #expect(p.contains("echo '\(b64)' | base64 -d > /usr/local/bin/mnas-historia"))
    }

    @Test("Odczyt historii tygodnia: zakres 7 dni, krok 30 min, moc w watach")
    func odczytHistoriiDlaTygodnia() {
        let p = ServerCommands.poleceniOdczytuHistorii(.week)
        #expect(p.contains("--start -604800"))
        #expect(p.contains("--step 1800"))
        #expect(p.contains("@@WERSJA"))
        #expect(p.contains("@@BRAK"))
        #expect(p.contains("1000000,/"))   // moc: µW → W
    }

    @Test("Zakresy zbieracza zgadzają się z archiwami RRA")
    func krokiZakresow() {
        #expect(OknoRRD.allCases.map(\.krokZbieracza) == [60, 60, 1_800, 7_200, 86_400])
        #expect(OknoRRD.hour.sekundy == 3_600)
        #expect(OknoRRD.year.sekundy == 31_622_400)
    }
}
