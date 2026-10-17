import SwiftUI
import AppKit
import Observation

/// Ikona mNas w pasku menu — `MenuBarExtra` w stylu `.window`, tak jak w TokenTime.
///
/// > [!important] Trzy własnoręczne próby na `NSStatusItem` (1.0.22, 1.0.25, 1.0.28)
/// > nie zadziałały u użytkownika mimo że każda była zmierzona i "naprawiona" po swojemu —
/// > ostatnia hipoteza (`performClose` nie gasi `isShown` od razu) została **obalona
/// > własnym testem** (`PopoverZamykanieTests`), więc błąd leżał w ścieżce zdarzeń
/// > wokół popovera, nie w nim samym. Decyzja 2026-08-23, po raz drugi: *„wchodzisz
/// > w kod tokentime i patrzysz jak tam to działa"*. `MenuBarExtra(.window)` przełącza
/// > panel natywnie — dokładnie to, co robił `TokenTime/App/ContentView.swift` bez
/// > żadnego z tych błędów.
/// >
/// > 🔴 Powód, dla którego wcześniej trzymaliśmy się `NSStatusItem` — rozróżnianie
/// > lewego i prawego kliknięcia, żeby prawy mógł otwierać okno na skróty —
/// > **zniknął razem z dwuklikiem** (decyzja 2026-08-23: *„wywal ten dwuklik,
/// > który nie działa — w okienku mam przycisk do wywołania głównego panelu"*).
/// > `MenuBarExtra` nie rozróżnia kliknięć, więc prawy klik też przepada — zastępuje
/// > go ten sam przycisk „Otwórz okno" w panelu. Decyzja 2026-08-23: zejść na samo
/// > `MenuBarExtra`, bez zamiennika za prawy klik.
///
/// > [!warning] `LSUIElement` zostaje wyłączony, ale Dock znika po zamknięciu okna
/// > mNas startuje jak zwykły program okienkowy — z Dockiem i oknem. Po zamknięciu
/// > okna **chowa się do paska menu** (decyzja 2026-08-20: *„po to jest w menu bar
/// > ikona"*), a wraca do Docka przy otwarciu okna. Robi to `NSApp.setActivationPolicy`,
/// > nie `LSUIElement` — ten drugi znaczyłby „nigdy nie ma Docka" i byłby nie do
/// > cofnięcia w trakcie działania. Cała mechanika: `Dock.swift`. `MenuBarExtra`
/// > działa niezależnie od `activationPolicy` — ikona zostaje w pasku w obu trybach.

/// Etykieta w pasku — samo rysowanie ikony, przeniesione z dawnego `aktualizujIkone()`.
/// `MenuBarExtra` sam dba o umieszczenie w pasku, o wygląd przy najechaniu i o reakcję
/// na klik; ten widok odpowiada wyłącznie za to, co się rysuje.
struct PasekMenuEtykieta: View {
    @Bindable var model: AppModel
    /// Nieczytane wprost w ciele widoku — samo czytanie każe SwiftUI przerysować
    /// etykietę przy zmianie trybu jasny/ciemny, bo `obraz(dla:)` zależy od aktualnego
    /// wyglądu. Zastępuje dawny `DistributedNotificationCenter` na
    /// `AppleInterfaceThemeChangedNotification`.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let stan = StanPaska(przebiegi: model.przebiegi,
                             polaczony: model.status.showsDashboard,
                             nieodczytane: model.nieodczytane.count,
                             odhaczone: model.potwierdzone.klucze,
                             doZainstalowania: model.aktualizacje?.doZainstalowania ?? 0)
        Image(nsImage: obraz(dla: stan))
            .help(stan.opis)
            .accessibilityLabel("mNas — \(stan.opis)")
    }

    /// 🔴 Rysujemy **w bieżącym wyglądzie systemu**, nie w domyślnym. `labelColor`
    /// i `tertiaryLabelColor` rozwiązują się dopiero przy rysowaniu — bez tego ikona
    /// wyszłaby czarna na ciemnym pasku (albo odwrotnie po zmianie motywu).
    /// `performAsCurrentDrawingAppearance` nic nie zwraca, więc obraz odbieramy zmienną.
    private func obraz(dla stan: StanPaska) -> NSImage {
        var zbudowany: NSImage?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            zbudowany = RysunekIkony.zbuduj(stan)
        }
        let obraz = zbudowany ?? NSImage()
        // Nie `isTemplate`: obraz niesie **kolory** odznaki i chmurki, a szablon
        // zamalowałby je jednolitą czernią i cały podział na zielone/czerwone/niebieskie
        // przestałby istnieć.
        obraz.isTemplate = false
        return obraz
    }
}

/// Łapie referencję do własnego okna raz, żeby dało się nasłuchiwać `didBecomeKey`
/// niezależnie od tego, czy `.window` `MenuBarExtra` woła `onAppear` przy **każdym**
/// pokazaniu, czy tylko przy pierwszym — SDK tego nie gwarantuje, a to jest jedyny
/// moment, w którym trzeba oznaczyć przebiegi jako przeczytane. `NSWindow` pod spodem
/// jest tym samym obiektem przy każdym otwarciu, więc subskrypcja założona raz starcza
/// na cały cykl życia panelu.
private struct OknoPanelu: NSViewRepresentable {
    /// `@MainActor @Sendable`, nie zwykłe `() -> Void`: `NotificationCenter` wymaga
    /// `@Sendable` domknięcia dla `using:`, a domyślna izolacja projektu na `MainActor`
    /// oznacza, że zwykłe domknięcie łapiące `model` nie przejdzie tej granicy. Para
    /// obu adnotacji naraz jest bezpieczna — domknięcie i tak wykona się wyłącznie
    /// na głównym aktorze, `@Sendable` mówi tylko, że samą wartość wolno tam przekazać.
    let staloSieAktywne: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let widok = NSView(frame: .zero)
        DispatchQueue.main.async { [weak widok] in
            guard let okno = widok?.window, context.coordinator.token == nil else { return }
            context.coordinator.token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: okno, queue: .main
            ) { _ in Task { @MainActor in staloSieAktywne() } }
        }
        return widok
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Zdjęcie obserwatora, gdy SwiftUI rozbiera ten widok. Okno żyje przez cały czas
    /// działania programu, ale **ten widok** nie musi — jeśli `MenuBarExtra` odbudowuje
    /// zawartość panelu, każdy nowy koordynator zakładał własny obserwator, a stare
    /// zostawały i „przeczytane” wołało się wielokrotnie. Audyt SBW 2026-09-24, E2-S-P3-02.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let token = coordinator.token {
            NotificationCenter.default.removeObserver(token)
            coordinator.token = nil
        }
    }

    @MainActor
    final class Coordinator {
        var token: Any?
    }
}

