import Testing
import Foundation
@testable import mNas

/// Testy rejestru zdarzeń — odpowiedź na zgłoszenie z 2026-08-23:
/// *„dostaje ikonka powiadomienia, ale jak otworzę okno to powiadomienie znika
/// i generalnie nie wiem co się dzieje, wiem tylko że jedna akcja, ale jak?"*.
///
/// Rzecz, o którą tu chodzi, to różnica między **„przeczytane"** a **„usunięte"**.
@MainActor
@Suite("Rejestr zdarzeń: historia, która przeżywa zgaszenie chmurki", .serialized)
struct ZdarzeniaTests {

    /// 🔴 Zestaw jest `.serialized`, bo wszystkie te testy piszą do **tego samego klucza**
    /// w `UserDefaults`. Swift Testing puszcza testy równolegle i bez wymuszonej kolejności
    /// jeden kasowałby rejestr drugiemu w połowie.
    private func czystyRejestr() -> RejestrZdarzen {
        MagazynUstawien.domyslny.removeObject(forKey: "mNasProxmox.zdarzenia")
        // 🔴 Znacznik czyszczenia też, inaczej test, który wywoła `wyczysc()`, zostawia
        // po sobie datę widoczną dla następnego — a ta decyduje, czy kafel „Zdarzenia"
        // w ogóle się pokazuje.
        MagazynUstawien.domyslny.removeObject(forKey: "mNasProxmox.zdarzeniaWyczyszczono")
        return RejestrZdarzen()
    }

    private func przebieg(_ id: String, _ stan: Przebieg.Stan, opis: String? = nil) -> Przebieg {
        Przebieg(id: id, nazwa: "Kopia na media", zrodlo: .host, stan: stan, opis: opis)
    }

    private let czas = Date(timeIntervalSince1970: 1_787_000_000)

    // MARK: - Sedno zgłoszenia

