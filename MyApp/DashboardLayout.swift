import Foundation
import os
import Observation

/// Kafelki dashboardu, które user układa sam na siatce.
///
/// Od 2026-08-16 są tu **wszystkie** sekcje, nie tylko górna: pamięć masowa, dyski,
/// usługi, alerty i narzędzia przestały być osobnymi listami pod panelem i weszły do
/// siatki jako **jeden moduł na sekcję** (a nie kafel na każdą usługę czy alert).
nonisolated enum DashTileID: String, CaseIterable, Codable {
    case cpu, guests, cpuHistory, coreUsage, coreTemp, ram, gpu, fans
    case storage, disks, services, alerts, tools
    case power
    case przebiegi
    case miejsce
    case zdarzenia
    case transfery

    var title: String {
        switch self {
        case .cpu:        return String(localized: "CPU")
        case .guests:     return String(localized: "Maszyny i kontenery")
        case .cpuHistory: return String(localized: "Zużycie CPU w czasie")
        case .coreUsage:  return String(localized: "Zużycie rdzeni")
        case .coreTemp:   return String(localized: "Temperatura rdzeni")
        case .ram:        return String(localized: "Pamięć RAM")
        case .gpu:        return String(localized: "GPU")
        case .fans:       return String(localized: "Wentylatory")
        case .storage:    return String(localized: "Pamięć masowa")
        case .disks:      return String(localized: "Dyski")
        case .services:   return String(localized: "Usługi")
        case .alerts:     return String(localized: "Alerty")
        case .tools:      return String(localized: "Narzędzia")
        case .power:      return String(localized: "Pobór mocy")
        case .przebiegi:  return String(localized: "Przebiegi")
        case .miejsce:    return String(localized: "Miejsce")
        case .zdarzenia:  return String(localized: "Zdarzenia")
        case .transfery:  return String(localized: "Transfery")
        }
    }
}

/// Rozmiar kafla — trzy stałe wielkości, decyzja użytkownika 2026-08-16.
///
/// Wymiary wynikają z modułu siatki, nie odwrotnie: kratka **144**, odstęp **12**.
/// Stąd 144 + 12 + 144 = **300**, czyli duży i średni mają równo 300 pt i każda
/// kombinacja kafli staje w jednej linii. Przy kratce 150 pt (pierwsza propozycja)
/// dwa małe dawały 312 i nic by się nie zeszło.
nonisolated enum TileSize: String, Codable, CaseIterable {
    case small      // 144 × 144
    case medium     // 300 × 144
    case large      // 300 × 300

    var cols: Int { self == .small ? 1 : 2 }
    var rows: Int { self == .large ? 2 : 1 }

    var label: String {
        switch self {
        case .small:  return String(localized: "Mały")
        case .medium: return String(localized: "Średni")
        case .large:  return String(localized: "Duży")
        }
    }

    /// Kolejny rozmiar w kółko — jeden przycisk w trybie edycji zamiast trzech.
    var next: TileSize {
        switch self {
        case .small:  return .medium
        case .medium: return .large
        case .large:  return .small
        }
    }
}

/// Miejsce kafla na siatce — kolumna i wiersz liczone w kratkach, nie w punktach.
nonisolated struct GridPos: Codable, Hashable {
    var col: Int
    var row: Int
}

/// Wymiary siatki w jednym miejscu — używa ich i układ, i same kafle.
///
/// `nonisolated`, bo czyta je `TileGrid` — typ zgodny z `Layout`, którego SwiftUI
/// woła poza MainActorem (konwencja jak w `Models.swift`).
nonisolated enum TileGeometry {
    static let cell: CGFloat = 144
    static let gap: CGFloat = 12

    static func length(_ units: Int) -> CGFloat {
        CGFloat(units) * cell + CGFloat(units - 1) * gap
    }

    static func width(_ size: TileSize) -> CGFloat { length(size.cols) }
    static func height(_ size: TileSize) -> CGFloat { length(size.rows) }
}