// MARK: - Rysowanie ikony

/// Składa ikonę paska z trzech kawałków: **odznaki po lewej**, dysku i chmurki po prawej.
///
/// Układ ustalony przez użytkownika 2026-08-20: `(●) 💾 💬3`
///
/// Dlaczego rysowane ręcznie, a nie gotowym symbolem SF w rodzaju
/// `externaldrive.fill.badge.checkmark`: te symbole mają **jedną** odznakę wbudowaną
/// w kształt, po prawej stronie i w kolorze całego symbolu. Tutaj odznaka ma stać
/// po lewej, zmieniać kolor niezależnie od podstawy i sąsiadować z chmurką. Jeden
/// własny rysunek to jedyny sposób, żeby te trzy elementy dało się ustawiać osobno.
///
/// > [!danger] 🔴 Symbole koloruj `paletteColors`, NIGDY przez `fill(using: .sourceAtop)`
/// > Pierwsza wersja (2026-08-20) rysowała symbol, a potem zamalowywała jego prostokąt
/// > bielą w trybie `.sourceAtop`. Na przezroczystym tle to działa — biel trafia tylko
/// > tam, gdzie symbol ma alfę. **Ale odznaka ma pod spodem nieprzezroczyste kółko**,
/// > więc `.sourceAtop` zamalowało cały prostokąt i zamiast ptaszka wychodził
/// > **biały kwadrat**. Zgłoszenie: „to kółko … słabo zielone z ptaszkiem".
/// > `SymbolConfiguration(paletteColors:)` koloruje sam kształt i nie ma tej pułapki.
@MainActor
enum RysunekIkony {

    private static let wysokosc: CGFloat = 18
    private static let srednicaOdznaki: CGFloat = 11
    /// O ile dysk wchodzi na odznakę. Stykają się rogami, nie stoją obok siebie —
    /// dzięki temu całość mieści się w pasku i czyta jako jedna ikona, nie dwie.
    private static let zachodzenie: CGFloat = 3
    private static let srednicaLicznika: CGFloat = 12
    /// Licznik jest **osobnym** znacznikiem, nie odznaką dysku — musi mieć wokół siebie
    /// powietrze, inaczej czyta się jak doklejony do obudowy.
    private static let odstepLicznika: CGFloat = 2
    /// Znak aktualizacji — to samo kółko co odznaka stanu, z odstępem od dysku (1.2.39).
    private static let odstepAktualizacji: CGFloat = 2

    static func zbuduj(_ stan: StanPaska) -> NSImage {
        let maOdznake = stan.odznaka.symbol != nil
        let przesuniecieDysku = maOdznake ? srednicaOdznaki - zachodzenie : 0

        let konfiguracjaDysku = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [stan.kolorPodstawy]))
        let dysk = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(konfiguracjaDysku)
        let szerokoscDysku = dysk?.size.width ?? 16

        let etykieta = etykietaChmurki(stan.nieodczytane)
        let szerokoscChmurki = etykieta.map { szerokoscChmurki($0) } ?? 0
        let szerokoscAktualizacji = stan.doZainstalowania > 0 ? odstepAktualizacji + srednicaOdznaki : 0
        let szerokosc = przesuniecieDysku + szerokoscDysku + szerokoscAktualizacji + szerokoscChmurki

        let obraz = NSImage(size: NSSize(width: szerokosc, height: wysokosc))
        obraz.lockFocus()
        defer { obraz.unlockFocus() }

        if let symbol = stan.odznaka.symbol {
            rysujOdznake(symbol: symbol, kolor: stan.kolorOdznaki)
        }
        if let dysk {
            dysk.draw(in: NSRect(x: przesuniecieDysku,
                                 y: (wysokosc - dysk.size.height) / 2,
                                 width: dysk.size.width, height: dysk.size.height))
        }
        if stan.doZainstalowania > 0 {
            rysujAktualizacje(x: przesuniecieDysku + szerokoscDysku + odstepAktualizacji)
        }
        if let etykieta {
            rysujLicznik(etykieta, x: przesuniecieDysku + szerokoscDysku + szerokoscAktualizacji, szerokosc: szerokoscChmurki)
        }
        return obraz
    }

    /// Powyżej dziewięciu liczba przestaje się mieścić — i przestaje mieć znaczenie.
    /// „9+" mówi dokładnie tyle, ile trzeba: jest tego więcej, niż warto liczyć.
    private static func etykietaChmurki(_ ile: Int) -> String? {
        switch ile {
        case ..<1:  return nil
        case 1...9: return "\(ile)"
        default:    return "9+"
        }
    }

    /// Szerokość zajmowana przez licznik razem z odstępem od dysku.
    private static func szerokoscChmurki(_ etykieta: String) -> CGFloat {
        odstepLicznika + (etykieta.count > 1 ? srednicaLicznika + 5 : srednicaLicznika)
    }

    /// Odznaka: pełne kółko w kolorze stanu, w środku biały znak.
    /// Stoi po **lewej**, przy dolnej krawędzi — decyzja 2026-08-20.
    private static func rysujOdznake(symbol: String, kolor: NSColor) {
        let kolo = NSRect(x: 0, y: 0, width: srednicaOdznaki, height: srednicaOdznaki)
        kolor.setFill()
        NSBezierPath(ovalIn: kolo).fill()

        // Znak w środku: **6,5 pt, waga `heavy`**. Przy cieńszej kresce ptaszek na kółku
        // tej wielkości zlewa się w plamkę i użytkownik widzi „słabo zielone kółko" zamiast
        // informacji, że wszystko działa.
        let konfiguracja = NSImage.SymbolConfiguration(pointSize: 6.5, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let znak = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(konfiguracja) else { return }
        znak.draw(in: NSRect(x: kolo.midX - znak.size.width / 2,
                             y: kolo.midY - znak.size.height / 2,
                             width: znak.size.width, height: znak.size.height))
    }

    /// Znak aktualizacji: pomarańczowe kółko z białą strzałką w dół, zaraz za dyskiem.
    /// Zamiast powiadomienia macOS (2026-10-17). Ten sam kształt i znak co odznaka stanu.
    private static func rysujAktualizacje(x: CGFloat) {
        let kolo = NSRect(x: x, y: (wysokosc - srednicaOdznaki) / 2, width: srednicaOdznaki, height: srednicaOdznaki)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: kolo).fill()
        let konfiguracja = NSImage.SymbolConfiguration(pointSize: 6.5, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let znak = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(konfiguracja) else { return }
        znak.draw(in: NSRect(x: kolo.midX - znak.size.width / 2, y: kolo.midY - znak.size.height / 2,
                             width: znak.size.width, height: znak.size.height))
    }

    /// Licznik nieodczytanych — **osobne kółko po prawej stronie dysku**.
    /// Decyzja 2026-08-20: *„z prawej ma się pojawić osobne kółko z ilością
    /// informacji nieodczytanych, jak nic nie ma to się ma nie pojawiać"*.
    ///
    /// Kółka **nie ma wcale** przy zerze — nie jest wygaszone ani puste. Widoczne zero
    /// to informacja, że nic się nie dzieje; brak kółka to brak informacji i tak ma być.
    /// Odpowiada za to `etykietaChmurki`, które przy zerze zwraca `nil`.
    ///
    /// Przy „9+" kółko rozciąga się w pigułkę, bo dwa znaki nie mieszczą się w kole
    /// o tej średnicy. Kształt rysuje `NSBezierPath(roundedRect:)` o promieniu równym
    /// połowie wysokości — przy jednym znaku wychodzi z tego dokładnie koło.
    private static func rysujLicznik(_ etykieta: String, x: CGFloat, szerokosc: CGFloat) {
        let srednica = srednicaLicznika
        let ramka = NSRect(x: x + odstepLicznika, y: (wysokosc - srednica) / 2,
                           width: szerokosc - odstepLicznika, height: srednica)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: ramka, xRadius: srednica / 2, yRadius: srednica / 2).fill()

        let atrybuty: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let napis = NSAttributedString(string: etykieta, attributes: atrybuty)
        let rozmiar = napis.size()
        napis.draw(at: NSPoint(x: ramka.midX - rozmiar.width / 2,
                               y: ramka.midY - rozmiar.height / 2))
    }
}

