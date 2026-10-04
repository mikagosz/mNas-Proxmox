import SwiftUI
import AppKit

@main
struct mNasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    /// Zabezpieczenie przed **klasycznymi** paskami przewijania — tylko w tej aplikacji.
    ///
    /// Właściwy pasek rysuje `ThinScrollView` (cienki, zawsze widoczny). To ustawienie
    /// pilnuje wyłącznie tego, żeby AppKit nie dorysował swojego szerokiego paska tam,
    /// gdzie został jeszcze goły `ScrollView` — np. w bloku wyjścia terminala.
    ///
    /// W Ustawieniach systemu [U] ma „Pokaż paski przewijania: **Zawsze**". W tym
    /// trybie AppKit rysuje paski w stylu klasycznym: szerokie, wrośnięte w układ
    /// (zabierają szerokość treści) i widoczne bez przerwy. `scrollIndicators(.never)`
    /// tego nie ruszy — decyduje styl paska, nie widoczność wskaźnika.
    ///
    /// `AppleShowScrollBars` czyta się z łańcucha domen `UserDefaults`, a domena
    /// aplikacji ma pierwszeństwo przed globalną. Ustawiamy więc własną wartość:
    /// system zostaje nietknięty, a mNas dostaje paski nakładkowe — wąskie, unoszące
    /// się nad treścią i znikające, gdy nikt nie przewija.
    ///
    /// Musi się wykonać **przed** powstaniem pierwszego okna, stąd `init`, a nie
    /// `onAppear`: AppKit odczytuje styl przy tworzeniu `NSScrollView`.
    init() {
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    }

    var body: some Scene {
        WindowGroup("mNas", id: Self.idOkna) {
            KorzenAplikacji(model: model, delegat: appDelegate)
                .environment(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) { PolecenieUstawien() }
            CommandGroup(after: .appInfo) {
                Button("Sprawdź aktualizacje…") { Task { await Updates.shared.check(manually: true) } }
            }
            CommandGroup(replacing: .help) { PrzyciskInstrukcji(tytul: "Instrukcja mNas") }
        }

        // Instrukcja: token, połączenie, SSH, historia, kafle — menu Pomoc, Ustawienia, ekran łączenia.
        Window("Instrukcja", id: OknoInstrukcji.id) {
            OknoInstrukcji()
        }
        .defaultSize(width: 720, height: 760)

        // Ustawienia programu — zębatka w nagłówku i na ekranie łączenia, ⌘,.
        Window("Ustawienia", id: OknoUstawien.id) {
            OknoUstawien()
        }
        .windowResizability(.contentSize)

        // Okna historii — jedno na kafel. `WindowGroup(for:)` z tą samą wartością nie
        // otwiera drugiego okna, tylko wyciąga istniejące (spec historii, część 3).
        WindowGroup("Historia", id: OknoHistorii.id, for: DashTileID.self) { $kafel in
            if let kafel {
                OknoHistoriiKafla(kafel: kafel).environment(model)
            }
        }
        .defaultSize(width: 720, height: 560)

        // Panele CPU, Transfery i dysku — do 1.2.13 arkusze, od 1.2.14 zwykłe okna
        // (zgłoszenie [U] 2026-10-04, `OknaPaneli.swift`).
        WindowGroup("Panel", id: OknoPaneluTrwalego.id, for: OknoPaneluTrwalego.Cel.self) { $cel in
            if let cel {
                OknoPaneluTrwalegoWidok(cel: cel).environment(model)
            }
        }
        .defaultSize(width: 680, height: 600)

        // `MenuBarExtra` żyje jako osobna scena, niezależnie od `WindowGroup` wyżej —
        // patrz uzasadnienie w `PasekMenu.swift`. Zamknięcie panelu programowo idzie
        // przez `NSApp.keyWindow?.close()`: w stylu `.window` panel jest w danej chwili
        // oknem kluczowym, a `MenuBarExtra` nie daje na to własnego API.
        MenuBarExtra {
            PanelPaskaMenu(
                model: model,
                zamknij: { NSApp.keyWindow?.close() },
                pokazOkno: { appDelegate.pokazOkno() }
            )
        } label: {
            PasekMenuEtykieta(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    /// Identyfikator głównego okna — potrzebny, żeby dało się je otworzyć **z powrotem**
    /// po zamknięciu, gdy program żyje dalej przez ikonę w pasku menu.
    static let idOkna = "glowne"
}

/// Cienka warstwa nad `RootView`, istniejąca po jedno: `openWindow` jest **wartością
/// środowiska SwiftUI**, więc da się ją odczytać tylko wewnątrz widoku — a ikona w pasku
/// menu żyje w AppKicie i musi dostać ją podaną jako domknięcie.
private struct KorzenAplikacji: View {
    let model: AppModel
    let delegat: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView()
            .frame(minWidth: 820, minHeight: 560)
            .onAppear {
                delegat.model = model
                delegat.uruchomPasekMenu(model: model) {
                    openWindow(id: mNasApp.idOkna)
                }
            }
    }
}

/// Delegat istnieje po jedno: żeby apka posprzątała po sobie przy zamykaniu.
///
/// Bez tego kanał PWM przestawiony suwakiem zostawał na serwerze w trybie ręcznym —
/// układ przestawał regulować obroty i nie podniósłby ich przy wzroście temperatury,
/// dopóki ktoś ręcznie nie wpisał `2` do `pwmX_enable` albo nie zrestartował serwera.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// Otwarcie okna, gdy żadnego już nie ma. Ustawiane przez widok, bo `openWindow`
    /// żyje w środowisku SwiftUI, a nie w AppKicie. Ikona sama w sobie to teraz scena
    /// `MenuBarExtra` w `mNasApp.body` — nie ma jej tu czego trzymać.
    private var otworzOkno: (() -> Void)?

    /// Wołane z `onAppear` głównego okna, więc przy **każdym** otwarciu okna —
    /// `sledzZamykanieOkien` ma własny strażnik, więc druga subskrypcja nie powstanie.
    @MainActor
    func uruchomPasekMenu(model: AppModel, otworzOkno: @escaping () -> Void) {
        self.otworzOkno = otworzOkno
        sledzZamykanieOkien()
        Updates.shared.isBusy = { [weak model] in model?.instalujeZbieracz ?? false }
    }

    /// Aktualizacje ruszają raz, przy starcie — niezależnie od tego, czy okno się otworzy
    /// (program może żyć samą ikoną w pasku menu).
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Updates.shared.start() }
    }

    /// Podnosi główne okno. Gdy użytkownik je zamknął, prosi SwiftUI o nowe.
    ///
    /// 🔴 Powrót do `.regular` musi być **przed** aktywacją i przed otwarciem okna.
    /// Program w trybie `.accessory` nie ma prawa mieć okna kluczowego — otwarte w tej
    /// kolejności okno pojawia się, ale zostaje nieaktywne: bez kursora w polach,
    /// bez reakcji na klawiaturę, z szarym paskiem tytułu.
    @MainActor
    func pokazOkno() {
        Dock.pokaz()
        NSApp.activate(ignoringOtherApps: true)
        // Okno panelu paska menu też siedzi w `NSApp.windows`, ale jest panelem i nie
        // może zostać głównym — `canBecomeMain` odsiewa je bez zgadywania po klasie.
        if let okno = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            okno.makeKeyAndOrderFront(nil)
        } else {
            otworzOkno?()
        }
    }

    // MARK: - Dock: program żyje po zamknięciu okna

    /// Zamknięcie ostatniego okna **nie kończy programu** — chowa go do paska menu.
    ///
    /// Domyślnie SwiftUI zamyka aplikację razem z ostatnim oknem `WindowGroup`.
    /// Przy ikonie w pasku menu to jest złe zachowanie: kliknięcie w czerwone kółko
    /// zabijałoby pilnowanie przebiegów, po które ta ikona w ogóle istnieje.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Kliknięcie w ikonę w Docku (albo ponowne `open` paczki), gdy okien nie ma.
    ///
    /// 🔴 **Zwracamy `false`, bo okno otwieramy sami.** Wartość zwracana nie znaczy
    /// „udało się" — znaczy „AppKit ma dołożyć swoje otwarcie okna". Przy `true`
    /// wychodziły **dwa okna naraz**: jedno z `pokazOkno()`, drugie od AppKitu.
    /// Zmierzone 2026-08-20: `okien=2` po jednym `open -a`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }   // okno jest — niech AppKit je po prostu podniesie
        pokazOkno()
        return false
    }

    /// Nasłuch zamykania okien — przez selektor `@objc`, nie przez domknięcie.
    ///
    /// 🔴 Wariant z domknięciem (`addObserver(forName:object:queue:using:)`) kompiluje
    /// się, ale daje ostrzeżenie: domknięcie jest `@Sendable`, a `NSWindow` należy do
    /// głównego aktora, więc odczyt `canBecomeMain` w środku jest sięganiem po stan
    /// izolowany. Zmierzone 2026-08-20 przy porcie do wersji TrueNAS — ostrzeżenie
    /// nie pada przy zwykłym budowaniu przyrostowym, bo ten plik się wtedy nie
    /// kompiluje, i dlatego umykało.
    ///
    /// Owinięcie ciała w `MainActor.assumeIsolated` **tego nie naprawia** — wtedy
    /// robi się z tego twardy błąd „sending 'powiadomienie' risks causing data races",
    /// bo `Notification` nie jest `Sendable` i nie da się jej przekazać przez granicę
    /// aktora. Lekiem jest metoda izolowana na głównym aktorze: `willCloseNotification`
    /// i tak przychodzi z AppKitu na głównym wątku.
    private func sledzZamykanieOkien() {
        guard !obserwujeOkna else { return }
        obserwujeOkna = true
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(oknoSieZamyka(_:)),
                                              name: NSWindow.willCloseNotification,
                                              object: nil)
    }

    @objc private func oknoSieZamyka(_ powiadomienie: Notification) {
        guard let okno = powiadomienie.object as? NSWindow,
              okno.canBecomeMain, !(okno is NSPanel) else { return }
        // `willClose` przychodzi, **zanim** okno zniknie z `NSApp.windows` — sprawdzenie
        // „czy zostało jeszcze jakieś" musi więc poczekać jedną turę pętli zdarzeń.
        // Bez tego program nigdy nie schowałby się do paska: zamykane okno wciąż
        // liczyłoby się jako widoczne.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Dock.schowajGdyBrakOkien() }
        }
    }

    private var obserwujeOkna = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasManualPWM else { return .terminateNow }
        Task {
            await model.restorePWMAuto()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        // Zamknięcie czeka na przywrócenie automatu. `setPWMAuto` dostaje krótki limit
        // czasu, więc nawet niedostępny serwer nie zablokuje wyjścia z programu.
        return .terminateLater
    }
}
