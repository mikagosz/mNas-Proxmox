import Testing
import Foundation
@testable import mNas

/// Ustawienia panelu paska menu — P14.
///
/// Zgłoszenie 2026-08-29: *„chcę dodać ustawienia do małego okienka z ikony menu bar,
/// aby mógł dostosować co chcę, aby tam się wyświetlało — a najlepiej, jeżeli chcę mieć
/// dwa okna, to żeby to okienko dzieliło się na pół, dwie sekcje, lub też jak chcę
/// więcej, to do przewijania strzałkami"*.
///
/// Reguła podziału siedzi w modelu, a nie w widoku, właśnie po to, żeby dała się
/// zmierzyć tutaj — bez uruchamiania interfejsu.
@Suite("Ustawienia panelu: jeden na całość, dwa na pół, więcej na strzałki")
struct UstawieniaPaneluTests {

    private func ustawienia(_ moduly: [ModulPanelu]) -> UstawieniaPanelu {
        UstawieniaPanelu(moduly: moduly)
    }

    // MARK: - Rozmiar decyduje o podziale, nie liczba pozycji

    /// 🔴 Zgłoszenie po teście 1.0.39: *„teraz jest wymuszenie tylko na pół"*.
    /// Podział bierze się z **rozmiaru wybranego przez użytkownika**, a nie z tego, ile rzeczy
    /// zaznaczył. Ten test pilnuje, żeby wymuszenie nie wróciło.
    @Test("Pozycja ustawiona na „całe” zajmuje stronę sama, choć obok są inne")
    func caleNieDzieliSiePolem() {
        var u = ustawienia([.wToku, .wymagaUwagi])
        u.ustawRozmiar(.cale, dla: .wToku)
        #expect(u.liczbaStron == 2)
        #expect(u.moduly(naStronie: 0) == [.wToku])
        #expect(u.moduly(naStronie: 1) == [.wymagaUwagi])
    }

    @Test("Dwie połówki dzielą jedną stronę, bez strzałek")
    func dwiePolowkiNaStronie() {
        let u = ustawienia([.wToku, .wymagaUwagi])
        #expect(u.liczbaStron == 1)
        #expect(!u.maStrzalki)
        #expect(u.moduly(naStronie: 0) == [.wToku, .wymagaUwagi])
    }

    @Test("Jedna pozycja zajmuje panel w całości")
    func jednaNaCalosc() {
        let u = ustawienia([.transfery])
        #expect(u.liczbaStron == 1)
        #expect(!u.maStrzalki)
        #expect(u.moduly(naStronie: 0) == [.transfery])
    }

    /// Ostatnia połówka bez pary zostaje na stronie sama — pół pustego panelu wygląda
    /// jak brakujące dane, a nie jak wybór.
    @Test("Nieparzysta liczba połówek nie zostawia pustej połowy strony")
    func nieparzystePolowki() {
        let u = ustawienia([.wToku, .wymagaUwagi, .ostatniePrzebiegi])
        #expect(u.liczbaStron == 2)
        #expect(u.moduly(naStronie: 1) == [.ostatniePrzebiegi])
    }

    /// Strzałki chodzą w kółko. Panel bez zawinięcia zmuszałby do klikania w tę
    /// i z powrotem, a to jest okienko na 340 pt, nie przeglądarka.
    @Test("Strony zawijają się w obie strony")
    func stronyWKolko() {
        let u = ustawienia([.wToku, .wymagaUwagi, .transfery, .miejsce, .zdarzenia])
        #expect(u.liczbaStron == 3)
        #expect(u.moduly(naStronie: 3) == u.moduly(naStronie: 0))
        #expect(u.moduly(naStronie: -1) == u.moduly(naStronie: 2))
        #expect(u.moduly(naStronie: -4) == u.moduly(naStronie: 2))
    }

    // MARK: - Kafle z okna głównego