/// Kolejność, rozmiary, ukryte kafle i odrzucone alerty — wszystko zapisywane
/// trwale w **pliku** `uklad-kafli.json`, więc przeżywa restart programu i podmianę
/// wersji. Patrz `KonfiguracjaUkladu`.
///
/// > [!danger] 🔴 Zapisujemy pozycje **nieprzycięte do szerokości okna**
/// > To jest przyczyna zgłoszenia [U] z 2026-08-29 (*„z każdą nową wersją muszę sobie
/// > kafelki ustawiać na nowo"*), znaleziona w kodzie 2026-08-29 i naprawiona tutaj.
/// >
/// > `resolvedPositions` **przycina** (`clamp`) każdą pozycję do bieżącej liczby kolumn,
/// > bo tyle akurat mieści się w oknie. To jest poprawne **do rysowania**. Błąd polegał
/// > na tym, że `place` i `toggleLock` wpisywały ten przycięty wynik z powrotem do
/// > `positions` — czyli **do zapisu na dysku**.
/// >
/// > Skutek: układ [U] jest szeroki na pięć kolumn (`disks`, `alerts` i `miejsce` stoją
/// > w kolumnie 4). Wystarczyło, że okno było chwilowo węższe — a przy starcie jest,
/// > zanim widok zmierzy szerokość — żeby przy pierwszym przesunięciu kafla wszystkie
/// > pozycje z kolumny 4 zapisały się jako kolumna 3. Zmierzone w pliku preferencji
/// > 2026-08-29: `cpu` i `power` **siedziały w tej samej kratce** `{col: 1, row: 0}`,
/// > czego żadne pojedyncze upuszczenie nie potrafi zrobić — to ślad po zderzeniu
/// > dwóch przyciętych pozycji.
/// >
/// > Reguła, która z tego zostaje: **`clamp` wolno użyć do rysowania, nigdy do zapisu.**
@MainActor
@Observable
final class DashboardLayout {
    var order: [DashTileID]
    private var sizes: [DashTileID: TileSize]
    private var hiddenTiles: Set<DashTileID>
    /// Kafle przypięte do konkretnej kratki. Pusty słownik = układ ciasny, bez dziur.
    private var positions: [DashTileID: GridPos]
    /// Kafle **zablokowane kłódką** — nie dają się przesunąć i nigdy nie ustępują miejsca.
    ///
    /// > [!important] Po co to jest
    /// > Zgłoszenie [U] 2026-08-23: *„aktualnie potrafią kafelki się przestawiać jak tylko
    /// > złapie inny do przesunięcia"*. Przyczyna siedzi w `place`: kafel nachodzący na
    /// > upuszczany był **wypychany** na pierwsze wolne pole. Przy ciasnym układzie jedno
    /// > nieprecyzyjne upuszczenie potrafiło więc przemeblować pół dashboardu.
    /// >
    /// > Kłódka jest odpowiedzią: zablokowany kafel nie ustępuje. Zamiast niego cofa się
    /// > **ruch** — upuszczenie na zajęte, zablokowane pole po prostu nie dochodzi
    /// > do skutku i kafel wraca tam, skąd go wzięto.
    private var lockedTiles: Set<DashTileID>
    /// Ustawienia panelu paska menu — P14. Trzymane razem z układem, bo to ten sam
    /// plik konfiguracyjny i ta sama decyzja [U]: „co ma być widać i gdzie".
    var panelPaska: UstawieniaPanelu {
        didSet { if panelPaska != oldValue { persist() } }
    }
    /// Czy widok zdążył już zmierzyć szerokość okna.
    ///
    /// 🔴 Dopóki nie zmierzył, `columns` ma wartość domyślną, a `firstFree` liczy z niej
    /// miejsca dla nowych kafli. Przypięcie kafla na podstawie zgadywanej szerokości
    /// zostaje na dysku na zawsze — więc do tego czasu **nic nie utrwalamy**.
    private var kolumnyZmierzone = false