/// Jak ma wyglądać ikona przy danym zestawie przebiegów.
///
/// Wyliczane osobno od widoku, żeby dało się to sprawdzić testem bez paska menu —
/// i faktycznie jest sprawdzane w `PrzebiegiTests`.
///
/// Cztery odznaki, kolejność ustalona przez użytkownika 2026-08-20:
///
/// | Odznaka | Kiedy | Znaczenie |
/// |---|---|---|
/// | 🔴 `xmark` | mechanizm padł, zamilkł albo chodzi za długo | „coś nie działa" |
/// | 🔵 `play` | jakikolwiek przebieg trwa | „mechanizm pracuje" |
/// | 🟢 `checkmark` | połączony, nic nie chodzi, nic nie boli | „wszystko w porządku" |
/// | brak | brak połączenia z serwerem | „niepołączony" |
///
/// 🔴 **Czerwony wygrywa z niebieskim.** Gdy w tym samym momencie coś trwa i coś innego
/// padło, na ikonie ma być błąd — inaczej awaria chowałaby się za normalną pracą.
/// Sam fakt, że coś jeszcze chodzi, jest wtedy mniej ważny niż to, że coś nie wyszło.
nonisolated struct StanPaska: Sendable, Equatable {

    /// Odznaka doklejana do symbolu dysku.
    nonisolated enum Odznaka: String, Sendable {
        case blad, praca, wporzadku, brak

        /// Symbol SF rysowany w kółku odznaki. `nil` = odznaki nie ma.
        var symbol: String? {
            switch self {
            case .blad:      return "xmark"
            case .praca:     return "play.fill"
            case .wporzadku: return "checkmark"
            case .brak:      return nil
            }
        }
    }

    var odznaka: Odznaka
    var opis: String
    var trwajacych: Int
    var alarmow: Int
    /// Liczba w chmurce po prawej. `0` = chmurki nie ma.
    var nieodczytane: Int
    /// Maszyny z aktualizacjami do zainstalowania (kropka pomarańczowa albo żółta). `0` = bez znaku.
    var doZainstalowania: Int

    /// - Parameter odhaczone: klucze alarmów, które użytkownik zakwitował przyciskiem
    ///   „Przyjęte". Puste = zachowanie sprzed 2026-08-23, czyli każdy alarm liczy się
    ///   do czerwieni. Patrz `PotwierdzoneAlerty.swift`.
    init(przebiegi: [Przebieg], polaczony: Bool, nieodczytane: Int = 0,
         odhaczone: Set<String> = [], doZainstalowania: Int = 0) {
        let trwajace = przebiegi.filter { $0.stan == .trwa }
        // 🔴 Warunek alarmu siedzi w `KluczAlertu.dla` i **tylko tam** — inaczej lista,
        // którą gasi przycisk, i lista, która zapala ikonę, rozjechałyby się przy
        // pierwszej zmianie w jednej z nich.
        let alarmy = przebiegi.filter { przebieg in
            guard let klucz = KluczAlertu.dla(przebieg) else { return false }
            return !odhaczone.contains(klucz)
        }
        trwajacych = trwajace.count
        alarmow = alarmy.count
        self.nieodczytane = nieodczytane
        self.doZainstalowania = doZainstalowania

        if !alarmy.isEmpty {
            odznaka = .blad
            opis = alarmy.count == 1
                ? "\(alarmy[0].nazwa) — \(alarmy[0].przekroczylCzas ? String(localized: "trwa nietypowo długo") : alarmy[0].stan.opis)"
                : String(localized: "\(alarmy.count) mechanizmów wymaga uwagi")
        } else if !trwajace.isEmpty {
            odznaka = .praca
            let pierwszy = trwajace[0]
            let postep = pierwszy.postepOpis.map { " (\($0))" } ?? ""
            opis = trwajace.count == 1
                ? String(localized: "\(pierwszy.nazwa)\(postep) — trwa")
                : String(localized: "\(trwajace.count) przebiegi w toku")
        } else if !polaczony {
            odznaka = .brak
            opis = String(localized: "brak połączenia z serwerem")
        } else {
            odznaka = .wporzadku
            opis = String(localized: "połączony, nic się nie kopiuje")
        }

        if doZainstalowania > 0 {
            opis += String(localized: ", aktualizacje na serwerze: \(doZainstalowania)")
        }
        if nieodczytane > 0 {
            // Odmiana po liczbie w katalogu tekstów (warianty liczby mnogiej).
            opis += String(localized: ", \(nieodczytane) nowych wiadomości")
        }
    }
}