    /// Zgłoszenie: *„chcę móc dodać 1:1 kafelek z pełnego ekranu"*. Lista panelu
    /// obejmuje **wszystkie** kafle okna, nie garść wybranych przeze mnie.
    @Test("Lista panelu zna wszystkie kafle okna głównego")
    func wszystkieKafleNaLiscie() {
        #expect(ModulPanelu.skroty.count == 7)
        #expect(ModulPanelu.kafleOkna.count == DashTileID.allCases.count)
        #expect(ModulPanelu.allCases.count == 7 + DashTileID.allCases.count)
        for id in DashTileID.allCases {
            #expect(ModulPanelu.allCases.contains(ModulPanelu.kafel(id)))
        }
    }

    @Test("Kafel zna swój identyfikator z okna, skrót nie udaje kafla")
    func rozpoznawanieKafla() {
        #expect(ModulPanelu.kafel(.cpu).kafel == .cpu)
        #expect(ModulPanelu.kafel(.cpu).rawValue == "kafel.cpu")
        #expect(ModulPanelu.kafel(.cpu).tytul == DashTileID.cpu.title)
        #expect(ModulPanelu.transfery.kafel == nil)
        #expect(!ModulPanelu.transfery.czyKafelOkna)
    }

    /// Kafel niesie wykres albo listę i w połowie panelu (200 pt) robi się nieczytelny —
    /// stąd inna wartość domyślna niż dla skrótu. To domyślność, nie przymus.
    @Test("Kafel domyślnie na całą stronę, skrót na pół")
    func domyslneRozmiary() {
        let u = ustawienia([.wToku, .kafel(.cpu)])
        #expect(u.rozmiar(.wToku) == .pol)
        #expect(u.rozmiar(.kafel(.cpu)) == .cale)
        #expect(u.liczbaStron == 2)
        #expect(u.moduly(naStronie: 1) == [.kafel(.cpu)])
    }

    @Test("Kafel przestawiony na pół dzieli stronę ze skrótem")
    func kafelNaPol() {
        var u = ustawienia([.wToku, .kafel(.cpu)])
        u.ustawRozmiar(.pol, dla: .kafel(.cpu))
        #expect(u.liczbaStron == 1)
        #expect(u.moduly(naStronie: 0) == [.wToku, .kafel(.cpu)])
    }

    /// Zapis to zwykły napis, więc plik config sprzed dodania kafli wczytuje się bez
    /// migracji — a nowy zapis czyta się z powrotem tak samo.
    @Test("Zapis i odczyt pozycji przeżywa podróż przez JSON")
    func codableWObieStrony() throws {
        var u = ustawienia([.wToku, .kafel(.disks)])
        u.ustawRozmiar(.pol, dla: .kafel(.disks))
        let dane = try JSONEncoder().encode(u)
        let tekst = String(decoding: dane, as: UTF8.self)
        #expect(tekst.contains("kafel.disks"))
        let wrocone = try JSONDecoder().decode(UstawieniaPanelu.self, from: dane)
        #expect(wrocone == u)
        #expect(wrocone.rozmiar(.kafel(.disks)) == .pol)
    }