    /// Skąd i dokąd zapisuje się układ. Wstrzykiwany, żeby testy dostały własny plik
    /// zamiast prawdziwego — patrz `MagazynUkladu`.
    private let magazyn: MagazynUkladu
    /// Identyfikatory alertów odrzuconych przez użytkownika. Alert wyczyszczony ręcznie
    /// **nie wraca po odświeżeniu** — serwer nadal go zgłasza, bo Proxmox nie zna pojęcia
    /// „potwierdzony alert", więc listę odrzuconych trzyma apka.
    private var dismissedAlerts: Set<String>

    // Osobne klucze od wersji pod TrueNAS-a — obie apki stoją na tym samym Macu,
    // a zestawy kafelków się różnią (tu doszły maszyny i kontenery).
    private static let orderKey     = "mNasProxmox.dash.order"
    private static let sizeKey      = "mNasProxmox.dash.size"
    private static let hiddenKey    = "mNasProxmox.dash.hidden"
    private static let dismissedKey = "mNasProxmox.dash.dismissedAlerts"
    private static let positionKey  = "mNasProxmox.dash.positions"
    private static let lockedKey    = "mNasProxmox.dash.locked"

    /// Domyślny rozmiar dobrany do tego, ile kafel ma do pokazania: listy i pierścienie
    /// z opisem dostają duży, pojedyncza liczba — mały.
    private static let defaultSizes: [DashTileID: TileSize] = [
        .cpu: .large, .ram: .large, .guests: .large,
        .cpuHistory: .medium, .coreUsage: .medium, .coreTemp: .medium,
        .gpu: .medium, .fans: .small, .power: .small,
        .storage: .large, .disks: .large, .services: .large,
        .alerts: .large, .tools: .medium,
        .przebiegi: .large,
        .miejsce: .large,
        .zdarzenia: .large,
        .transfery: .large
    ]

    private static let defaultOrder: [DashTileID] = [
        .cpu, .ram, .guests, .alerts, .storage, .disks,
        .cpuHistory, .coreUsage, .coreTemp, .fans, .power, .gpu, .tools, .services,
        .przebiegi, .miejsce, .zdarzenia, .transfery
    ]

    init(magazyn: MagazynUkladu = .domyslny) {
        self.magazyn = magazyn
        let konf = magazyn.wczytaj() ?? Self.migracjaZUserDefaults()

        // Kafle dodane w apce po tym, jak [U] zapisał sobie układ, dochodzą na koniec.
        let zapisanaKolejnosc = konf.kolejnosc.compactMap(DashTileID.init(rawValue:))
        if zapisanaKolejnosc.isEmpty {
            order = Self.defaultOrder
        } else {
            order = zapisanaKolejnosc + Self.defaultOrder.filter { !zapisanaKolejnosc.contains($0) }
        }

        let rozmiaryLokalne = Dictionary(uniqueKeysWithValues: konf.rozmiary.compactMap { k, v -> (DashTileID, TileSize)? in
            guard let id = DashTileID(rawValue: k), let s = TileSize(rawValue: v) else { return nil }
            return (id, s)
        })
        sizes = rozmiaryLokalne
        hiddenTiles = Set(konf.ukryte.compactMap(DashTileID.init(rawValue:)))
        lockedTiles = Set(konf.zablokowane.compactMap(DashTileID.init(rawValue:)))
        dismissedAlerts = Set(konf.odrzuconeAlerty)
        panelPaska = konf.panelPaska

        // Pozycje z pliku przycięte do rozsądnych granic: plik da się edytować ręcznie,
        // a `row` bliski `Int.max` przepełniał `pos.row + size.rows` w `cells(at:)`
        // i wywracał program przy starcie. Audyt SBW 2026-09-24, E3-S-P3-01.
        let wczytane = Dictionary(uniqueKeysWithValues: konf.pozycje.compactMap { k, v in
            DashTileID(rawValue: k).map { ($0, Self.przytnijZPliku(v)) }
        })
        positions = Self.naprawKolizje(wczytane) { id in
            Self.sizesLookup(id, sizes: rozmiaryLokalne)
        }
    }

