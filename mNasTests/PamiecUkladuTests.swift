import Testing
import Foundation
@testable import mNas

/// Trwałość układu kafli — czy dashboard pamięta, gdzie co postawiono.
///
/// Zgłoszenie 2026-08-23: *„dlaczego program nie pamięta ustawień kafelków? Już kolejny
/// build i znów pomieszane kafelki mam"*.
///
/// 🔴 Zmierzona przyczyna, nie zgadnięta: w `UserDefaults` pozycje miały **3 kafle z 18**
/// (`fans`, `gpu`, `power`). Reszta nie miała zapisanej pozycji w ogóle, więc `firstFree`
/// układał je od nowa przy każdym starcie — a jego wynik zależy od tego, które kafle mają
/// w danej chwili dane. Do tego `place` **kasował** zapisy kafli chwilowo niewidocznych.
@MainActor
@Suite("Pamięć układu: kafle zostają tam, gdzie je postawiono", .serialized)
struct PamiecUkladuTests {

    /// `ustawKolumny`, nie `columns =` — samo podstawienie liczby nie znaczy jeszcze,
    /// że widok cokolwiek zmierzył, a bez pomiaru układ celowo niczego nie utrwala.
    private func czystyUklad(columns: Int = 4) -> DashboardLayout {
        UkladTestowy.uklad("pamiec", columns: columns)
    }

    private let wszystkie: [DashTileID] = [.cpu, .ram, .disks, .przebiegi]

    // MARK: - Kontrola dodatnia

    /// Bez tego reszta mogłaby przechodzić dlatego, że nic się nigdzie nie zapisuje.
    @Test("Kontrola dodatnia: świeży układ nie ma zapamiętanych pozycji")
    func swiezyUkladNiePamieta() {
        #expect(!czystyUklad().hasPinnedTiles)
    }

    // MARK: - Sedno zgłoszenia

    @Test("Utrwalenie zapisuje miejsca wszystkich kafli, nie tylko przeciąganych")
    func utrwalenieZapisujeWszystkie() {
        let uklad = czystyUklad()
        #expect(uklad.utrwalPozycje(wszystkie))

        let zapamietane = uklad.resolvedPositions(wszystkie)
        let poRestarcie = DashboardLayout()
        poRestarcie.columns = 4
        #expect(poRestarcie.resolvedPositions(wszystkie) == zapamietane)
    }

    /// 🔴 Sedno: układ ma być **ten sam**, niezależnie od tego, ile kafli miało dane
    /// w chwili pierwszego rysowania.
    @Test("Kafel, który dostał dane później, nie przestawia pozostałych")
    func poznyKafelNiePrzestawiaReszty() {
        let uklad = czystyUklad()
        // Start: serwer jeszcze nie odpowiedział, widać dwa kafle.
        uklad.utrwalPozycje([.cpu, .ram])
        let cpuNaStarcie = uklad.resolvedPositions([.cpu, .ram])[.cpu]
        let ramNaStarcie = uklad.resolvedPositions([.cpu, .ram])[.ram]

        // Dane dochodzą, dochodzą kolejne kafle.
        uklad.utrwalPozycje(wszystkie)
        let po = uklad.resolvedPositions(wszystkie)
        #expect(po[.cpu] == cpuNaStarcie)
        #expect(po[.ram] == ramNaStarcie)
    }

    @Test("Utrwalenie nie rusza kafla, który ma już swoje miejsce")
    func utrwalenieNieRuszaIstniejacych() {
        let uklad = czystyUklad()
        uklad.place(.disks, at: GridPos(col: 2, row: 2), among: wszystkie)
        #expect(uklad.resolvedPositions(wszystkie)[.disks] == GridPos(col: 2, row: 2))

        uklad.utrwalPozycje(wszystkie)
        #expect(uklad.resolvedPositions(wszystkie)[.disks] == GridPos(col: 2, row: 2))
    }

    @Test("Drugie utrwalenie nic nie zmienia — nie ma czego dopisywać")
    func drugieUtrwalenieNicNieRobi() {
        let uklad = czystyUklad()
        #expect(uklad.utrwalPozycje(wszystkie))
        #expect(!uklad.utrwalPozycje(wszystkie))
    }

    // MARK: - Druga przyczyna: kasowanie zapisów kafli bez danych