extension StanPaska {
    /// Kolor odznaki. Wszystkie trzy czytają się i na jasnym, i na ciemnym pasku —
    /// dlatego są to kolory systemowe, a nie własne wartości RGB.
    var kolorOdznaki: NSColor {
        switch odznaka {
        case .blad:      return .systemRed
        case .praca:     return .systemBlue
        case .wporzadku: return .systemGreen
        case .brak:      return .clear
        }
    }

    /// Kolor samego dysku. Bez połączenia przygaszony — ikona ma na pierwszy rzut oka
    /// mówić „program nic teraz nie wie", zanim ktokolwiek doczyta odznakę.
    var kolorPodstawy: NSColor {
        odznaka == .brak ? .tertiaryLabelColor : .labelColor
    }
}

// MARK: - Zawartość panelu

/// Panel spod jednego kliknięcia: co teraz chodzi, co poszło źle, co robić dalej.
struct PanelPaskaMenu: View {
    @Bindable var model: AppModel
    var zamknij: () -> Void
    var pokazOkno: () -> Void

    private var trwajace: [Przebieg] { model.przebiegi.filter { $0.stan == .trwa } }
    private var alarmy: [Przebieg] {
        model.przebiegi.filter { ($0.stan.alarmujacy || $0.przekroczylCzas) && $0.stan != .trwa }
    }
    private var reszta: [Przebieg] {
        model.przebiegi.filter { $0.stan != .trwa && !$0.stan.alarmujacy && !$0.przekroczylCzas }
    }

    /// Numer strony panelu. Może wyjść poza zakres — `UstawieniaPanelu.moduly(naStronie:)`
    /// **zawija** go, bo strzałki mają chodzić w kółko.
    @State private var strona = 0
    @State private var pokazUstawienia = false
    /// Czy sterowanie stronami jest w tej chwili widoczne.
    ///
    /// Zgłoszenie po teście 1.1.1: strzałki i kropki leżą **na** treści, więc przy
    /// kaflu wypełniającym stronę przykrywały ostatni wiersz. Decyzja: *„chowane
    /// dopóki nie rusza"* — sterowanie pojawia się na ruch myszy nad panelem i gaśnie
    /// samo, gdy ruch ustanie.
    @State private var sterowanieWidoczne = false
    /// Odliczanie do zgaszenia sterowania. Trzymane, żeby każdy ruch myszy je **odnawiał**
    /// zamiast dokładać kolejne — bez tego dziesięć drgnięć gasiłoby panel dziesięć razy.
    @State private var zegarSterowania: Task<Void, Never>?