    /// Granice dla pozycji wczytanych z pliku — znacznie powyżej tego, co da się
    /// ułożyć w oknie, i daleko od przepełnienia `Int`.
    static let maksKolumnaZPliku = 64
    static let maksWierszZPliku = 10_000

    static func przytnijZPliku(_ p: GridPos) -> GridPos {
        GridPos(col: min(max(p.col, 0), maksKolumnaZPliku),
                row: min(max(p.row, 0), maksWierszZPliku))
    }

    /// Rozmiar kafla bez sięgania do jeszcze niezainicjowanego `self` — potrzebne
    /// wyłącznie w `init`, gdzie `size(_:)` nie jest jeszcze dostępne.
    private static func sizesLookup(_ id: DashTileID, sizes: [DashTileID: TileSize]) -> TileSize {
        sizes[id] ?? defaultSizes[id] ?? .medium
    }

    /// Jednorazowe przeniesienie układu ze starego zapisu w `UserDefaults` do pliku.
    ///
    /// 🔴 Starych kluczy **nie kasujemy**. Gdyby [U] wrócił do wcześniejszej wersji
    /// programu, zastanie swój układ na miejscu; plik jest wtedy po prostu ignorowany.
    /// Kasowanie zapisu, do którego nie mamy jak wrócić, jest drogą w jedną stronę.
    private static func migracjaZUserDefaults() -> KonfiguracjaUkladu {
        var konf = KonfiguracjaUkladu()
        let d = MagazynUstawien.domyslny

        if let data = d.data(forKey: orderKey),
           let saved = try? JSONDecoder().decode([DashTileID].self, from: data) {
            konf.kolejnosc = saved.map(\.rawValue)
        }
        if let data = d.data(forKey: sizeKey),
           let saved = try? JSONDecoder().decode([String: TileSize].self, from: data) {
            konf.rozmiary = saved.mapValues(\.rawValue)
        }
        konf.ukryte = d.array(forKey: hiddenKey) as? [String] ?? []
        konf.zablokowane = d.array(forKey: lockedKey) as? [String] ?? []
        konf.odrzuconeAlerty = d.stringArray(forKey: dismissedKey) ?? []
        if let data = d.data(forKey: positionKey),
           let saved = try? JSONDecoder().decode([String: GridPos].self, from: data) {
            konf.pozycje = saved
        }
        return konf
    }

    /// Rozsuwa kafle, które w zapisie stoją na sobie.
    ///
    /// > [!danger] 🔴 To jest naprawa **danych**, nie kodu — i jest potrzebna raz
    /// > Plik [U] przyszedł z `UserDefaults`, w których zderzenie już siedziało
    /// > (`cpu` i `power` w kratce `{1, 0}`, zmierzone 2026-08-29). Sam poprawiony
    /// > `place` tego nie odkręci: on pilnuje, żeby nowych zderzeń nie tworzyć,
    /// > a stare zostałyby na dysku i dalej przestawiały siatkę przy każdym starcie.
    /// >
    /// > Pierwszy kafel w kolejności zostaje na swoim miejscu, każdy następny
    /// > kolidujący **traci przypięcie** — czyli wraca do układania automatycznego,
    /// > zamiast lądować w losowej kratce.
    static func naprawKolizje(_ wejscie: [DashTileID: GridPos],
                              rozmiar: (DashTileID) -> TileSize) -> [DashTileID: GridPos] {
        var out: [DashTileID: GridPos] = [:]
        var zajete = Set<GridCell>()
        // Stała kolejność, żeby naprawa dawała ten sam wynik przy każdym uruchomieniu.
        for id in DashTileID.allCases {
            guard let pos = wejscie[id] else { continue }
            let komorki = cells(at: pos, size: rozmiar(id))
            guard komorki.isDisjoint(with: zajete) else {
                Log.uklad.notice("Układ: \(id.rawValue, privacy: .public) stał na zajętej kratce — przypięcie zdjęte")
                continue
            }
            out[id] = pos
            zajete.formUnion(komorki)
        }
        return out
    }