    @Test("Wpis zostaje po zdarzeniu — chmurka gaśnie, treść nie")
    func wpisZostaje() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("host.media", .udany, opis: "OK: 8.2G w 2s"),
                 poprzedniStan: .trwa, czas: czas)
        #expect(r.zdarzenia.count == 1)
        #expect(r.zdarzenia[0].nazwa == "Kopia na media")
        #expect(r.zdarzenia[0].opis == "OK: 8.2G w 2s")
        #expect(r.zdarzenia[0].stan == .udany)
        #expect(r.zdarzenia[0].poprzedniStan == .trwa)
    }

    /// Bez poprzedniego stanu „udany" nie mówi, czy coś się właśnie naprawiło,
    /// czy po prostu przeszło kolejny raz. To jest ta informacja, której brakowało.
    @Test("Zdanie do listy niesie przejście, nie sam stan końcowy")
    func zdanieNiesiePrzejscie() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("host.media", .udany), poprzedniStan: .bledny, czas: czas)
        #expect(r.zdarzenia[0].jednymZdaniem == "błąd → udany")
    }

    @Test("Bez poprzedniego stanu zostaje sam stan")
    func bezPoprzedniegoStanu() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("host.media", .cisza), poprzedniStan: nil, czas: czas)
        #expect(r.zdarzenia[0].jednymZdaniem == "brak sygnału")
    }

    @Test("Rejestr czyści się wyłącznie jawnym poleceniem")
    func czysciSieTylkoJawnie() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("host.media", .udany), poprzedniStan: .trwa, czas: czas)
        #expect(!r.zdarzenia.isEmpty)
        r.wyczysc()
        #expect(r.zdarzenia.isEmpty)
    }

    // MARK: - Kafel nie kasuje sam siebie
    //
    // Zgłoszenie 2026-08-23: *„jak w głównym kliknąłem wyczyść to kafelek zniknął
    // i się nie pojawił"*. Przycisk „Wyczyść rejestr" stał w kaflu, który pokazywał się
    // wyłącznie przy niepustym rejestrze — więc kasował z ekranu sam siebie.

    /// Świeży rejestr i rejestr wyczyszczony ręcznie są **oba puste**, ale znaczą co
    /// innego. Na tym rozróżnieniu stoi widoczność kafla.
    @Test("Nigdy nieczyszczony rejestr nie ma znacznika czyszczenia")
    func swiezyRejestrBezZnacznika() {
        #expect(czystyRejestr().wyczyszczonoKiedy == nil)
    }

    @Test("Wyczyszczenie zostawia znacznik — kafel ma po czym zostać na ekranie")
    func czyszczenieZostawiaZnacznik() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("host.media", .udany), poprzedniStan: .trwa, czas: czas)
        r.wyczysc(czas: czas)
        #expect(r.zdarzenia.isEmpty)
        #expect(r.wyczyszczonoKiedy == czas)
    }

    @Test("Znacznik czyszczenia przeżywa restart programu")
    func znacznikPrzezywaRestart() {
        let r = czystyRejestr()
        r.wyczysc(czas: czas)
        // Drugi obiekt czyta ten sam `UserDefaults` — tak jak po ponownym uruchomieniu.
        #expect(RejestrZdarzen().wyczyszczonoKiedy == czas)
    }

    /// Nowe zdarzenie znaczy, że rejestr znów ma treść — informacja „wyczyszczono o…"
    /// przestaje wtedy opisywać to, co widać na ekranie.
    @Test("Pierwsze nowe zdarzenie kasuje znacznik czyszczenia")
    func noweZdarzenieKasujeZnacznik() {
        let r = czystyRejestr()
        r.wyczysc(czas: czas)
        #expect(r.wyczyszczonoKiedy != nil)

        r.dopisz(przebieg: przebieg("host.media", .bledny), poprzedniStan: .trwa,
                 czas: czas.addingTimeInterval(3600))
        #expect(r.wyczyszczonoKiedy == nil)
        #expect(r.zdarzenia.count == 1)
    }

    // MARK: - Kolejność i tożsamość

    @Test("Najświeższe na górze")
    func najswiezszeNaGorze() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("a", .udany), poprzedniStan: .trwa, czas: czas)
        r.dopisz(przebieg: przebieg("b", .bledny), poprzedniStan: .trwa,
                 czas: czas.addingTimeInterval(60))
        #expect(r.zdarzenia.first?.stan == .bledny)
        #expect(r.zdarzenia.count == 2)
    }

    /// Ten sam mechanizm zgłasza się co noc i **każde** zgłoszenie jest osobnym
    /// zdarzeniem — tożsamość musi więc nieść czas, nie sam identyfikator przebiegu.
    @Test("Ten sam mechanizm w różnych dniach to dwa zdarzenia")
    func tenSamMechanizmDwaRazy() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("host.media", .udany), poprzedniStan: .trwa, czas: czas)
        r.dopisz(przebieg: przebieg("host.media", .udany), poprzedniStan: .trwa,
                 czas: czas.addingTimeInterval(86_400))
        #expect(r.zdarzenia.count == 2)
        #expect(r.zdarzenia[0].id != r.zdarzenia[1].id)
    }

    /// Tura odświeżania potrafi zobaczyć tę samą zmianę dwa razy, zanim stan się ustabilizuje.
    @Test("Ta sama zmiana w tej samej sekundzie to jeden wpis")
    func tenSamMomentToJedenWpis() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("host.media", .udany), poprzedniStan: .trwa, czas: czas)
        r.dopisz(przebieg: przebieg("host.media", .udany), poprzedniStan: .trwa, czas: czas)
        #expect(r.zdarzenia.count == 1)
    }

    // MARK: - Limit i trwałość

    @Test("Rejestr nie rośnie w nieskończoność")
    func limitTrzyma() {
        let r = czystyRejestr()
        for i in 0..<(RejestrZdarzen.limit + 25) {
            r.dopisz(przebieg: przebieg("host.\(i)", .udany), poprzedniStan: .trwa,
                     czas: czas.addingTimeInterval(Double(i * 60)))
        }
        #expect(r.zdarzenia.count == RejestrZdarzen.limit)
        // Ucinamy najstarsze, nie najnowsze.
        #expect(r.zdarzenia.first?.nazwa == "Kopia na media")
        #expect(r.zdarzenia.first?.czas == czas.addingTimeInterval(Double((RejestrZdarzen.limit + 24) * 60)))
    }

    /// mNas bywa zamykany częściej, niż zdarzają się kopie — historia trzymana wyłącznie
    /// w pamięci gasłaby razem z tym, o co użytkownik pyta.
    @Test("Rejestr przeżywa restart programu")
    func przezywaRestart() {
        let r = czystyRejestr()
        r.dopisz(przebieg: przebieg("host.media", .bledny, opis: "BLAD: serwer nie odpowiada"),
                 poprzedniStan: .udany, czas: czas)

        // Drugi egzemplarz czyta to samo, co zapisał pierwszy — tak jak po ponownym starcie.
        let poRestarcie = RejestrZdarzen()
        #expect(poRestarcie.zdarzenia.count == 1)
        #expect(poRestarcie.zdarzenia[0].opis == "BLAD: serwer nie odpowiada")
        #expect(poRestarcie.zdarzenia[0].zrodlo == .host)
        #expect(poRestarcie.zdarzenia[0].poprzedniStan == .udany)
    }
}
