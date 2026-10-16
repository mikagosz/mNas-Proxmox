import AppKit

/// Obecność mNas w Docku — włączana i wyłączana w trakcie działania programu.
///
/// Decyzja 2026-08-20: **zamknięcie głównego okna chowa program z Docka.**
/// Uzasadnienie, dosłownie: *„po to jest w menu bar ikona"*. Program nie kończy
/// się przy zamknięciu okna — żyje dalej w pasku menu i dalej pilnuje przebiegów.
///
/// > [!warning] To NIE jest `LSUIElement`
/// > `LSUIElement` w `Info.plist` znaczy „ten program **nigdy** nie ma Docka" i jest
/// > nie do cofnięcia w trakcie działania. Tutaj potrzeba czegoś odwrotnego: program
/// > startuje **normalnie**, z Dockiem i oknem, a Dock znika dopiero po zamknięciu
/// > okna i wraca przy jego otwarciu. Robi to `NSApp.setActivationPolicy`, i tylko ono.
/// >
/// > Poprzednia wersja dokumentacji tego modułu mówiła „nie przestawiaj polityki
/// > aktywacji na `.accessory`". **Odwołane decyzją 2026-08-20** — dokładnie o to
/// > przestawienie chodzi. `LSUIElement` nadal zostaje wyłączony.
///
/// > [!note] Czego `.accessory` kosztuje
/// > Program bez Docka wypada też z przełącznika ⌘Tab i traci pasek menu u góry
/// > (Plik, Edycja, Okno). To jest normalne dla tego trybu, nie usterka — całe
/// > sterowanie jest wtedy w panelu spod ikony. Wszystko wraca przy otwarciu okna.
@MainActor
enum Dock {

    /// Program wraca do Docka. Wołane **przed** otwarciem albo podniesieniem okna.
    static func pokaz() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    /// Program znika z Docka — o ile faktycznie nie ma już żadnego zwykłego okna.
    ///
    /// Sprawdzenie jest konieczne, bo `willClose` przychodzi, **zanim** okno zniknie
    /// z `NSApp.windows`, a przy dwóch otwartych oknach zamknięcie jednego nie jest
    /// powodem do chowania programu.
    static func schowajGdyBrakOkien() {
        guard NSApp.activationPolicy() == .regular else { return }
        guard !maZwykleOkno() else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Czy jest jeszcze jakieś **widoczne** okno programu.
    ///
    /// Panel spod ikony w pasku menu (`NSPopover`) też ma okno w `NSApp.windows`,
    /// ale jest panelem i nie może zostać głównym — inaczej otwarty panel trzymałby
    /// program w Docku w nieskończoność.
    ///
    /// 🔴 **Nie jest już `private`** — od 2026-09-11 czyta to także `AppModel`, żeby
    /// zwolnić odpytywanie serwera, gdy nikt na te dane nie patrzy. Dwie kopie tego
    /// warunku rozjechałyby się przy pierwszej zmianie, więc jest jedna.
    static func maZwykleOkno() -> Bool {
        NSApp.windows.contains { okno in
            okno.canBecomeMain && !(okno is NSPanel) && okno.isVisible
        }
    }
}
