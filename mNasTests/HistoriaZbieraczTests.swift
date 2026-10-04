import Testing
import Foundation
@testable import mNas

/// Zbieracz to kod, który chodzi rootem co minutę na serwerze. Testy pilnują
/// zasad, których złamanie widać dopiero po tygodniu: talerze, wersja, przekręcenie RAPL.
@Suite("Zbieracz historii: treść skryptu i jednostek")
struct HistoriaZbieraczTests {
    /// Sam kod skryptu, bez linii komentarzy — komentarze tłumaczą, czego NIE robimy,
    /// i zawierają właśnie te słowa, których w kodzie ma nie być.
    private var kod: String {
        HistoriaZbieracz.skrypt.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    @Test func skryptMaWersjeZgodnaZProgramem() {
        #expect(HistoriaZbieracz.skrypt.contains("WERSJA=\(HistoriaZbieracz.wersja)"))
    }

    /// 🔴 Za mostkiem USB `queue/rotational` kłamie — zmierzone 2026-10-04 na serwerze
    /// testowym: wszystkie cztery dyski SATA (dwa SSD, dwa talerze) mają `rotational=1`.
    /// Rozstrzyga pole udev z obrotami, czytane z bazy udev, bez dotykania dysku.
    @Test func talerzeOdsiewanePolemUdevBezDotykaniaDysku() {
        let s = kod
        #expect(s.contains("ID_ATA_ROTATION_RATE_RPM"))
        #expect(s.contains("-n standby"))
        #expect(!s.contains("queue/rotational"))
        #expect(!s.contains("smartctl -i"))
    }

    @Test func mocToDeriveZMinimumZero() {
        #expect(HistoriaZbieracz.skrypt.contains("DS:pakiet:DERIVE:120:0:U"))
    }

    @Test func bezSetE() {
        // Jedna padnięta sekcja (np. brak RAPL) nie może zabić pozostałych.
        #expect(!kod.contains("set -e"))
    }

    @Test func timerTykaJakCzujkaNieJakPrzebieg() {
        // OnUnitActiveSec = czujka w PrzebiegiParsers.mechanizmyHosta — nie zasypie kafla Przebiegi.
        #expect(HistoriaZbieracz.timer.contains("OnUnitActiveSec=60"))
        #expect(!HistoriaZbieracz.timer.contains("OnCalendar"))
    }

    @Test func uslugaUruchamiaSkrypt() {
        #expect(HistoriaZbieracz.usluga.contains("ExecStart=\(HistoriaZbieracz.sciezkaSkryptu)"))
    }

    @Test func archiwaJakWProjekcie() {
        let s = HistoriaZbieracz.skrypt
        for rra in ["1:1440", "30:336", "120:372", "1440:366"] {
            #expect(s.contains("RRA:AVERAGE:0.5:\(rra)"))
            #expect(s.contains("RRA:MIN:0.5:\(rra)"))
            #expect(s.contains("RRA:MAX:0.5:\(rra)"))
        }
    }
}
