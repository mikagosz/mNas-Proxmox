import Testing
import Foundation
@testable import mNas

/// Kłódka na kaflu — blokada pozycji w trybie edycji układu.
///
/// Zgłoszenie [U] 2026-08-23: *„dodaj w edycji kafelków kłódkę, które zablokują kafelek
/// w miejscu przy edycji i się nie będzie przesuwał, bo aktualnie potrafią kafelki się
/// przestawiać jak tylko złapie inny do przesunięcia"*.
///
/// 🔴 Sedno: `DashboardLayout.place` **wypycha** każdy kafel nachodzący na upuszczany.
/// Kłódka wyjmuje kafel z tego wypychania — i to jest jedyna rzecz, którą te testy
/// naprawdę mierzą. Reszta to warunki brzegowe wokół niej.
@MainActor
@Suite("Kłódka: kafel, który nie ustępuje", .serialized)
struct KlodkaKafliTests {

    /// 🔴 `.serialized` i czyszczenie kluczy z tego samego powodu co w `ZdarzeniaTests`:
    /// `DashboardLayout` czyta i pisze `UserDefaults`, więc bez tego jeden test
    /// dziedziczyłby układ po drugim i „kafel stoi na swoim miejscu" bywałoby prawdą
    /// z cudzych danych.
    /// Wspólny magazyn dla całego zestawu — „restart programu" znaczy nowy
    /// `DashboardLayout` czytający **ten sam plik**, a nie inny.
    private static let magazyn = UkladTestowy.magazyn("klodka")

    private func czystyUklad(columns: Int = 4) -> DashboardLayout {
        Self.magazyn.wyczysc()
        let uklad = DashboardLayout(magazyn: Self.magazyn)
        uklad.ustawKolumny(columns)
        return uklad
    }

    /// Trzy małe kafle w jednym rzędzie — najprostszy układ, w którym widać wypychanie.
    private func trzyMale(_ uklad: DashboardLayout) -> [DashTileID] {
        let kafle: [DashTileID] = [.fans, .power, .gpu]
        for id in kafle where uklad.size(id) != .small {
            // `cycleSize` chodzi w kółko mały → średni → duży, więc kręcimy aż do małego.
            while uklad.size(id) != .small { uklad.cycleSize(id) }
        }
        return kafle
    }

    // MARK: - Kontrola dodatnia: bez kłódki objaw MUSI się odtwarzać

    /// 🔴 Bez tego testu cała reszta znaczyłaby „nie wiem".
    /// Jeśli kafle nie wypychają się nawzajem **bez** kłódki, to testy niżej przechodzą
    /// z powodu, który nie ma nic wspólnego z blokadą.
    @Test("Kontrola dodatnia: bez kłódki kafel USTĘPUJE miejsca")
    func bezKlodkiKafelUstepuje() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        let przed = uklad.resolvedPositions(kafle)
        let celPower = przed[.power]!

        // Kładziemy `fans` dokładnie na polu, które zajmuje `power`.
        uklad.place(.fans, at: celPower, among: kafle)