    // MARK: - Rozmiar

    func size(_ id: DashTileID) -> TileSize { sizes[id] ?? Self.defaultSizes[id] ?? .medium }

    func cycleSize(_ id: DashTileID) {
        sizes[id] = size(id).next
        persist()
    }

    // MARK: - Pozycje na siatce (wolne układanie, z dziurami)

    /// Ile kolumn mieści się w oknie. Ustawia to widok, bo tylko on zna szerokość.
    ///
    /// 🔴 Wartość startowa jest **zgadywana** i wolno z niej rysować, ale nie wolno
    /// z niej zapisywać. Pilnuje tego `kolumnyZmierzone`, ustawiane w `ustawKolumny`.
    var columns: Int = 4 {
        didSet { if columns != oldValue { columns = max(1, columns) } }
    }

    /// Jedyna droga, którą widok podaje zmierzoną szerokość okna.
    ///
    /// Osobna metoda zamiast samego `layout.columns = …`, bo razem z liczbą kolumn
    /// przechodzi tu druga informacja: **że to już pomiar, a nie wartość domyślna**.
    func ustawKolumny(_ ile: Int) {
        columns = max(1, ile)
        kolumnyZmierzone = true
    }

    /// Utrwala wyliczone miejsca kafli, **którym nikt jeszcze nie nadał pozycji**.
    ///
    /// > [!danger] 🔴 To jest naprawa zgłoszenia [U] 2026-08-23: „już kolejny build i znów
    /// > pomieszane kafelki mam"
    /// > Zmierzone tego dnia w `UserDefaults`: pozycje miały **3 kafle z 18**. Pozostałe
    /// > 15 nie miało zapisanej pozycji w ogóle, więc przy każdym uruchomieniu układał je
    /// > od nowa `firstFree` — a jego wynik zależy od tego, **które kafle mają w tej chwili
    /// > dane**. Podczas łączenia z serwerem dane napływają kafel po kaflu, `visibleTiles`
    /// > rośnie, i cała siatka przestawia się na oczach [U].
    /// >
    /// > Układ nie był więc „zapominany" — nigdy nie został zapisany. Zapisywało go
    /// > wyłącznie przeciągnięcie kafla albo kłódka, i tylko dla kafli widocznych **w tej
    /// > jednej chwili**.
    /// >
    /// > Teraz każde ustalone miejsce jest zapamiętywane od razu. Kafel raz postawiony
    /// > zostaje tam, gdzie stanął — także po restarcie i po ponownym zbudowaniu programu.
    ///
    /// Kafle, które **mają** już pozycję, nie są ruszane: `merge` zostawia starą wartość.
    /// Dzięki temu zwężenie okna (i wynikające z niego przycięcie w `clamp`) zmienia sam
    /// rysunek, a nie zapis — po powrocie do szerokiego okna układ wraca nietknięty.
    @discardableResult
    func utrwalPozycje(_ tiles: [DashTileID]) -> Bool {
        // 🔴 Dopóki widok nie zmierzył okna, `columns` jest zgadywane — a `firstFree`
        // liczy z niego miejsce, które zaraz **zostanie zapisane na stałe**. Kafel
        // przypięty na podstawie zgadywanej szerokości zostaje tam na zawsze.
        guard kolumnyZmierzone else { return false }
        let ustalone = resolvedPositions(tiles)
        let brakujace = ustalone.filter { positions[$0.key] == nil }
        guard !brakujace.isEmpty else { return false }
        positions.merge(brakujace) { stara, _ in stara }
        persist()
        return true
    }