    /// 🔴 Kontrola tego, że plik sprzed dodania pola wczytuje się **w całości**.
    /// Bez własnego dekodera brakujący klucz wywracał `KonfiguracjaUkladu`, a razem
    /// z nią przepadał układ kafli — objaw nie do odróżnienia od P13.
    @Test("Plik config bez sekcji panelu nie kasuje układu kafli")
    func staryPlikConfigSieWczytuje() throws {
        let stary = Data(#"{"wersjaZapisu":1,"kolejnosc":["cpu","ram"],"pozycje":{}}"#.utf8)
        let k = try JSONDecoder().decode(KonfiguracjaUkladu.self, from: stary)
        #expect(k.kolejnosc == ["cpu", "ram"])
        #expect(k.panelPaska.wybrane == UstawieniaPanelu.domyslne)
        #expect(k.zablokowane.isEmpty)
    }

    @Test("Stary zapis bez rozmiarów wczytuje się i dostaje wartości domyślne")
    func staryZapisSieWczytuje() throws {
        let stary = Data(#"{"moduly":["wToku","transfery"]}"#.utf8)
        let u = try JSONDecoder().decode(UstawieniaPanelu.self, from: stary)
        #expect(u.wybrane == [.wToku, .transfery])
        #expect(u.rozmiar(.transfery) == .pol)
        #expect(u.liczbaStron == 1)
    }

    // MARK: - Wybór

    /// 🔴 Pusty panel wygląda dokładnie jak zepsuty panel, a użytkownik nie miałby z niego
    /// drogi powrotnej do ustawień.
    @Test("Ostatniego modułu nie da się wyłączyć")
    func ostatniZostaje() {
        var u = ustawienia([.transfery])
        u.przelacz(.transfery)
        #expect(u.wybrane == [.transfery])
    }

    @Test("Wyłączenie działa, dopóki zostaje więcej niż jeden")
    func wylaczenieDziala() {
        var u = ustawienia([.wToku, .transfery])
        u.przelacz(.wToku)
        #expect(u.wybrane == [.transfery])
    }

    /// Kolejność w panelu ma być stała, a nie taka, w jakiej użytkownik klikał — inaczej
    /// odznaczenie i ponowne zaznaczenie przestawiałoby moduły pod ręką.
    @Test("Włączony moduł wraca na swoje miejsce w kolejności, nie na koniec")
    func kolejnoscStala() {
        var u = ustawienia([.zdarzenia, .miejsce])
        u.przelacz(.wToku)
        #expect(u.wybrane == [.wToku, .zdarzenia, .miejsce])
    }

    /// Użytkownik, który nigdy nie otworzył ustawień, ma dostać dokładnie to, co panel
    /// pokazywał przed P14.
    @Test("Pusty wybór znaczy układ domyślny, nie pusty panel")
    func pustyWyborToDomyslne() {
        let u = ustawienia([])
        #expect(u.wybrane == UstawieniaPanelu.domyslne)
        #expect(u.moduly(naStronie: 0).count == 2)
        #expect(u.maStrzalki)
    }

    /// Siedem skrótów po pół to cztery strony (ostatnia z jedną pozycją), a osiemnaście
    /// kafli domyślnie po całej stronie dokłada osiemnaście kolejnych.
    @Test("Komplet pozycji rozkłada się na strony bez gubienia żadnej")
    func komplet() {
        let u = ustawienia(ModulPanelu.allCases)
        #expect(u.liczbaStron == 4 + DashTileID.allCases.count)
        #expect(u.strony.flatMap { $0 }.count == ModulPanelu.allCases.count)
        #expect(u.strony.allSatisfy { !$0.isEmpty && $0.count <= 2 })
    }
}

/// Trwałość wyboru — ta sama reguła, która domknęła P13: stan programu żyje w pliku
/// config, więc przeżywa podmianę wersji.
///
/// 🔴 Magazyn pod testami jest **przekierowany na plik tymczasowy, a nie wyłączony**.
/// Wyłączony zapis dałby test, który przechodzi dlatego, że nic się nie zapisuje.
@MainActor
@Suite("Ustawienia panelu przeżywają restart programu", .serialized)
struct TrwaloscUstawienPaneluTests {

    @Test("Kontrola dodatnia: świeży plik nie ma zapisanego wyboru")
    func swiezyPlikNiePamieta() {
        let uklad = UkladTestowy.uklad("panel-kontrola")
        #expect(uklad.panelPaska.wybrane == UstawieniaPanelu.domyslne)
    }

    @Test("Wybór wraca po ponownym uruchomieniu")
    func wyborPrzezywaRestart() {
        let magazyn = UkladTestowy.magazyn("panel-trwalosc")
        let uklad = DashboardLayout(magazyn: magazyn)
        uklad.panelPaska.przelacz(.transfery)
        uklad.panelPaska.przelacz(.zdarzenia)
        let oczekiwane = uklad.panelPaska.wybrane

        let poRestarcie = DashboardLayout(magazyn: MagazynUkladu(plik: magazyn.plik))
        #expect(poRestarcie.panelPaska.wybrane == oczekiwane)
        #expect(poRestarcie.panelPaska.zawiera(.transfery))
        #expect(!poRestarcie.panelPaska.zawiera(.zdarzenia))
    }
}

/// Ręczna kolejność pozycji panelu (1.2.2).
///
/// Zgłoszenie 2026-09-04: *„daj mi możliwość przesuwania w opcjach, żebym to ja
/// decydował jakie informacje są obok siebie"*. Kolejność ma znaczenie, bo pozycje
/// „pół" idą **parami na stronę** — to ona decyduje, co z czym sąsiaduje.
@Suite("Panel: kolejność ustawia użytkownik")
struct KolejnoscPanelutests {

    private func ustawienia(_ m: [ModulPanelu]) -> UstawieniaPanelu {
        UstawieniaPanelu(moduly: m)
    }

    @Test("Przesunięcie w górę zamienia sąsiadów miejscami")
    func wGore() {
        var u = ustawienia([.wToku, .zdarzenia, .wymagaUwagi])
        u.przesun(.wymagaUwagi, o: -1)
        #expect(u.wybrane == [.wToku, .wymagaUwagi, .zdarzenia])
    }

    @Test("Przesunięcie w dół działa symetrycznie")
    func wDol() {
        var u = ustawienia([.wToku, .zdarzenia, .wymagaUwagi])
        u.przesun(.wToku, o: 1)
        #expect(u.wybrane == [.zdarzenia, .wToku, .wymagaUwagi])
    }

    @Test("Poza zakres nie wychodzimy i nie zawijamy")
    func brzegi() {
        var u = ustawienia([.wToku, .zdarzenia])
        u.przesun(.wToku, o: -1)
        #expect(u.wybrane == [.wToku, .zdarzenia])   // pierwszy w górę — bez zmian
        u.przesun(.zdarzenia, o: 1)
        #expect(u.wybrane == [.wToku, .zdarzenia])   // ostatni w dół — bez zmian
    }

    @Test("KONTROLA DODATNIA: ten sam ruch w dozwoloną stronę jednak przestawia")
    func kontrolaDodatnia() {
        // Bez tego test brzegów przechodziłby także wtedy, gdyby przesun() nie robiło
        // nic w ogóle.
        var u = ustawienia([.wToku, .zdarzenia])
        u.przesun(.zdarzenia, o: -1)
        #expect(u.wybrane == [.zdarzenia, .wToku])
    }

    @Test("Moduł spoza wybranych nie rusza listy")
    func obcy() {
        var u = ustawienia([.wToku, .zdarzenia])
        u.przesun(.wymagaUwagi, o: -1)
        #expect(u.wybrane == [.wToku, .zdarzenia])
    }

    @Test("🔴 Po ręcznym ułożeniu zaznaczenie modułu NIE przesortowuje listy")
    func zaznaczenieNiePsujeKolejnosci() {
        // To jest sedno zgłoszenia: przed poprawką `przelacz` sortował listę wg
        // ModulPanelu.allCases, więc ustawiona ręcznie para rozpadała się przy
        // najbliższym zaznaczeniu czegokolwiek.
        var u = ustawienia([.zdarzenia, .wToku])
        u.przesun(.zdarzenia, o: 1)                 // ustawia flagę własnej kolejności
        let poPrzesunieciu = u.wybrane
        u.przelacz(.wymagaUwagi)                    // dokładamy moduł
        #expect(Array(u.wybrane.prefix(poPrzesunieciu.count)) == poPrzesunieciu)
        #expect(u.wybrane.last == .wymagaUwagi)     // nowy dokleja się na końcu
    }

    @Test("Kto strzałek nie tknął, dostaje kolejność domyślną jak dotąd")
    func bezWlasnejKolejnosciSortujeJakZawsze() {
        var u = ustawienia([.zdarzenia])
        u.przelacz(.wToku)
        let porzadek = ModulPanelu.allCases
        let idx = u.wybrane.compactMap { porzadek.firstIndex(of: $0) }
        #expect(idx == idx.sorted())
    }

    @Test("Zapis sprzed 1.2.2 wczytuje się, a kolejność jest wtedy domyślna")
    func staryZapis() throws {
        // Klucza `wlasnaKolejnosc` w takim pliku nie ma. Ma się wczytać jako false,
        // a nie wywrócić odczyt całej konfiguracji.
        let json = #"{"moduly":[],"rozmiary":{}}"#.data(using: .utf8)!
        let u = try JSONDecoder().decode(UstawieniaPanelu.self, from: json)
        #expect(u.wlasnaKolejnosc == false)
        #expect(u.wybrane == UstawieniaPanelu.domyslne)
    }

    @Test("Ręczna kolejność przeżywa zapis i odczyt")
    func kolejnoscPrzezywaZapis() throws {
        var u = ustawienia([.wToku, .zdarzenia, .wymagaUwagi])
        u.przesun(.wymagaUwagi, o: -1)
        let dane = try JSONEncoder().encode(u)
        let wczytane = try JSONDecoder().decode(UstawieniaPanelu.self, from: dane)
        #expect(wczytane.wybrane == u.wybrane)
        #expect(wczytane.wlasnaKolejnosc)
    }
}

/// Podgląd rozmieszczenia w ustawieniach panelu (1.2.4).
///
/// Zgłoszenie 2026-09-04: *„klikając w strzałki ja nie widzę, gdzie teraz będzie
/// stało okno"*. Strzałki zmieniały listę, której w ekranie ustawień nie było widać —
/// sekcje wypisują wszystkie dostępne moduły w stałym porządku.
@Suite("Panel: widać, gdzie pozycja wyląduje")
struct PolozenieModulowTests {

    /// Dwie „pół" na stronę — reguła podziału siedzi w `strony`.
    private func polowki(_ m: [ModulPanelu]) -> UstawieniaPanelu {
        var u = UstawieniaPanelu(moduly: m)
        for x in m { u.ustawRozmiar(.pol, dla: x) }
        return u
    }

    @Test("Dwie pierwsze pozycje to góra i dół strony pierwszej")
    func pierwszaStrona() throws {
        let u = polowki([.wToku, .wymagaUwagi])
        let a = try #require(u.polozenie(.wToku))
        let b = try #require(u.polozenie(.wymagaUwagi))
        #expect(a.strona == 1 && a.opis == "góra")
        #expect(b.strona == 1 && b.opis == "dół")
    }

    @Test("Trzecia pozycja przechodzi na stronę drugą")
    func drugaStrona() throws {
        let u = polowki([.wToku, .wymagaUwagi, .zdarzenia])
        let c = try #require(u.polozenie(.zdarzenia))
        #expect(c.strona == 2)
    }

    @Test("Przesunięcie zmienia to, co pokazuje podgląd")
    func podgladIdzieZaStrzalka() throws {
        var u = polowki([.wToku, .wymagaUwagi, .zdarzenia])
        #expect(try #require(u.polozenie(.zdarzenia)).strona == 2)
        u.przesun(.zdarzenia, o: -1)          // na miejsce drugie
        let po = try #require(u.polozenie(.zdarzenia))
        #expect(po.strona == 1)
        #expect(po.opis == "dół")
        // A wypchnięty sąsiad ląduje tam, gdzie było zdarzenie.
        #expect(try #require(u.polozenie(.wymagaUwagi)).strona == 2)
    }

    @Test("Pozycja „całe” zajmuje stronę sama")
    func cale() throws {
        var u = UstawieniaPanelu(moduly: [.wToku, .wymagaUwagi])
        u.ustawRozmiar(.cale, dla: .wToku)
        u.ustawRozmiar(.pol, dla: .wymagaUwagi)
        let a = try #require(u.polozenie(.wToku))
        #expect(a.strona == 1)
        #expect(a.opis == "całe okienko")
        #expect(try #require(u.polozenie(.wymagaUwagi)).strona == 2)
    }

    @Test("Moduł niewybrany nie ma położenia")
    func niewybrany() {
        let u = polowki([.wToku])
        #expect(u.polozenie(.zdarzenia) == nil)
    }

    @Test("KONTROLA DODATNIA: wybrany moduł położenie ma")
    func kontrolaDodatnia() {
        let u = polowki([.wToku])
        #expect(u.polozenie(.wToku) != nil)
    }
}