    /// 🔴 `place` robił `positions = resolved`, a `resolved` zna tylko kafle widoczne
    /// **w tej chwili**. Przestawienie jednego kafla przy rozłączonym serwerze kasowało
    /// zapamiętane miejsca całej reszty.
    @Test("Przestawienie kafla NIE kasuje miejsc kafli chwilowo bez danych")
    func przestawienieNieKasujeNieobecnych() {
        let uklad = czystyUklad()
        uklad.utrwalPozycje(wszystkie)
        let przebiegiPrzed = uklad.resolvedPositions(wszystkie)[.przebiegi]

        // Serwer milknie: widać tylko dwa kafle. Użytkownik przestawia jeden z nich.
        uklad.place(.cpu, at: GridPos(col: 3, row: 3), among: [.cpu, .ram])

        // Kafel, którego wtedy nie było, ma **zachować swój zapis**.
        //
        // 🔴 Sprawdzamy `konfiguracja.pozycje`, a nie `resolvedPositions`, i to jest
        // zmiana z 2026-08-29. Wcześniej test patrzył na rysunek — a rysunek w tym
        // ustawieniu jest inny z dobrego powodu: `cpu` ląduje w kratkach, na których
        // stoi `przebiegi`, więc od tej wersji jeden z nich schodzi na wolne pole
        // zamiast rysować się pod drugim. Zapis zostaje nietknięty i `przebiegi`
        // wraca na swoje, gdy `cpu` się odsunie. Testem tego, o co w zgłoszeniu
        // chodziło — „nie kasuj miejsc nieobecnych kafli" — jest właśnie zapis.
        #expect(uklad.konfiguracja.pozycje["przebiegi"] != nil)
        #expect(uklad.konfiguracja.pozycje["przebiegi"] == przebiegiPrzed)
    }

    @Test("Kłódka też nie kasuje miejsc kafli chwilowo bez danych")
    func klodkaNieKasujeNieobecnych() {
        let uklad = czystyUklad()
        uklad.utrwalPozycje(wszystkie)
        let przebiegiPrzed = uklad.resolvedPositions(wszystkie)[.przebiegi]

        uklad.toggleLock(.cpu, among: [.cpu, .ram])

        #expect(uklad.resolvedPositions(wszystkie)[.przebiegi] == przebiegiPrzed)
    }

    // MARK: - Współpraca z resztą

    @Test("Ściśnięcie zdejmuje zapisy, a utrwalenie zapisuje ciasny układ od nowa")
    func sciskanieIUtrwalenieWspolpracuja() {
        let uklad = czystyUklad()
        // 🔴 Kolumna **2**, nie 3: `przebiegi` to kafel `.large`, czyli szeroki na dwie
        // kratki, więc przy czterech kolumnach `clamp` przycina go do `4 - 2 = 2`.
        // Pierwsza wersja tego testu prosiła o kolumnę 3 i padała — słusznie.
        uklad.place(.przebiegi, at: GridPos(col: 2, row: 5), among: wszystkie)
        #expect(uklad.resolvedPositions(wszystkie)[.przebiegi] == GridPos(col: 2, row: 5))

        uklad.repack()
        uklad.utrwalPozycje(wszystkie)
        // Po ściśnięciu kafel stoi wyżej — i to nowe miejsce jest zapamiętane.
        let po = uklad.resolvedPositions(wszystkie)[.przebiegi]!
        #expect(po.row < 5)
        let poRestarcie = DashboardLayout()
        poRestarcie.columns = 4
        #expect(poRestarcie.resolvedPositions(wszystkie)[.przebiegi] == po)
    }

    /// Zwężenie okna przycina rysunek (`clamp`), ale **nie zapis** — po powrocie do
    /// szerokiego okna układ ma wrócić nietknięty.
    @Test("Zwężenie okna nie niszczy zapamiętanego układu")
    func zwezenieOknaNieNiszczyZapisu() {
        let uklad = czystyUklad(columns: 6)
        // 🔴 Miejsce **inne niż naturalne**. Przy ciasnym układzie `disks` i tak stanąłby
        // w (4,0), a `place` wychodzi wcześniej, gdy kafel już jest tam, gdzie ma trafić —
        // wtedy nic by się nie zapisało i test mierzyłby coś innego, niż zamierzam.
        uklad.place(.disks, at: GridPos(col: 0, row: 4), among: wszystkie)
        #expect(uklad.resolvedPositions(wszystkie)[.disks] == GridPos(col: 0, row: 4))

        uklad.columns = 2                       // okno zwężone
        uklad.utrwalPozycje(wszystkie)          // rysowanie utrwala, co może
        uklad.columns = 6                       // i z powrotem

        #expect(uklad.resolvedPositions(wszystkie)[.disks] == GridPos(col: 0, row: 4))
    }

    // MARK: - Zgłoszenie 2026-08-29: układ ginie z każdą nową wersją