    /// Wybór: co panel pokazuje. Leży w tym samym pliku config co układ kafli.
    private var ustawienia: UstawieniaPanelu { model.layout.panelPaska }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            naglowek
            pasekOdhaczenia
            Divider()
            if pokazUstawienia {
                EkranUstawienPanelu(layout: model.layout) { pokazUstawienia = false }
            } else {
                stronaZeSterowaniem
            }
            Divider()
            stopka
        }
        .frame(width: 340, height: 400)
        // Zmiana wyboru potrafi skrócić listę stron pod palcem — wracamy na pierwszą,
        // zamiast zostawiać użytkownika na stronie, której już nie ma.
        .onChange(of: ustawienia.liczbaStron) { strona = 0 }
        // Otwarcie panelu **jest** przeczytaniem: użytkownik właśnie patrzy na tę listę.
        // Chmurka gaśnie tutaj, a nie po upływie czasu — licznik ma mówić
        // „nie widziałeś tego", a nie „to się stało niedawno". Patrz `OknoPanelu`.
        .background(OknoPanelu { model.oznaczPrzebiegiJakoPrzeczytane() })
    }

    private var naglowek: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("mNas").font(.headline)
                Text(podpisStanu).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                pokazUstawienia.toggle()
            } label: {
                Image(systemName: pokazUstawienia ? "xmark" : "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help(pokazUstawienia ? "Wróć do panelu" : "Wybierz, co ma być w tym okienku")
            Button {
                Task { await model.odswiezPrzebiegi() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Sprawdź przebiegi teraz")
        }
        // Pod adresem mniej miejsca niż nad nazwą — zgłoszenie po teście 1.1.0:
        // pusty pas między adresem a belką odsuwał treść od nagłówka bez powodu.
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// Pasek „Przyjęte" — stoi **pod nagłówkiem, nad listą**, bo odpowiada na
    /// pierwsze pytanie, jakie użytkownik zadaje po zobaczeniu czerwonej ikony: co się pali
    /// i jak to zgasić. Schowany w stopce byłby odpowiedzią na końcu zdania.
    ///
    /// Znika sam, gdy nie ma czego odhaczać — pusty przycisk „potwierdź" przy zdrowym
    /// serwerze uczyłby, że się go klika bez czytania.
    @ViewBuilder private var pasekOdhaczenia: some View {
        let doOdhaczenia = model.alarmyDoOdhaczenia
        if !doOdhaczenia.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(doOdhaczenia.count == 1
                         ? doOdhaczenia[0].nazwa
                         : String(localized: "\(doOdhaczenia.count) mechanizmów wymaga uwagi"))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(doOdhaczenia.count == 1
                         ? (doOdhaczenia[0].opis ?? doOdhaczenia[0].stan.opis)
                         : String(localized: "Ikona świeci na czerwono, dopóki tego nie zakwitujesz."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                // Wpis w rejestrze zdarzeń **zostaje** — gaśnie sam kolor alarmu.
                Button("Przyjęte") { model.potwierdzAlerty() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Gasi czerwoną ikonę i liczbę obok niej. Wpis w „Zdarzeniach” zostaje, a kolejna awaria zapali je od nowa.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.red.opacity(0.10))
        }
    }

    private var podpisStanu: String {
        switch model.status {
        case .connected:    return model.host.isEmpty ? String(localized: "Połączony") : String(localized: "Połączony · \(model.host)")
        case .reconnecting: return String(localized: "Wracam po zerwaniu połączenia…")
        case .connecting:   return String(localized: "Łączę…")
        case .failed:       return String(localized: "Połączenie nieudane")
        case .disconnected: return String(localized: "Rozłączony")
        }
    }

    // MARK: - Strony panelu (P14)
    //
    // Zgłoszenie 2026-08-29: *„chcę dodać ustawienia do małego okienka z ikony menu
    // bar, aby mógł dostosować co chcę, aby tam się wyświetlało — a najlepiej, jeżeli
    // chcę mieć dwa okna, to żeby to okienko dzieliło się na pół, dwie sekcje, lub też
    // jak chcę więcej, to do przewijania strzałkami"*.
    //
    // Reguła podziału siedzi w `UstawieniaPanelu`, nie tutaj — widok tylko rysuje to,
    // co model zwrócił dla danej strony. Dzięki temu „jeden = całość, dwa = pół, więcej
    // = strzałki" da się sprawdzić testem, bez uruchamiania interfejsu.

    /// Zawartość jednej strony: pozycja „całe" sama, dwie „pół" jedna nad drugą.
    /// Podziałem rządzi rozmiar wybrany przez użytkownika, nie liczba pozycji.
    @ViewBuilder private var zawartoscStrony: some View {
        let naStronie = ustawienia.moduly(naStronie: strona)
        VStack(spacing: 0) {
            ForEach(Array(naStronie.enumerated()), id: \.element) { i, m in
                if i > 0 { Divider() }
                pozycja(m, rozmiar: ustawienia.rozmiar(m))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Kafel z okna rysuje `DashboardView` w trybie `.panel` — **ten sam widok co w oknie**,
    /// nie jego skrócona kopia. Skróty panelu (przebiegi rozbite na trzy stany, ostrzeżenia
    /// SMART) odpowiednika w oknie nie mają i rysują się tutaj.
    @ViewBuilder private func pozycja(_ m: ModulPanelu, rozmiar: RozmiarModulu) -> some View {
        if let kafel = m.kafel {
            // 🔴 „Pół" MUSI dostać wariant `.medium`, nie `.large`.
            //
            // Próba z 1.2.1 dawała `.large` obu pozycjom, żeby odblokować pełne listy —
            // i zepsuła podział strony. Kafle z wykresami (Temp. rdzeni, Historia CPU)
            // mają w `.large` słupki i przebiegi o **stałej, dużej wysokości**, które nie
            // ustępują: pierwszy kafel rozpychał stronę, a drugi nie miał się gdzie zmieścić.
            // Zgłoszenie 2026-09-04: *„ustawiam dyski pół i mam cały kafelek"*.
            //
            // Listy odblokowane są teraz w samych kaflach (`ilePokazac`/`listaKafla`),
            // czyli tam, gdzie leżał prawdziwy problem — a nie przez podmianę wariantu.
            DashboardView(tryb: .panel,
                          kafelPanelu: kafel,
                          rozmiarPanelu: rozmiar == .cale ? .large : .medium)
                .environment(model)
        } else {
            modul(m)
        }
    }

    /// Strona z nałożonym sterowaniem: strzałki po bokach, kropki u dołu.
    ///
    /// Zgłoszenie po teście 1.1.0: *„na dole pasek 1 z 2 usuwamy i aktywne strzałki
    /// mają być na oknie, a zamiast 1 z 2 mają być kropki na dole"*. Sterowanie leży
    /// **na** treści, a nie pod nią, więc nie zabiera wysokości — panel ma 400 pt
    /// i osobny pasek zjadał z tego kilkanaście punktów na każdej stronie.
    @ViewBuilder private var stronaZeSterowaniem: some View {
        ZStack(alignment: .bottom) {
            zawartoscStrony
            if ustawienia.maStrzalki {
                Group {
                    strzalka(.wstecz)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    strzalka(.dalej)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    kropki
                }
                .opacity(sterowanieWidoczne ? 1 : 0)
                // Niewidoczne sterowanie nie łapie kliknięć — inaczej dałoby się trafić
                // w strzałkę, której nie widać, i strona zmieniałaby się „sama".
                .allowsHitTesting(sterowanieWidoczne)
                .animation(.easeOut(duration: 0.15), value: sterowanieWidoczne)
            }
        }
        .frame(maxHeight: .infinity)
        .onContinuousHover { faza in
            switch faza {
            case .active: pokazSterowanie()
            case .ended:  ukryjSterowanie()
            }
        }
        .onDisappear { zegarSterowania?.cancel() }
    }

    /// Ile sterowanie zostaje na ekranie po ostatnim drgnięciu myszy.
    private static let czasSterowania: Duration = .seconds(2)

    private func pokazSterowanie() {
        sterowanieWidoczne = true
        zegarSterowania?.cancel()
        zegarSterowania = Task {
            try? await Task.sleep(for: Self.czasSterowania)
            guard !Task.isCancelled else { return }
            sterowanieWidoczne = false
        }
    }

    private func ukryjSterowanie() {
        zegarSterowania?.cancel()
        zegarSterowania = nil
        sterowanieWidoczne = false
    }

    private enum Kierunek { case wstecz, dalej }

    /// Strzałka nałożona na treść. Kółko z podkładką, bo pod spodem bywa wykres —
    /// sam znak ginąłby na jasnych miejscach kafla.
    private func strzalka(_ kierunek: Kierunek) -> some View {
        Button {
            przewin(kierunek == .wstecz ? -1 : 1)
            // Klik odnawia odliczanie: przewijanie trzema kliknięciami nie ma prawa
            // zgasić sterowania w połowie.
            pokazSterowanie()
        } label: {
            Image(systemName: kierunek == .wstecz ? "chevron.left" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(kierunek == .wstecz ? "Poprzednia strona" : "Następna strona")
    }

    /// Kropki zamiast podpisu „2 z 4". Klikalne — przy czterech stronach szybciej trafić
    /// w kropkę niż trzy razy w strzałkę.
    private var kropki: some View {
        HStack(spacing: 5) {
            ForEach(0..<ustawienia.liczbaStron, id: \.self) { i in
                Button {
                    strona = i
                    pokazSterowanie()
                } label: {
                    Circle()
                        .fill(i == numerStrony ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.30))
                        .frame(width: 5, height: 5)
                }
                .buttonStyle(.plain)
                .help("Strona \(i + 1) z \(ustawienia.liczbaStron)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 6)
    }

    /// Numer strony sprowadzony do zakresu — do podpisu „2 z 4". Sam ruch zostawia
    /// `strona` poza zakresem i to jest w porządku: model zawija przy odczycie.
    private var numerStrony: Int {
        let stron = ustawienia.liczbaStron
        return ((strona % stron) + stron) % stron
    }

    private func przewin(_ o: Int) { strona = numerStrony + o }

    @ViewBuilder private func modul(_ m: ModulPanelu) -> some View {
        ThinScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: m.ikona).font(.caption2).foregroundStyle(.tertiary)
                    Text(m.tytul.uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                switch m {
                case .wToku:
                    zawartoscPrzebiegow(trwajace, pusto: "Nic się teraz nie wykonuje.")
                case .wymagaUwagi:
                    zawartoscPrzebiegow(alarmy, pusto: "Żaden mechanizm nie zgłasza problemu.")
                case .ostatniePrzebiegi:
                    zawartoscPrzebiegow(reszta, pusto: "Jeszcze nic się nie domknęło.")
                case .zdarzenia:         zawartoscZdarzen
                case .transfery:         zawartoscTransferow
                case .miejsce:           zawartoscMiejsca
                case .ostrzezeniaDyskow: zawartoscOstrzezen
                default:                 EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    /// Pusto **nie znaczy** to samo przy rozłączonym serwerze co przy zdrowym — bez tego
    /// rozróżnienia brak połączenia wyglądałby jak spokój.
    @ViewBuilder private func zawartoscPrzebiegow(_ lista: [Przebieg], pusto: LocalizedStringKey) -> some View {
        if lista.isEmpty {
            Text(model.status.showsDashboard
                 ? pusto
                 : "Połącz się z serwerem, żeby zobaczyć zadania i monitory.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(lista) { p in WierszPrzebiegu(przebieg: p) }
        }
    }

    /// Historia zdarzeń.
    ///
    /// 🔴 Ma prawo stać w panelu **dlatego, że to tutaj gaśnie chmurka**. Otwarcie panelu
    /// kasuje licznik nieodczytanych, a przed 2026-08-23 razem z nim znikała jedyna
    /// informacja, że cokolwiek się wydarzyło — zgłoszenie: *„jak otworzę okno to
    /// powiadomienie znika i generalnie nie wiem co się dzieje"*. Gdyby użytkownik wyłączył ten
    /// moduł, chmurka dalej gaśnie — dlatego pełna historia jest też w oknie głównym.
    @ViewBuilder private var zawartoscZdarzen: some View {
        let lista = Array(model.rejestr.zdarzenia.prefix(5))
        if lista.isEmpty {
            Text("Rejestr jest pusty — nic jeszcze nie zmieniło stanu.")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            ForEach(lista) { z in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Self.kolorStanu(z.stan))
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(z.nazwa).font(.caption).lineLimit(1)
                        Text(z.opis.map { "\(z.jednymZdaniem) · \($0)" } ?? z.jednymZdaniem)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(Self.godzina.string(from: z.czas))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            if model.rejestr.zdarzenia.count > lista.count {
                Text("Pełna historia w oknie programu, kafel „Zdarzenia”.")
                    .font(.caption2).foregroundStyle(.quaternary)
            }
        }
    }

    /// Transfery w skrócie: prędkość łącza, godzinny przebieg i trzech największych.
    /// Źródło to RRD Proxmoksa — patrz `Transfery.swift`.
    @ViewBuilder private var zawartoscTransferow: some View {
        let lacze = model.strumienie.first { if case .lacze = $0.rodzaj { return true }; return false }
        let aktywne = TransferyParsers.aktywne(model.strumienie)
        if !model.transferyZywe {
            // 🔴 „Nie ma odczytu" ≠ „w sieci cisza".
            Text("Proxmox nie oddał historii RRD. To brak odczytu, nie cisza w sieci.")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.predkosc(lacze?.bajtyNaSekunde ?? 0))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.mint)
                Text("przez łącze").font(.caption2).foregroundStyle(.secondary)
            }
            if let punkty = lacze?.punkty.map(\.razemNaSekunde), punkty.count > 1 {
                Sparkline(points: punkty, tint: .mint)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.3)))
            }
            if aktywne.isEmpty {
                Text("Cisza — nic powyżej \(Format.predkosc(TransferyParsers.progCiszyBajtowNaSekunde)).")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(aktywne.prefix(3)) { s in
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox").font(.caption2).foregroundStyle(.mint)
                    Text(s.kto).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.predkosc(s.bajtyNaSekunde))
                        .font(.caption2.monospacedDigit())
                }
            }
        }
    }

    /// Zajętość udziałów — ten sam próg co czujka na serwerze (`Miejsce.progZajetosci`).
    @ViewBuilder private var zawartoscMiejsca: some View {
        if model.udzialy.isEmpty {
            Text("Brak odczytu udziałów. Miejsce czyta `df` po SSH, więc wymaga tego kanału.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(model.udzialy) { u in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(u.nazwa).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(u.procent)%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(u.przekroczylProg ? Color.red : Color.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(u.przekroczylProg ? Color.red : Color.accentColor)
                                .frame(width: max(2, geo.size.width * Double(u.procent) / 100))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }

    /// Ostrzeżenia SMART. Liczone tak samo jak w oknie głównym — jedna funkcja
    /// `OstrzezeniaDyskow.zbierz`, żeby panel i kafel nie mogły powiedzieć czego innego.
    @ViewBuilder private var zawartoscOstrzezen: some View {
        let lista = OstrzezeniaDyskow.zbierz(disks: model.disks,
                                             temperatures: model.temperatures,
                                             czas: model.lastSuccessfulRefresh ?? Date())
        if lista.isEmpty {
            Label("Żaden dysk nie przekracza teraz progu.", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        } else {
            ForEach(lista) { o in
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.opisNosnika).font(.caption.weight(.medium)).lineLimit(1)
                    Text(o.jednymZdaniem)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func kolorStanu(_ stan: Przebieg.Stan) -> Color {
        switch stan {
        case .trwa:     return .teal
        case .udany:    return .green
        case .bledny:   return .red
        case .cisza:    return .orange
        case .nieznany: return .secondary
        }
    }

    private static let godzina: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var stopka: some View {
        HStack(spacing: 10) {
            Button {
                zamknij()
                pokazOkno()
            } label: {
                Label("Otwórz okno", systemImage: "macwindow")
            }
            .help("Otwiera główne okno programu")
            Spacer()
            // Wersja stoi tam, gdzie użytkownik i tak patrzy zamykając panel. Czytana z pakietu,
            // nie wpisana — patrz `Wersja`.
            if let v = Wersja.krotka {
                Text(v)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.quaternary)
                    .help(Wersja.pelna ?? v)
                Spacer()
            }
            Button("Zakończ mNas") { NSApp.terminate(nil) }
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(10)
    }
}

/// Jeden wiersz listy — ten sam układ w panelu paska i (w skrócie) na kaflu.
private struct WierszPrzebiegu: View {
    let przebieg: Przebieg

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(kolor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(przebieg.nazwa)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let ulamek = przebieg.postepUlamek, przebieg.stan == .trwa {
                    PasekPostepu(ulamek: ulamek, kolor: kolor)
                }
                if let dopisek {
                    Text(dopisek)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text(PrzebiegFormat.czas(przebieg))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var kolor: Color {
        if przebieg.przekroczylCzas { return .orange }
        switch przebieg.stan {
        case .trwa:     return .accentColor
        case .udany:    return .green
        case .bledny:   return .red
        case .cisza:    return .orange
        case .nieznany: return .secondary
        }
    }

    private var dopisek: String? {
        var czesci: [String] = []
        if przebieg.przekroczylCzas { czesci.append(String(localized: "trwa nietypowo długo")) }
        if let postep = przebieg.postepOpis { czesci.append(postep) }
        if let faza = przebieg.faza { czesci.append(faza) }
        if let opis = przebieg.opis { czesci.append(opis) }
        if let tempo = PrzebiegFormat.tempo(przebieg) { czesci.append(tempo) }
        return czesci.isEmpty ? nil : czesci.joined(separator: " · ")
    }
}

/// Pasek postępu przebiegu.
///
/// 🔴 Mierzy **pozycje, nie bajty** — bo tylko to serwer podaje uczciwie
/// (`PrzebiegiParsers.vzdumpPostep`). Trwająca pozycja liczy się jako pół, żeby
/// pasek nie stał nieruchomo przez całą minutę pakowania jednego kontenera.
struct PasekPostepu: View {
    let ulamek: Double
    let kolor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(kolor)
                    .frame(width: max(3, geo.size.width * ulamek))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.4), value: ulamek)
    }
}

/// Formatowanie czasu przebiegu — trwające liczą się w przód, zakończone wstecz.
///
/// Zostaje przy MainActorze (domyślnej izolacji projektu) razem z `Format`: `RelativeDateTimeFormatter`
/// nie jest `Sendable`, a jedynym miejscem, które to woła, są widoki.
enum PrzebiegFormat {
    private static let wzgledny: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = .current // od 2026-10-04 język systemu (był pl_PL) — tor „mNas po angielsku”
        return f
    }()

    /// Prędkość i ile już zapisano — do dopisku pod nazwą.
    ///
    /// Wartość niebieżąca dostaje dopisek „ostatnio", bo pochodzi z **zakończonej**
    /// fazy i potrafi być sprzed minuty. Pokazanie jej bez zastrzeżenia znaczyłoby
    /// „tyle leci teraz", co bywa nieprawdą — a to jest liczba, na którą się patrzy
    /// właśnie po to, żeby wiedzieć, czy coś się jeszcze rusza.
    static func tempo(_ p: Przebieg) -> String? {
        var czesci: [String] = []
        if let rozmiar = p.rozmiarBajtow, rozmiar > 0 {
            czesci.append(Format.shortBytes(rozmiar))
        }
        if let v = p.predkosc, v > 0 {
            let naSekunde = Format.shortBytes(Int64(v)) + "/s"
            czesci.append(p.predkoscBiezaca ? naSekunde : String(localized: "ostatnio \(naSekunde)"))
        }
        return czesci.isEmpty ? nil : czesci.joined(separator: " · ")
    }

    static func czas(_ p: Przebieg) -> String {
        if p.stan == .trwa {
            guard let t = p.czasTrwania else { return "" }
            return Format.uptime(t)
        }
        guard let kiedy = p.koniec ?? p.start else { return "" }
        return wzgledny.localizedString(for: kiedy, relativeTo: Date())
    }
}

// MARK: - Ustawienia panelu (P14)

/// Ekran wyboru zawartości panelu spod ikony.
///
/// > [!important] Lista jest **niezależna od kafli okna głównego**
/// > Decyzja 2026-08-29, potwierdzona wprost przy wznowieniu pracy. Powód: w oknie
/// > stoi osiemnaście kafli, z których większość w pasku szerokim na 340 pt nie ma sensu
/// > (wykresy rdzeni, siatka maszyn), a zgłoszenie mówiło o tym, co ma być **w tym
/// > okienku**. Gdyby to miał być podzbiór kafli, zmiana dotyczy `ModulPanelu`, nie tego
/// > ekranu — widok czyta gotową listę.
///
/// Zapis idzie do tego samego pliku config co układ kafli, więc wybór przeżywa nową
/// wersję programu. To jest ta sama reguła, która domknęła P13.
private struct EkranUstawienPanelu: View {
    let layout: DashboardLayout
    var gotowe: () -> Void

    private var ustawienia: UstawieniaPanelu { layout.panelPaska }

    var body: some View {
        ThinScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Zaznacz, co ma być widać w tym okienku.")
                    .font(.caption.weight(.medium))
                Text(podpisReguly)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                sekcjaKolejnosci

                sekcja("SKRÓTY PANELU", ModulPanelu.skroty,
                       podpis: "Widoki, których w oknie głównym nie ma.")
                sekcja("KAFLE Z OKNA GŁÓWNEGO", ModulPanelu.kafleOkna,
                       podpis: "Ten sam kafel co w oknie, jeden do jednego.")

                Button("Gotowe") { gotowe() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    /// Podpis mówi, co **właśnie** zrobi wybór — reguła opisana w oderwaniu od stanu
    /// zmuszałaby do liczenia zaznaczeń w głowie.
    private var podpisReguly: String {
        let ile = ustawienia.wybrane.count
        let stron = ustawienia.liczbaStron
        if stron == 1 {
            return ile == 1
                ? String(localized: "Jedna pozycja — zajmie całe okienko.")
                : String(localized: "Dwie pozycje po pół — jedno okienko, bez strzałek.")
        }
        return String(localized: "\(ile) pozycji · \(stron) strony do przewijania strzałkami. Pozycja „Całe” zajmuje stronę sama, dwie „Pół” dzielą ją między siebie.")
    }

    /// Wybrane pozycje w **ich własnej** kolejności, z miejscem, jakie zajmą.
    ///
    /// 🔴 To jedyne miejsce w ustawieniach, gdzie widać rzeczywisty układ panelu.
    /// Sekcje niżej wypisują dostępne moduły w stałym porządku — dobre do zaznaczania,
    /// bezużyteczne do układania.
    @ViewBuilder private var sekcjaKolejnosci: some View {
        let wybrane = ustawienia.wybrane
        VStack(alignment: .leading, spacing: 6) {
            Text("ROZMIESZCZENIE")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Text("Kolejność decyduje, co stoi obok czego. Strzałkami przesuwasz pozycję między stronami i połówkami.")
                .font(.caption2).foregroundStyle(.quaternary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(wybrane.enumerated()), id: \.element) { i, m in
                let gdzie = ustawienia.polozenie(m)
                HStack(spacing: 6) {
                    Text("\(i + 1).")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.quaternary)
                        .frame(width: 16, alignment: .trailing)

                    Label(m.tytul, systemImage: m.ikona)
                        .font(.caption.weight(.medium)).lineLimit(1)

                    Spacer(minLength: 4)

                    if let gdzie {
                        // To jest odpowiedź na „nie widzę, gdzie będzie stało okno".
                        Text("str. \(gdzie.strona) · \(gdzie.opis)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        layout.panelPaska.przesun(m, o: -1)
                    } label: {
                        Image(systemName: "arrow.up").font(.caption2.bold())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!ustawienia.czyMoznaWGore(m))
                    .help("Wyżej — bliżej pierwszej strony")

                    Button {
                        layout.panelPaska.przesun(m, o: 1)
                    } label: {
                        Image(systemName: "arrow.down").font(.caption2.bold())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!ustawienia.czyMoznaWDol(m))
                    .help("Niżej — dalej od pierwszej strony")
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func sekcja(_ tytul: LocalizedStringKey, _ lista: [ModulPanelu], podpis: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tytul)
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Text(podpis)
                .font(.caption2).foregroundStyle(.quaternary)
            ForEach(lista) { m in wiersz(m) }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func wiersz(_ m: ModulPanelu) -> some View {
        let wybrany = ustawienia.zawiera(m)
        // 🔴 Ostatniego modułu nie da się wyłączyć — pusty panel wygląda dokładnie jak
        // zepsuty panel, a użytkownik nie miałby z niego drogi powrotnej. Reguła stoi w modelu;
        // tutaj tylko widać, dlaczego przycisk nie reaguje.
        let ostatni = wybrany && ustawienia.wybrane.count == 1
        VStack(alignment: .leading, spacing: 4) {
            Button {
                layout.panelPaska.przelacz(m)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: wybrany ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(wybrany ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Label(m.tytul, systemImage: m.ikona)
                            .font(.caption.weight(.medium))
                        Text(ostatni
                             ? String(localized: "Ostatniej pozycji nie da się wyłączyć — puste okienko wygląda jak zepsute.")
                             : m.opis)
                            .font(.caption2)
                            .foregroundStyle(ostatni ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ostatni)

            // Rozmiar pokazujemy tylko przy zaznaczonych — przełącznik przy pozycji,
            // której nie ma w panelu, sterowałby niczym.
            if wybrany {
                HStack(spacing: 6) {
                    Picker("Rozmiar", selection: Binding(
                        get: { ustawienia.rozmiar(m) },
                        set: { layout.panelPaska.ustawRozmiar($0, dla: m) }
                    )) {
                        ForEach(RozmiarModulu.allCases, id: \.self) { r in
                            Text(r.etykieta).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)

                    // Strzałki kolejności NIE stoją tutaj — mieszkają w sekcji
                    // „ROZMIESZCZENIE" na górze, gdzie widać skutek ruchu. Tutaj lista
                    // jest w stałym porządku i strzałka byłaby ruchem w ciemno.
                    if let gdzie = ustawienia.polozenie(m) {
                        Text("str. \(gdzie.strona) · \(gdzie.opis)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }
}