        let po = uklad.resolvedPositions(kafle)
        #expect(po[.fans] == celPower)
        // To jest objaw zgłoszony przez [U]: kafel, którego nikt nie ruszał, zmienił pole.
        #expect(po[.power] != celPower)
    }

    // MARK: - Sedno zgłoszenia

    @Test("Kafel pod kłódką NIE ustępuje — cofa się ruch, nie blokada")
    func zablokowanyNieUstepuje() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        let przed = uklad.resolvedPositions(kafle)
        let celPower = przed[.power]!

        uklad.toggleLock(.power, among: kafle)
        uklad.place(.fans, at: celPower, among: kafle)

        let po = uklad.resolvedPositions(kafle)
        #expect(po[.power] == celPower)          // stoi tam, gdzie stał
        #expect(po[.fans] == przed[.fans])       // ruch się nie odbył
    }

    @Test("Zablokowanego kafla nie da się przesunąć nawet wprost")
    func zablokowanegoNieDaSiePrzesunac() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        let przed = uklad.resolvedPositions(kafle)

        uklad.toggleLock(.fans, among: kafle)
        uklad.place(.fans, at: GridPos(col: 3, row: 2), among: kafle)

        #expect(uklad.resolvedPositions(kafle)[.fans] == przed[.fans])
    }

    /// Blokada dotyczy **pola**, nie całej siatki. Kafle, których nikt nie zablokował,
    /// mają się dalej układać normalnie — inaczej jedna kłódka zamrażałaby dashboard.
    @Test("Kłódka na jednym kaflu nie unieruchamia pozostałych")
    func klodkaNieZamrazaReszty() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        uklad.toggleLock(.power, among: kafle)

        // Wolne pole w drugim rzędzie — nie koliduje z niczym.
        uklad.place(.fans, at: GridPos(col: 0, row: 3), among: kafle)
        #expect(uklad.resolvedPositions(kafle)[.fans] == GridPos(col: 0, row: 3))
    }

    @Test("Zdjęcie kłódki przywraca zwykłe zachowanie")
    func zdjecieKlodkiPrzywraca() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        let celPower = uklad.resolvedPositions(kafle)[.power]!

        uklad.toggleLock(.power, among: kafle)
        uklad.toggleLock(.power, among: kafle)      // i z powrotem
        #expect(!uklad.isLocked(.power))

        uklad.place(.fans, at: celPower, among: kafle)
        #expect(uklad.resolvedPositions(kafle)[.power] != celPower)
    }

    // MARK: - Kłódka a reszta narzędzi układu

    /// 🔴 Gdyby „Ściśnij" zdejmowało pozycje kafli pod kłódką, jedno kliknięcie
    /// obchodziłoby blokadę tylnymi drzwiami.
    @Test("„Ściśnij” nie rusza kafli pod kłódką")
    func sciskanieNieRuszaZablokowanych() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)

        // Odsuwamy `fans` daleko, żeby powstała dziura, i blokujemy go tam.
        uklad.place(.fans, at: GridPos(col: 3, row: 3), among: kafle)
        uklad.toggleLock(.fans, among: kafle)

        uklad.repack()
        #expect(uklad.resolvedPositions(kafle)[.fans] == GridPos(col: 3, row: 3))
    }

    @Test("„Ściśnij” dalej domyka dziury po kaflach bez kłódki")
    func sciskanieDomykaDziuryPozostalych() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        uklad.place(.gpu, at: GridPos(col: 3, row: 4), among: kafle)
        #expect(uklad.resolvedPositions(kafle)[.gpu] == GridPos(col: 3, row: 4))

        uklad.repack()
        // Bez przypięcia kafel spada w pierwsze wolne pole od góry-lewej.
        #expect(uklad.resolvedPositions(kafle)[.gpu]!.row < 4)
    }

    @Test("„Resetuj układ” zdejmuje także kłódki")
    func resetZdejmujeKlodki() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        uklad.toggleLock(.power, among: kafle)
        #expect(uklad.hasLockedTiles)

        uklad.reset()
        #expect(!uklad.hasLockedTiles)
        #expect(!uklad.isLocked(.power))
    }

    @Test("Odblokowanie wszystkich zdejmuje kłódki naraz")
    func odblokowanieWszystkich() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        uklad.toggleLock(.power, among: kafle)
        uklad.toggleLock(.gpu, among: kafle)
        #expect(uklad.hasLockedTiles)

        uklad.unlockAll()
        #expect(!uklad.hasLockedTiles)
    }

    /// Przycisk „Ściśnij" pokazuje się po `hasPinnedTiles`. Same kafle pod kłódką nie
    /// mogą go zapalać — obiecywałby zmianę, która i tak nie nastąpi.
    @Test("Sama kłódka nie zapala przycisku „Ściśnij”")
    func samaKlodkaNieZapalaSciskania() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        #expect(!uklad.hasPinnedTiles)

        uklad.toggleLock(.power, among: kafle)
        // `toggleLock` przypina wszystkie kafle, ale niezablokowane dalej da się ścisnąć.
        uklad.unlockAll()
        uklad.repack()
        #expect(!uklad.hasPinnedTiles)
    }

    // MARK: - Trwałość

    @Test("Kłódki przeżywają restart programu")
    func klodkiPrzezywajaRestart() {
        let uklad = czystyUklad()
        let kafle = trzyMale(uklad)
        uklad.toggleLock(.power, among: kafle)
        let gdzieStal = uklad.resolvedPositions(kafle)[.power]!

        // Drugi obiekt czyta ten sam plik układu — tak jak po ponownym uruchomieniu.
        let poRestarcie = DashboardLayout(magazyn: Self.magazyn)
        poRestarcie.ustawKolumny(4)
        #expect(poRestarcie.isLocked(.power))
        #expect(poRestarcie.resolvedPositions(kafle)[.power] == gdzieStal)
    }
}
