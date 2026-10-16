import Foundation

/// Alarmy, które użytkownik odhaczył — „widziałem, wiem, nie świeć mi już na czerwono".
///
/// > [!important] Po co to powstało
/// > Zgłoszenie 2026-08-23: *„powinien być przycisk że zapoznałem się z alertem,
/// > żeby ikona w menu bar zmieniła się z czerwonej na zieloną — w tym małym okienku
/// > oraz na głównym w kafelku z tymi info"*.
/// >
/// > Przed tą zmianą czerwona odznaka gasła **wyłącznie wtedy, gdy mechanizm sam wszedł
/// > w dobry stan**. Nieudana kopia sprzed trzech dni świeciła więc bez końca: nikt jej
/// > już nie powtórzy, więc stan `bledny` z niej nigdy nie zejdzie. Ikona przestawała
/// > nieść informację — czerwień znaczyła „kiedyś coś padło", a nie „popatrz na mnie".
/// >
/// > Odhaczenie **nie udaje, że problemu nie było**: wpis w rejestrze zdarzeń zostaje,
/// > wiersz w „Przebiegach" zostaje, znika wyłącznie kolor alarmu. To ta sama różnica
/// > co przy chmurce — „przeczytane", nie „usunięte".
///
/// > [!danger] 🔴 Odhaczenie dotyczy JEDNEGO wystąpienia, nie mechanizmu
/// > Klucz niesie znacznik czasu zdarzenia, więc **kolejna** nieudana kopia tego samego
/// > zadania zapala czerwień od nowa. Gdyby kluczem był sam identyfikator przebiegu,
/// > jedno kliknięcie wyciszyłoby ten mechanizm na zawsze — a to jest dokładnie ten
/// > rodzaj cichej awarii, przed którym monitoring ma chronić.
nonisolated enum KluczAlertu {

    /// Tożsamość jednego wystąpienia alarmu. `nil`, gdy przebieg w ogóle nie alarmuje.
    ///
    /// Dwa rodzaje alarmu mają osobne klucze, bo to dwie różne rzeczy:
    /// - `bledny` / `cisza` — zdarzenie **zakończone**, znacznikiem jest `koniec ?? start`;
    /// - `przekroczylCzas` — przebieg **wciąż trwa**, `koniec` jest pusty z definicji,
    ///   więc znacznikiem jest `start`. Ponowne uruchomienie zmienia `start` i alarm wraca.
    static func dla(_ przebieg: Przebieg) -> String? {
        if przebieg.stan.alarmujacy {
            return "\(przebieg.id)|\(przebieg.stan.rawValue)|\(sekundy(przebieg.koniec ?? przebieg.start))"
        }
        if przebieg.przekroczylCzas {
            return "\(przebieg.id)|dlugo|\(sekundy(przebieg.start))"
        }
        return nil
    }

    /// Sekundy zamiast pełnej daty: `Date` ma rozdzielczość poniżej mikrosekundy, a ten
    /// sam odczyt potrafi wrócić z serwera minimalnie inaczej sformatowany. Klucz musi
    /// być **stabilny między turami odświeżania**, inaczej odhaczenie gasłoby samo.
    private static func sekundy(_ data: Date?) -> Int {
        guard let data else { return 0 }
        return Int(data.timeIntervalSince1970)
    }
}

/// Zbiór odhaczonych alarmów, przeżywający restart programu.
///
/// Przeżywa świadomie: bez tego zamknięcie i otwarcie mNas przywracałoby czerwień
/// dla czegoś, co użytkownik już przeczytał — czyli dokładnie zachowanie, które zgłosił.
@MainActor
@Observable
final class PotwierdzoneAlerty {

    /// Ile kluczy trzymamy. Zbiór jest czyszczony z nieistniejących alarmów przy każdym
    /// odświeżeniu (`zapomnijNieistniejace`), więc limit jest tu wyłącznie bezpiecznikiem
    /// na wypadek, gdyby przebiegi zmieniały tożsamość szybciej, niż zdąży sprzątanie.
    static let limit = 200

    private static let klucz = "mNasProxmox.potwierdzoneAlerty"

    private(set) var klucze: Set<String> = []

    init() {
        if let zapisane = MagazynUstawien.domyslny.stringArray(forKey: Self.klucz) {
            klucze = Set(zapisane)
        }
    }

    /// Czy ten przebieg ma jeszcze alarmować.
    func alarmuje(_ przebieg: Przebieg) -> Bool {
        guard let klucz = KluczAlertu.dla(przebieg) else { return false }
        return !klucze.contains(klucz)
    }

    /// Odhacza wszystkie alarmy z podanej listy. Przebiegi, które nie alarmują, są
    /// pomijane — inaczej zbiór zapełniłby się kluczami zdrowych mechanizmów.
    func potwierdz(_ przebiegi: [Przebieg]) {
        let nowe = przebiegi.compactMap { KluczAlertu.dla($0) }
        guard !nowe.isEmpty else { return }
        klucze.formUnion(nowe)
        if klucze.count > Self.limit { klucze = Set(klucze.prefix(Self.limit)) }
        zapisz()
    }

    /// Wyrzuca klucze alarmów, których już nie ma na liście przebiegów.
    ///
    /// Bez tego zbiór rósłby w nieskończoność, a co gorsza — odhaczenie sprzed tygodnia
    /// mogłoby przypadkiem trafić w klucz nowego zdarzenia o tym samym znaczniku czasu.
    func zapomnijNieistniejace(_ przebiegi: [Przebieg]) {
        let zywe = Set(przebiegi.compactMap { KluczAlertu.dla($0) })
        let zostaje = klucze.intersection(zywe)
        guard zostaje != klucze else { return }
        klucze = zostaje
        zapisz()
    }

    private func zapisz() {
        MagazynUstawien.domyslny.set(Array(klucze), forKey: Self.klucz)
    }
}
