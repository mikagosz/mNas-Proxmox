import Foundation

/// Co pokazuje panel spod ikony w pasku menu — wybór należy do [U].
///
/// > [!important] Skąd to jest
/// > Zgłoszenie [U] 2026-08-29: *„chcę dodać ustawienia do małego okienka z ikony menu
/// > bar, aby mógł dostosować co chcę, aby tam się wyświetlało — a najlepiej, jeżeli
/// > chcę mieć dwa okna, to żeby to okienko dzieliło się na pół, dwie sekcje, lub też
/// > jak chcę więcej, to do przewijania strzałkami"*.
/// >
/// > Poprawka po teście 1.0.39, tego samego dnia: *„chcę móc dodać 1:1 kafelek z pełnego
/// > ekranu i chcę mieć wybór czy daję duże na pełne okno czy na pół, bo teraz jest
/// > wymuszenie tylko na pół"*. Stąd dwie zmiany: lista obejmuje **wszystkie kafle okna
/// > głównego**, a każda pozycja niesie **własny rozmiar**.
///
/// > [!danger] 🔴 Kafel w panelu to **ten sam widok** co w oknie, nie jego kopia
/// > Rysuje go `DashboardView` w trybie `.panel` — jedno wywołanie `tileContent`.
/// > Nie pisz drugiej, „skróconej" wersji kafla na potrzeby paska: rozjedzie się
/// > z oknem przy pierwszej zmianie i [U] zobaczy dwie różne prawdy o tej samej rzeczy.
/// > Siedem skrótów niżej to co innego — one **nie mają** odpowiednika w oknie
/// > (rozbicie przebiegów na trzy stany, ostrzeżenia SMART) i dlatego zostają.

// MARK: - Pozycja panelu

/// Jedna pozycja panelu: albo skrót panelu, albo kafel z okna głównego.
///
/// Struktura z surową wartością tekstową, a nie `enum` — kafli jest osiemnaście i rosną,
/// więc lista przypadków musiałaby być przepisywana przy każdym nowym kaflu. Zapis
/// w pliku config to zwykły napis (`transfery`, `kafel.cpu`), więc stare konfiguracje
/// wczytują się bez migracji.
nonisolated struct ModulPanelu: RawRepresentable, Codable, Hashable, Sendable, Identifiable {

    var rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    var id: String { rawValue }

    // MARK: Skróty panelu — rzeczy, których w oknie nie ma

    static let wToku             = ModulPanelu(rawValue: "wToku")
    static let wymagaUwagi       = ModulPanelu(rawValue: "wymagaUwagi")
    static let ostatniePrzebiegi = ModulPanelu(rawValue: "ostatniePrzebiegi")
    static let zdarzenia         = ModulPanelu(rawValue: "zdarzenia")
    static let transfery         = ModulPanelu(rawValue: "transfery")
    static let miejsce           = ModulPanelu(rawValue: "miejsce")
    static let ostrzezeniaDyskow = ModulPanelu(rawValue: "ostrzezeniaDyskow")

    static let skroty: [ModulPanelu] = [
        .wToku, .wymagaUwagi, .ostatniePrzebiegi, .zdarzenia,
        .transfery, .miejsce, .ostrzezeniaDyskow
    ]

    // MARK: Kafle z okna głównego

    static let przedrostekKafla = "kafel."

    static func kafel(_ id: DashTileID) -> ModulPanelu {
        ModulPanelu(rawValue: przedrostekKafla + id.rawValue)
    }

    /// Kafel okna, gdy ta pozycja nim jest. `nil` dla skrótów panelu.
    var kafel: DashTileID? {
        guard rawValue.hasPrefix(Self.przedrostekKafla) else { return nil }
        return DashTileID(rawValue: String(rawValue.dropFirst(Self.przedrostekKafla.count)))
    }

    var czyKafelOkna: Bool { kafel != nil }

    static let kafleOkna: [ModulPanelu] = DashTileID.allCases.map(ModulPanelu.kafel)

    /// Skróty najpierw, kafle okna pod nimi — ta kolejność jest jednocześnie kolejnością
    /// w ekranie ustawień i porządkiem, do którego wraca włączony moduł.
    static let allCases: [ModulPanelu] = skroty + kafleOkna

    // MARK: Opis

    var tytul: String {
        if let kafel { return kafel.title }
        switch self {
        case .wToku:             return String(localized: "W toku")
        case .wymagaUwagi:       return String(localized: "Wymaga uwagi")
        case .ostatniePrzebiegi: return String(localized: "Ostatnie przebiegi")
        case .zdarzenia:         return String(localized: "Co się wydarzyło")
        case .transfery:         return String(localized: "Transfery — skrót")
        case .miejsce:           return String(localized: "Miejsce — skrót")
        case .ostrzezeniaDyskow: return String(localized: "Ostrzeżenia dysków")
        default:                 return rawValue
        }
    }

    var ikona: String {
        if let kafel { return Self.ikonaKafla(kafel) }
        switch self {
        case .wToku:             return "clock.arrow.circlepath"
        case .wymagaUwagi:       return "exclamationmark.triangle"
        case .ostatniePrzebiegi: return "checklist"
        case .zdarzenia:         return "bell.badge"
        case .transfery:         return "arrow.left.arrow.right"
        case .miejsce:           return "internaldrive"
        case .ostrzezeniaDyskow: return "externaldrive.badge.exclamationmark"
        default:                 return "square"
        }
    }

    /// Krótkie wyjaśnienie w ekranie ustawień — żeby wybór nie był zgadywanką po nazwie.
    var opis: String {
        if kafel != nil { return String(localized: "Kafel z okna głównego, jeden do jednego.") }
        switch self {
        case .wToku:             return String(localized: "Zadania, które właśnie się wykonują.")
        case .wymagaUwagi:       return String(localized: "Mechanizmy z błędem albo przeterminowane.")
        case .ostatniePrzebiegi: return String(localized: "Ostatnie domknięcia kopii i monitorów.")
        case .zdarzenia:         return String(localized: "Rejestr zmian stanu — co i kiedy się przestawiło.")
        case .transfery:         return String(localized: "Prędkość łącza, wykres godzinny i trzej najwięksi.")
        case .miejsce:           return String(localized: "Zajętość udziałów sieciowych, same paski.")
        case .ostrzezeniaDyskow: return String(localized: "Wskaźniki SMART poza progiem.")
        default:                 return ""
        }
    }

    private static func ikonaKafla(_ id: DashTileID) -> String {
        switch id {
        case .cpu:        return "cpu"
        case .ram:        return "memorychip"
        case .guests:     return "shippingbox"
        case .cpuHistory: return "chart.xyaxis.line"
        case .coreUsage:  return "square.grid.3x3"
        case .coreTemp:   return "thermometer.medium"
        case .gpu:        return "display"
        case .fans:       return "fan"
        case .storage:    return "externaldrive"
        case .disks:      return "internaldrive"
        case .services:   return "gearshape.2"
        case .alerts:     return "bell.badge"
        case .tools:      return "wrench.and.screwdriver"
        case .power:      return "bolt"
        case .przebiegi:  return "clock.arrow.circlepath"
        case .miejsce:    return "chart.pie"
        case .zdarzenia:  return "list.bullet.rectangle"
        case .transfery:  return "arrow.left.arrow.right"
        }
    }
}