    /// Gdzie faktycznie stoi każdy kafel.
    ///
    /// Kafel **przypięty** stoi tam, gdzie go położono — nawet jeśli obok zostaje dziura.
    /// Kafel bez przypięcia (świeżo dodany albo nigdy nieruszany) spada w pierwsze wolne
    /// miejsce od góry-lewej, żeby nie wylądował na kimś.
    func resolvedPositions(_ tiles: [DashTileID]) -> [DashTileID: GridPos] {
        var out: [DashTileID: GridPos] = [:]
        var taken = Set<GridCell>()

        // 🔴 Dwa przypięte kafle potrafią po `clamp` wylądować w tej samej kratce —
        // wystarczy, że okno jest węższe niż układ. Wcześniej obie pozycje wchodziły
        // do wyniku bez sprawdzenia i kafle rysowały się jeden na drugim; dziś ten
        // drugi schodzi na pierwsze wolne pole. Zapisu to nie dotyka — patrz `place`.
        var przyciete: [DashTileID] = []
        for id in tiles {
            guard let pinned = positions[id] else { continue }
            let clamped = clamp(pinned, size: size(id))
            let komorki = cells(at: clamped, size: size(id))
            guard komorki.isDisjoint(with: taken) else { przyciete.append(id); continue }
            out[id] = clamped
            taken.formUnion(komorki)
        }
        for id in przyciete {
            let spot = firstFree(size: size(id), avoiding: taken)
            out[id] = spot
            taken.formUnion(cells(at: spot, size: size(id)))
        }
        for id in tiles where out[id] == nil {
            let spot = firstFree(size: size(id), avoiding: taken)
            out[id] = spot
            taken.formUnion(cells(at: spot, size: size(id)))
        }
        return out
    }

    /// Kładzie kafel dokładnie tam, gdzie go upuszczono.
    ///
    /// Przy pierwszym przełożeniu **przypina wszystkie** widoczne kafle w miejscach,
    /// w których właśnie stoją. Bez tego reszta natychmiast spłynęłaby w dziurę, którą
    /// user celowo zostawił — a to jest dokładnie to, czego nie chciał.
    func place(_ moved: DashTileID, at target: GridPos, among tiles: [DashTileID]) {
        // Kafel pod kłódką nie rusza się z miejsca — także wtedy, gdy ktoś go złapie.
        // Sam uchwyt jest wyłączony w widoku, ale warunek stoi też tutaj: to model
        // decyduje o układzie i to on musi być odporny, a nie tylko interfejs.
        guard !isLocked(moved) else { return }

        let wanted = clamp(target, size: size(moved))
        var resolved = resolvedPositions(tiles)
        guard resolved[moved] != wanted else { return }

        let movedCells = cells(at: wanted, size: size(moved))

        // 🔴 Zablokowany kafel **nie ustępuje**. Zamiast wypychać go na pierwsze wolne
        // pole — jak robią to kafle bez kłódki niżej — cofamy cały ruch. Upuszczenie
        // na zajęte, zablokowane pole po prostu nie dochodzi do skutku.
        //
        // To jest jedyne miejsce, w którym kłódka faktycznie działa: gdyby tego warunku
        // nie było, kafel z kłódką dalej odpływałby przy każdym upuszczeniu obok niego.
        for id in tiles where id != moved && isLocked(id) {
            guard let pos = resolved[id] else { continue }
            if !cells(at: pos, size: size(id)).isDisjoint(with: movedCells) { return }
        }

        resolved[moved] = wanted
        // Kto nachodzi na nowe miejsce, ustępuje — schodzi na pierwsze wolne pole.
        var taken = movedCells
        var displaced: [DashTileID] = []
        for id in tiles where id != moved {
            guard let pos = resolved[id] else { continue }
            if cells(at: pos, size: size(id)).isDisjoint(with: movedCells) {
                taken.formUnion(cells(at: pos, size: size(id)))
            } else {
                displaced.append(id)
            }
        }
        for id in displaced {
            let spot = firstFree(size: size(id), avoiding: taken)
            resolved[id] = spot
            taken.formUnion(cells(at: spot, size: size(id)))
        }

        // 🔴 Zapisujemy **trzy różne rzeczy trzema różnymi regułami** i to nie jest
        // przesada — poprzednia wersja miała tu jedno `merge(resolved) { _, nowa in nowa }`
        // i to ono gubiło układ [U] (zgłoszenie 2026-08-29, opis w nagłówku klasy).
        //
        // 1. Kafel bez własnej pozycji dostaje tę, w której właśnie stoi. Bez tego reszta
        //    spłynęłaby w dziurę, którą [U] celowo zostawił — zgłoszenie z 2026-08-23.
        for (id, pos) in resolved where positions[id] == nil {
            positions[id] = pos
        }
        // 2. Kafle **już przypięte** zostają nietknięte. `resolved` jest przycięty do
        //    szerokości okna, więc wpisanie go z powrotem spłaszczyłoby układ szerszy
        //    niż bieżące okno. To był ten błąd.
        // 3. Nadpisujemy wyłącznie kafel przesunięty i te, które musiały mu ustąpić.
        positions[moved] = wanted
        for id in displaced {
            positions[id] = resolved[id]
        }
        persist()
    }