    /// > [!danger] 🔴 To jest test na przyczynę, nie na objaw
    /// > `resolvedPositions` przycina pozycje do szerokości okna. Poprzednia wersja
    /// > `place` wpisywała ten przycięty wynik z powrotem do zapisu, więc jedno
    /// > przesunięcie kafla w **węższym** oknie spłaszczało cały układ na trwałe.
    /// >
    /// > Kontrola mutacyjna: po przywróceniu `positions.merge(resolved) { _, nowa in nowa }`
    /// > ten test pada.
    @Test("Przesunięcie kafla w wąskim oknie nie spłaszcza pozycji pozostałych")
    func waskieOknoNiePsujeZapisu() {
        let uklad = czystyUklad(columns: 6)
        let kafle: [DashTileID] = [.cpu, .ram, .disks, .przebiegi]

        // Użytkownik stawia `disks` w prawym górnym rogu szerokiego układu — czyli tam, gdzie
        // sam by nie trafił. Wiersz 4 celowo: gdyby cel pokrywał się z miejscem
        // naturalnym, `place` słusznie nie robiłby nic i test nie mierzyłby niczego.
        uklad.place(.disks, at: GridPos(col: 4, row: 4), among: kafle)
        #expect(uklad.konfiguracja.pozycje["disks"] == GridPos(col: 4, row: 4))

        // Okno robi się węższe: mieszczą się trzy kolumny.
        uklad.ustawKolumny(3)
        // Rysowanie ma prawo przyciąć — i przycina.
        let narysowane = uklad.resolvedPositions(kafle)
        #expect((narysowane[.disks]?.col ?? 99) <= 1)

        // …ale przesunięcie **innego** kafla nie ma prawa tego przycięcia utrwalić.
        uklad.place(.cpu, at: GridPos(col: 0, row: 8), among: kafle)
        #expect(uklad.konfiguracja.pozycje["disks"] == GridPos(col: 4, row: 4),
                "zapis `disks` został spłaszczony do szerokości okna — to jest ten błąd")
    }

    @Test("Kłódka na jednym kaflu nie przestawia zapisu pozostałych")
    func klodkaNiePsujeZapisu() {
        let uklad = czystyUklad(columns: 6)
        let kafle: [DashTileID] = [.cpu, .ram, .disks]
        uklad.place(.disks, at: GridPos(col: 4, row: 4), among: kafle)

        uklad.ustawKolumny(2)
        uklad.toggleLock(.cpu, among: kafle)

        #expect(uklad.konfiguracja.pozycje["disks"] == GridPos(col: 4, row: 4))
    }

    @Test("Bez zmierzonej szerokości okna nic się nie utrwala")
    func bezPomiaruNieUtrwalamy() {
        let uklad = DashboardLayout(magazyn: UkladTestowy.magazyn("bez-pomiaru"))
        #expect(!uklad.utrwalPozycje(wszystkie))
        #expect(!uklad.hasPinnedTiles)
    }

    // MARK: - Naprawa zderzeń w już zapisanym pliku

    /// Plik użytkownika przyszedł z `UserDefaults`, w których `cpu` i `power` **siedziały
    /// w tej samej kratce** `{col: 1, row: 0}` — zmierzone 2026-08-29.
    @Test("Dwa kafle w jednej kratce: drugi traci przypięcie, pierwszy zostaje")
    func naprawaZderzenia() {
        let wejscie: [DashTileID: GridPos] = [
            .cpu: GridPos(col: 1, row: 0),
            .power: GridPos(col: 1, row: 0),
            .ram: GridPos(col: 3, row: 0)
        ]
        let wynik = DashboardLayout.naprawKolizje(wejscie) { _ in .small }

        #expect(wynik[.ram] == GridPos(col: 3, row: 0), "kafel bez zderzenia ma zostać nietknięty")
        #expect(wynik.count == 2, "z pary zderzonych ma zostać dokładnie jeden")
        #expect(wynik[.cpu] != nil || wynik[.power] != nil)
        #expect(!(wynik[.cpu] != nil && wynik[.power] != nil))
    }

    /// Kontrola dodatnia do testu wyżej: bez zderzeń naprawa **niczego nie rusza**.
    @Test("Kontrola dodatnia: układ bez zderzeń przechodzi naprawę bez zmian")
    func naprawaNieRuszaZdrowego() {
        let wejscie: [DashTileID: GridPos] = [
            .cpu: GridPos(col: 0, row: 0),
            .power: GridPos(col: 1, row: 0),
            .ram: GridPos(col: 2, row: 0)
        ]
        #expect(DashboardLayout.naprawKolizje(wejscie) { _ in .small } == wejscie)
    }
}