// MARK: - Rozmiar pozycji

/// Ile miejsca pozycja zajmuje na stronie panelu.
///
/// 🔴 To jest **wybór [U]**, nie wynik reguły. Do 1.0.39 podział na pół był wymuszony
/// zawsze, gdy wybrano więcej niż jedną rzecz — zgłoszenie po teście:
/// *„teraz jest wymuszenie tylko na pół"*.
nonisolated enum RozmiarModulu: String, Codable, CaseIterable, Sendable {
    /// Dwie takie pozycje dzielą stronę na pół.
    case pol
    /// Zajmuje całą stronę sama.
    case cale

    var etykieta: String { self == .pol ? String(localized: "Pół") : String(localized: "Całe") }
}

/// Wybór [U] plus sposób pokazania go w panelu.
nonisolated struct UstawieniaPanelu: Codable, Equatable, Sendable {

    /// Moduły w kolejności, w jakiej mają się pokazywać. Pusta lista = układ domyślny.
    var moduly: [ModulPanelu] = Self.domyslne

    /// Czy kolejność ułożył [U] ręcznie (strzałkami w ustawieniach panelu).
    ///
    /// Dopóki `false`, `przelacz` porządkuje listę wg `ModulPanelu.allCases` — tak było
    /// od początku i tak ma zostać dla kogoś, kto strzałek nie tknął. Po pierwszym
    /// przesunięciu sortowanie znika, bo inaczej kasowałoby ustawienie przy najbliższym
    /// zaznaczeniu dowolnego modułu.
    ///
    /// `Optional` w dekodowaniu: konfiguracje zapisane przed 1.2.2 tego klucza nie mają
    /// i mają go czytać jako `false`, a nie wywracać odczyt całego pliku.
    var wlasnaKolejnosc: Bool = false

    /// Rozmiar pozycji, kluczowany jej surową nazwą. Brak wpisu = `domyslnyRozmiar`.
    var rozmiary: [String: RozmiarModulu] = [:]

    /// Domyślnie to, co panel pokazywał przed wprowadzeniem ustawień — żeby [U],
    /// który nic nie wybierze, dostał dokładnie to, co miał do tej pory.
    static let domyslne: [ModulPanelu] = [.wToku, .wymagaUwagi, .ostatniePrzebiegi, .zdarzenia]

    var wybrane: [ModulPanelu] { moduly.isEmpty ? Self.domyslne : moduly }

    // MARK: Rozmiary

    /// Skrót panelu domyślnie zajmuje pół, kafel z okna — całą stronę.
    ///
    /// Powód jest w treści: skróty to trzy–pięć wierszy tekstu i dwa takie mieszczą się
    /// obok siebie, a kafel z okna niesie wykres albo listę i w połowie panelu (200 pt)
    /// robi się nieczytelny. To **domyślna wartość, nie przymus** — [U] przestawia każdą
    /// pozycję osobno.
    static func domyslnyRozmiar(_ m: ModulPanelu) -> RozmiarModulu {
        m.czyKafelOkna ? .cale : .pol
    }

    func rozmiar(_ m: ModulPanelu) -> RozmiarModulu {
        rozmiary[m.rawValue] ?? Self.domyslnyRozmiar(m)
    }

    mutating func ustawRozmiar(_ r: RozmiarModulu, dla m: ModulPanelu) {
        rozmiary[m.rawValue] = r
    }

    // MARK: Strony

    /// Podział wybranych pozycji na strony panelu.
    ///
    /// Reguła jest prosta i wynika wprost z rozmiarów: pozycja „całe" dostaje własną
    /// stronę, dwie kolejne „pół" dzielą jedną. Ostatnia „pół" bez pary zostaje na
    /// stronie sama i zajmuje ją w całości — puste pół panelu wygląda jak brakujące dane.
    var strony: [[ModulPanelu]] {
        var out: [[ModulPanelu]] = []
        var biezaca: [ModulPanelu] = []
        for m in wybrane {
            if rozmiar(m) == .cale {
                if !biezaca.isEmpty { out.append(biezaca); biezaca = [] }
                out.append([m])
            } else {
                biezaca.append(m)
                if biezaca.count == Self.polowekNaStrone { out.append(biezaca); biezaca = [] }
            }
        }
        if !biezaca.isEmpty { out.append(biezaca) }
        return out.isEmpty ? [[]] : out
    }

    /// Ile połówek mieści strona. Dwie — bo panel ma 400 pt wysokości i trzecia sekcja
    /// zeszłaby poniżej wysokości, na której cokolwiek widać.
    static let polowekNaStrone = 2

    var liczbaStron: Int { strony.count }

    /// Strzałki pokazują się dopiero, gdy jest dokąd nimi iść.
    var maStrzalki: Bool { liczbaStron > 1 }

    /// Moduły na wskazanej stronie. Numer strony spoza zakresu jest **zawijany**,
    /// a nie ucinany — strzałki mają chodzić w kółko, bo panel bez końca listy
    /// zmuszałby do klikania w tę i z powrotem.
    func moduly(naStronie strona: Int) -> [ModulPanelu] {
        let s = strony
        guard !s.isEmpty else { return [] }
        let i = ((strona % s.count) + s.count) % s.count
        return s[i]
    }

    // MARK: Wybór

    /// Włącza i wyłącza moduł, zachowując kolejność z `ModulPanelu.allCases`.
    ///
    /// 🔴 **Ostatniego modułu nie da się wyłączyć.** Pusty panel wygląda dokładnie jak
    /// zepsuty panel, a [U] nie miałby z niego drogi powrotnej do ustawień.
    mutating func przelacz(_ modul: ModulPanelu) {
        var lista = wybrane
        if let idx = lista.firstIndex(of: modul) {
            guard lista.count > 1 else { return }
            lista.remove(at: idx)
        } else {
            lista.append(modul)
            // Po ręcznym ułożeniu nie sortujemy — nowa pozycja dokleja się na końcu,
            // zamiast wskakiwać w środek i rozbijać pary, które [U] sam poustawiał.
            if !wlasnaKolejnosc {
                let porzadek = ModulPanelu.allCases
                lista.sort { a, b in
                    (porzadek.firstIndex(of: a) ?? 0) < (porzadek.firstIndex(of: b) ?? 0)
                }
            }
        }
        moduly = lista
    }

    func zawiera(_ modul: ModulPanelu) -> Bool { wybrane.contains(modul) }

    // MARK: Kolejność

    /// Przesuwa moduł o `krok` miejsc w wybranej liście.
    ///
    /// > [!info] Po co, skoro kolejność bierze się z `ModulPanelu.allCases`
    /// > Bo ta kolejność jest **stała i nie moja**. Pozycje idą parami na strony:
    /// > pierwsza z drugą, trzecia z czwartą. Kto chce widzieć Dyski obok Miejsca,
    /// > a nie obok Temperatur, musiał do 1.2.2 odznaczać i zaznaczać moduły w takiej
    /// > kolejności, żeby przypadkiem trafiły na jedną stronę — i tracił to przy
    /// > każdej zmianie wyboru, bo `przelacz` sortował listę z powrotem.
    /// > Zgłoszenie [U] 2026-09-04: *„daj mi możliwość przesuwania w opcjach, żebym
    /// > to ja decydował jakie informacje są obok siebie"*.
    ///
    /// Poza zakres nie wychodzimy: przy pierwszym „w górę" i ostatnim „w dół" nic się
    /// nie dzieje. Zawijanie przenosiłoby pozycję przez całą listę jednym kliknięciem
    /// i wyglądało na usterkę.
    mutating func przesun(_ modul: ModulPanelu, o krok: Int) {
        var lista = wybrane
        guard let z = lista.firstIndex(of: modul) else { return }
        let doIdx = z + krok
        guard doIdx >= 0, doIdx < lista.count else { return }
        lista.swapAt(z, doIdx)
        moduly = lista
        // 🔴 Ręczna kolejność przestaje być „domyślna" — od tej chwili `przelacz`
        // nie ma prawa jej przesortować.
        wlasnaKolejnosc = true
    }

    /// Gdzie dana pozycja wyląduje: numer strony (od 1) i miejsce na niej.
    ///
    /// > [!info] Po co to istnieje
    /// > Strzałki kolejności zmieniają listę, której w ekranie ustawień nie widać —
    /// > sekcje wypisują **wszystkie dostępne** moduły w stałym porządku, a nie wybrane
    /// > w ich własnym. Zgłoszenie [U] 2026-09-04: *„klikając w strzałki ja nie widzę,
    /// > gdzie teraz będzie stało okno"*. Bez tej informacji strzałka jest ruchem
    /// > w ciemno — widać skutek dopiero po zamknięciu ustawień.
    ///
    /// Liczone z tego samego `strony`, co realny układ panelu, więc podgląd nie ma
    /// jak się rozjechać z tym, co [U] za chwilę zobaczy.
    func polozenie(_ modul: ModulPanelu) -> (strona: Int, opis: String)? {
        for (i, strona) in strony.enumerated() {
            guard let j = strona.firstIndex(of: modul) else { continue }
            let opis: String
            if strona.count == 1 {
                opis = rozmiar(modul) == .cale ? String(localized: "całe okienko") : String(localized: "sama na stronie")
            } else {
                opis = j == 0 ? String(localized: "góra") : String(localized: "dół")
            }
            return (i + 1, opis)
        }
        return nil
    }

    /// Czy [U] ustawił kolejność ręcznie.
    func czyMoznaWGore(_ m: ModulPanelu) -> Bool { (wybrane.firstIndex(of: m) ?? 0) > 0 }
    func czyMoznaWDol(_ m: ModulPanelu) -> Bool {
        guard let i = wybrane.firstIndex(of: m) else { return false }
        return i < wybrane.count - 1
    }

    // MARK: - Odczyt

    /// 🔴 Każde pole czytane przez `decodeIfPresent`, **nie** przez syntezowany dekoder.
    ///
    /// Syntezowany wymaga wszystkich kluczy, więc plik zapisany starszą wersją programu
    /// (bez `rozmiary`) wywracałby dekodowanie **całej** `KonfiguracjaUkladu` — a razem
    /// z nią przepadałby układ kafli. Dokładnie ta usterka, którą zamknęło P13, tylko
    /// wejściem od innej strony. Wyszła z testu „Stary zapis bez rozmiarów wczytuje się",
    /// zanim zdążyła trafić do [U].
    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        moduly = try k.decodeIfPresent([ModulPanelu].self, forKey: .moduly) ?? Self.domyslne
        rozmiary = try k.decodeIfPresent([String: RozmiarModulu].self, forKey: .rozmiary) ?? [:]
        // Konfiguracje sprzed 1.2.2 tego klucza nie mają — brak znaczy „kolejność
        // domyślna", nie błąd odczytu. Ta sama zasada co przy `rozmiary`.
        wlasnaKolejnosc = try k.decodeIfPresent(Bool.self, forKey: .wlasnaKolejnosc) ?? false
    }

    /// Wypisany wprost, bo własny dekoder kasuje ten z pól.
    init(moduly: [ModulPanelu] = UstawieniaPanelu.domyslne,
         rozmiary: [String: RozmiarModulu] = [:],
         wlasnaKolejnosc: Bool = false) {
        self.moduly = moduly
        self.rozmiary = rozmiary
        self.wlasnaKolejnosc = wlasnaKolejnosc
    }
}