    /// Zdejmuje przypięcia — kafle wracają do ciasnego układu bez dziur.
    ///
    /// 🔴 **Kafle pod kłódką zostają tam, gdzie stoją.** „Ściśnij" ma domknąć dziury,
    /// a nie obejść blokadę tylnymi drzwiami — inaczej jedno kliknięcie kasowałoby
    /// wszystko, co [U] świadomie przygwoździł.
    func repack() {
        positions = positions.filter { lockedTiles.contains($0.key) }
        persist()
    }

    /// Czy jest **co** ściskać. Same kafle pod kłódką się nie liczą: przycisk „Ściśnij"
    /// pokazany przy nich obiecywałby zmianę, która i tak nie nastąpi.
    var hasPinnedTiles: Bool { positions.contains { !lockedTiles.contains($0.key) } }

    // MARK: - Kłódka

    func isLocked(_ id: DashTileID) -> Bool { lockedTiles.contains(id) }

    var hasLockedTiles: Bool { !lockedTiles.isEmpty }

    /// Zakłada i zdejmuje kłódkę.
    ///
    /// 🔴 Zakładanie kłódki **przypina wszystkie widoczne kafle w miejscach, w których
    /// właśnie stoją**. Bez tego blokada byłaby pozorna: kafel bez własnej pozycji jest
    /// układany od nowa przy każdym przeliczeniu siatki (`resolvedPositions` spycha go
    /// w pierwsze wolne pole), więc „zablokowany" i tak by odpłynął — przy zmianie
    /// rozmiaru okna albo gdy zniknie kafel stojący wyżej.
    ///
    /// Ta sama decyzja co przy pierwszym przeciągnięciu w `place`, z tego samego powodu.
    func toggleLock(_ id: DashTileID, among tiles: [DashTileID]) {
        if lockedTiles.contains(id) {
            lockedTiles.remove(id)
        } else {
            // `merge` z tego samego powodu co w `place` — kafle chwilowo bez danych
            // nie mogą tracić zapamiętanych miejsc.
            //
            // 🔴 `{ stara, _ in stara }`, nie odwrotnie: przypięte miejsce jest zapisem
            // decyzji [U], a `resolvedPositions` zwraca je **przycięte do okna**.
            // Zakładanie kłódki nie ma prawa przestawiać kafli, których nie dotyczy.
            positions.merge(resolvedPositions(tiles)) { stara, _ in stara }
            lockedTiles.insert(id)
        }
        persist()
    }

    /// Zdejmuje wszystkie kłódki naraz — bo zdejmowanie ich pojedynczo przy kilkunastu
    /// kaflach jest karą za ostrożność.
    func unlockAll() {
        guard !lockedTiles.isEmpty else { return }
        lockedTiles.removeAll()
        persist()
    }

