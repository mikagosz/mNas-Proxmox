import Testing
import AppKit
@testable import mNas

/// Pomiar mechanizmu, na którym poległy **dwie** naprawy przełączania panelu w pasku menu.
///
/// Zgłoszenie 2026-08-23, po drugiej nieudanej próbie: *„klikam raz — okienko się
/// pojawia, klikam drugi raz — chowa się, kliknę trzeci raz — okienko ma się pojawić.
/// Nadal jest ten sam błąd"*. Czyli **co drugie kliknięcie martwe**.
///
/// > [!danger] 🔴 WYNIK: hipoteza OBALONA pomiarem. Ta ścieżka jest wykluczona.
/// > Podejrzenie brzmiało: `performClose(_:)` nie gasi `isShown` natychmiast, więc kod
/// > pytający zaraz potem `if panel.isShown` dostawał jeszcze `true` i zamykał panel
/// > drugi raz zamiast go otworzyć.
/// >
/// > **Zmierzone 2026-08-23: `performClose` gasi `isShown` OD RAZU** (`p.isShown → false`),
/// > a sekwencja otwórz–zamknij–otwórz oparta na samym `isShown` działa w izolacji
/// > poprawnie. Przyczyna „co drugie kliknięcie martwe" leży **gdzie indziej** — najpewniej
/// > w ścieżce zdarzeń (podglądacze `NSEvent`, aktywacja aplikacji), a nie w stanie popovera.
/// >
/// > Te testy zostają jako **zapis wykluczenia**. Bez nich następna sesja poszłaby
/// > tą samą ślepą drogą trzeci raz.
@MainActor
@Suite("NSPopover: czy zamknięcie gasi isShown natychmiast", .serialized)
struct PopoverZamykanieTests {

    /// Popover musi być zakotwiczony w widoku należącym do okna, inaczej `show` nic nie robi.
    private func zbudujPopover() -> (popover: NSPopover, kotwica: NSView, okno: NSWindow) {
        let okno = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let kotwica = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        okno.contentView?.addSubview(kotwica)
        okno.orderFront(nil)

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let tresc = NSViewController()
        tresc.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        popover.contentViewController = tresc
        return (popover, kotwica, okno)
    }

    @Test("Kontrola dodatnia: popover w ogóle się otwiera")
    func popoverSieOtwiera() {
        let (p, kotwica, okno) = zbudujPopover()
        defer { p.close(); okno.orderOut(nil) }
        p.show(relativeTo: kotwica.bounds, of: kotwica, preferredEdge: .minY)
        // Bez tego wszystkie pozostałe pomiary w tym pliku znaczyłyby „nie wiem".
        #expect(p.isShown)
    }

    /// 🔴 Zmierzone: `performClose` gasi stan **natychmiast**, tak samo jak `close()`.
    /// To wyklucza „odroczone zamknięcie" jako przyczynę martwego trzeciego kliknięcia.
    @Test("performClose gasi isShown natychmiast — wbrew podejrzeniu")
    func performCloseGasiNatychmiast() {
        let (p, kotwica, okno) = zbudujPopover()
        defer { p.close(); okno.orderOut(nil) }
        p.show(relativeTo: kotwica.bounds, of: kotwica, preferredEdge: .minY)
        #expect(p.isShown)

        p.performClose(nil)
        #expect(!p.isShown)
    }

    @Test("close() gasi isShown od razu")
    func closeGasiOdRazu() {
        let (p, kotwica, okno) = zbudujPopover()
        defer { okno.orderOut(nil) }
        p.show(relativeTo: kotwica.bounds, of: kotwica, preferredEdge: .minY)
        #expect(p.isShown)

        p.close()
        #expect(!p.isShown)
    }

    /// 🔴 Próba odtworzenia zgłoszenia na gołym `NSPopover`: **objaw NIE odtwarza się**.
    /// Sama logika „pytaj `isShown`, zamykaj `performClose`" daje poprawne
    /// otwórz–zamknij–otwórz. Czyli winna jest ścieżka **zdarzeń wokół** popovera,
    /// nie on sam. Ten test pilnuje, żeby ten wniosek nie wyparował.
    @Test("Sama logika isShown + performClose działa poprawnie w izolacji")
    func sekwencjaNaIsShownDzialaWIzolacji() {
        let (p, kotwica, okno) = zbudujPopover()
        defer { p.close(); okno.orderOut(nil) }

        func klik() {
            if p.isShown { p.performClose(nil) }
            else { p.show(relativeTo: kotwica.bounds, of: kotwica, preferredEdge: .minY) }
        }

        klik(); #expect(p.isShown)    // 1: otwiera
        klik(); #expect(!p.isShown)   // 2: zamyka
        klik(); #expect(p.isShown)    // 3: otwiera — w izolacji błędu nie ma
    }

    /// Ta sama sekwencja, ale decyzja idzie po **własnym stanie**, a zamknięcie przez
    /// `close()` — czyli tak, jak działa `PasekMenu` po naprawie. Trzecie kliknięcie
    /// ma otworzyć panel.
    @Test("Na własnym stanie i close() trzecie kliknięcie otwiera")
    func trzecieKlikniecieDziala() {
        let (p, kotwica, okno) = zbudujPopover()
        defer { p.close(); okno.orderOut(nil) }
        var otwarty = false

        func klik() {
            if otwarty { p.close(); otwarty = false }
            else { p.show(relativeTo: kotwica.bounds, of: kotwica, preferredEdge: .minY); otwarty = true }
        }

        klik(); #expect(p.isShown)   // 1
        klik(); #expect(!p.isShown)  // 2
        klik(); #expect(p.isShown)   // 3 — to jest to, o co poszło zgłoszenie
        klik(); #expect(!p.isShown)  // 4
        klik(); #expect(p.isShown)   // 5
    }
}