    // MARK: - Rachunki na kratkach

    fileprivate struct GridCell: Hashable { var col: Int; var row: Int }

    private static func cells(at pos: GridPos, size: TileSize) -> Set<GridCell> {
        var out = Set<GridCell>()
        for c in pos.col..<(pos.col + size.cols) {
            for r in pos.row..<(pos.row + size.rows) {
                out.insert(GridCell(col: c, row: r))
            }
        }
        return out
    }

    private func cells(at pos: GridPos, size: TileSize) -> Set<GridCell> {
        Self.cells(at: pos, size: size)
    }

    /// Nie pozwala wystawić kafla poza prawą krawędź ani nad górną.
    private func clamp(_ pos: GridPos, size: TileSize) -> GridPos {
        GridPos(col: min(max(0, pos.col), max(0, columns - size.cols)),
                row: max(0, pos.row))
    }

    private func firstFree(size: TileSize, avoiding taken: Set<GridCell>) -> GridPos {
        var row = 0
        while true {
            for col in 0...max(0, columns - size.cols) {
                let candidate = GridPos(col: col, row: row)
                if cells(at: candidate, size: size).isDisjoint(with: taken) {
                    return candidate
                }
            }
            row += 1
        }
    }

    // MARK: - Chowanie

    func isHidden(_ id: DashTileID) -> Bool { hiddenTiles.contains(id) }

    var hidden: [DashTileID] { order.filter { hiddenTiles.contains($0) } }

    func hide(_ id: DashTileID) {
        hiddenTiles.insert(id)
        persist()
    }

    func show(_ id: DashTileID) {
        hiddenTiles.remove(id)
        persist()
    }

    // MARK: - Alerty odrzucone przez użytkownika

    func isAlertDismissed(_ id: String) -> Bool { dismissedAlerts.contains(id) }

    func dismissAlert(_ id: String) {
        dismissedAlerts.insert(id)
        persist()
    }

    func dismissAlerts(_ ids: [String]) {
        dismissedAlerts.formUnion(ids)
        persist()
    }

    /// Przywraca wszystkie wyczyszczone alerty — bez tego wyczyszczenie byłoby
    /// nieodwracalne, a alert bywa czyszczony przez pomyłkę.
    func restoreDismissedAlerts() {
        dismissedAlerts.removeAll()
        persist()
    }

    var dismissedAlertCount: Int { dismissedAlerts.count }

    // MARK: - Reset i zapis

    func reset() {
        order = Self.defaultOrder
        sizes = [:]
        hiddenTiles = []
        positions = [:]
        // Kłódki też — „przywróć domyślny układ" ma znaczyć domyślny, a nie „domyślny
        // z wyjątkiem tych kafli, o których zapomniałeś, że je zablokowałeś".
        lockedTiles = []
        persist()
    }

    private func persist() {
        magazyn.zapisz(konfiguracja)
    }

    /// Bieżący układ w postaci, która idzie do pliku. Wydzielone, żeby dało się
    /// sprawdzić testem, co dokładnie zostanie zapisane, bez dotykania dysku.
    var konfiguracja: KonfiguracjaUkladu {
        KonfiguracjaUkladu(
            wersjaZapisu: KonfiguracjaUkladu.aktualnaWersjaZapisu,
            kolejnosc: order.map(\.rawValue),
            rozmiary: Dictionary(uniqueKeysWithValues: sizes.map { ($0.key.rawValue, $0.value.rawValue) }),
            ukryte: hiddenTiles.map(\.rawValue).sorted(),
            zablokowane: lockedTiles.map(\.rawValue).sorted(),
            pozycje: Dictionary(uniqueKeysWithValues: positions.map { ($0.key.rawValue, $0.value) }),
            odrzuconeAlerty: dismissedAlerts.sorted(),
            panelPaska: panelPaska)
    }
}
