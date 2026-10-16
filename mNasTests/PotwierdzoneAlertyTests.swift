import Testing
import Foundation
@testable import mNas

/// Odhaczanie alertów — „zapoznałem się", czyli gaszenie czerwieni bez kasowania historii.
///
/// Zgłoszenie 2026-08-23: *„powinien być przycisk że zapoznałem się z alertem, żeby
/// ikona w menu bar zmieniła się z czerwonej na zieloną"*.
///
/// 🔴 Najważniejszy test w tym pliku to `kolejnaAwariaZapalaOdNowa`. Odhaczenie, które
/// wycisza mechanizm **na stałe**, jest gorsze niż brak odhaczania: monitoring milczy
/// wtedy dokładnie wtedy, kiedy powinien krzyczeć.
@MainActor
@Suite("Odhaczanie alertów: gasi kolor, nie historię", .serialized)
struct PotwierdzoneAlertyTests {

    /// 🔴 `.serialized` i czyszczenie klucza z tego samego powodu co w `ZdarzeniaTests`:
    /// wszystkie te testy piszą do **jednego** klucza `UserDefaults`. Bez tego jeden
    /// zostawiałby drugiemu odhaczenia i „nie alarmuje" wychodziłoby prawdą z cudzych
    /// danych, a nie z tego, co test faktycznie zrobił.
    private func czystyZbior() -> PotwierdzoneAlerty {
        MagazynUstawien.domyslny.removeObject(forKey: "mNasProxmox.potwierdzoneAlerty")
        return PotwierdzoneAlerty()
    }

    private func przebieg(id: String = "kopia-nocna",
                          stan: Przebieg.Stan = .bledny,
                          koniec: Date? = Date(timeIntervalSince1970: 1_000_000),
                          start: Date? = nil,
                          limitSekund: Double? = nil) -> Przebieg {
        Przebieg(id: id, nazwa: "Kopia nocna", zrodlo: .serwer, stan: stan,
                 start: start, koniec: koniec, limitSekund: limitSekund)
    }

    // MARK: - Klucz alarmu

    @Test("Zdrowy przebieg nie ma klucza — nie ma czego odhaczać")
    func zdrowyNieMaKlucza() {
        #expect(KluczAlertu.dla(przebieg(stan: .udany)) == nil)
        #expect(KluczAlertu.dla(przebieg(stan: .trwa, koniec: nil)) == nil)
    }

    @Test("Błąd i cisza mają klucze, i są to RÓŻNE klucze")
    func bladICiszaMajaRozneKlucze() {
        let bledny = KluczAlertu.dla(przebieg(stan: .bledny))
        let cisza = KluczAlertu.dla(przebieg(stan: .cisza))
        #expect(bledny != nil)
        #expect(cisza != nil)
        // Ten sam mechanizm, ta sama godzina, inny rodzaj kłopotu — dwa osobne alarmy.
        #expect(bledny != cisza)
    }

    @Test("Klucz jest stabilny między turami odświeżania")
    func kluczStabilny() {
        // Gdyby klucz niósł pełną precyzję `Date` albo cokolwiek losowego, odhaczenie
        // gasłoby samo przy następnym odczycie z serwera.
        let a = KluczAlertu.dla(przebieg())
        let b = KluczAlertu.dla(przebieg())
        #expect(a == b)
    }

    @Test("Przebieg trwający zbyt długo też ma klucz, liczony ze startu")
    func przekroczonyCzasMaKlucz() {
        // `koniec` z definicji jest pusty przy trwającym przebiegu, więc znacznikiem
        // musi być `start` — inaczej wszystkie zawieszone przebiegi miałyby ten sam klucz.
        let dlugi = przebieg(stan: .trwa, koniec: nil,
                             start: Date(timeIntervalSinceNow: -600), limitSekund: 60)
        #expect(dlugi.przekroczylCzas)
        #expect(KluczAlertu.dla(dlugi) != nil)
    }

    // MARK: - Zbiór odhaczonych

    @Test("Po odhaczeniu przebieg przestaje alarmować")
    func odhaczonyNieAlarmuje() {
        let zbior = czystyZbior()
        let p = przebieg()
        #expect(zbior.alarmuje(p))
        zbior.potwierdz([p])
        #expect(!zbior.alarmuje(p))
    }

    /// 🔴 Sedno całej funkcji. Odhaczenie dotyczy **jednego wystąpienia**.
    @Test("Kolejna awaria tego samego mechanizmu zapala alarm od nowa")
    func kolejnaAwariaZapalaOdNowa() {
        let zbior = czystyZbior()
        let wczoraj = przebieg(koniec: Date(timeIntervalSince1970: 1_000_000))
        zbior.potwierdz([wczoraj])
        #expect(!zbior.alarmuje(wczoraj))

        // Ta sama kopia, następnej nocy, znowu nieudana.
        let dzisiaj = przebieg(koniec: Date(timeIntervalSince1970: 1_086_400))
        #expect(zbior.alarmuje(dzisiaj))
    }

    @Test("Odhaczenie jednego mechanizmu nie gasi drugiego")
    func odhaczenieNieRozlewaSie() {
        let zbior = czystyZbior()
        let a = przebieg(id: "kopia-a")
        let b = przebieg(id: "kopia-b")
        zbior.potwierdz([a])
        #expect(!zbior.alarmuje(a))
        #expect(zbior.alarmuje(b))
    }

    @Test("Zdrowe przebiegi nie zaśmiecają zbioru")
    func zdroweNieWchodzaDoZbioru() {
        let zbior = czystyZbior()
        zbior.potwierdz([przebieg(stan: .udany), przebieg(stan: .trwa, koniec: nil)])
        #expect(zbior.klucze.isEmpty)
    }

    @Test("Alarm, którego już nie ma na liście, przestaje zajmować miejsce")
    func sprzatanieNieistniejacych() {
        let zbior = czystyZbior()
        let znikajacy = przebieg(id: "kopia-wygaszona")
        let zostajacy = przebieg(id: "kopia-zywa")
        zbior.potwierdz([znikajacy, zostajacy])
        #expect(zbior.klucze.count == 2)

        zbior.zapomnijNieistniejace([zostajacy])
        #expect(zbior.klucze.count == 1)
        #expect(!zbior.alarmuje(zostajacy))
    }

    // MARK: - Ikona w pasku menu

    @Test("Odhaczony błąd daje zielony ptaszek zamiast czerwonego krzyżyka")
    func odhaczonyBladDajeZielonyPtaszek() {
        let p = przebieg()
        let przedOdhaczeniem = StanPaska(przebiegi: [p], polaczony: true)
        #expect(przedOdhaczeniem.odznaka == .blad)

        let klucz = KluczAlertu.dla(p)!
        let poOdhaczeniu = StanPaska(przebiegi: [p], polaczony: true, odhaczone: [klucz])
        // To jest dokładnie to, o co poszło zgłoszenie: z czerwonej na zieloną.
        #expect(poOdhaczeniu.odznaka == .wporzadku)
    }

    @Test("Odhaczenie jednego z dwóch alarmów nie gasi ikony")
    func jedenOdhaczonyDrugiZostaje() {
        let a = przebieg(id: "kopia-a")
        let b = przebieg(id: "kopia-b")
        let stan = StanPaska(przebiegi: [a, b], polaczony: true,
                             odhaczone: [KluczAlertu.dla(a)!])
        #expect(stan.odznaka == .blad)
        #expect(stan.alarmow == 1)
    }

    @Test("Odhaczenie nie tyka trwających przebiegów — play zostaje")
    func odhaczenieNieGasiPracy() {
        let bledny = przebieg(id: "kopia-a")
        let trwajacy = przebieg(id: "kopia-b", stan: .trwa, koniec: nil,
                                start: Date(timeIntervalSinceNow: -10))
        let stan = StanPaska(przebiegi: [bledny, trwajacy], polaczony: true,
                             odhaczone: [KluczAlertu.dla(bledny)!])
        #expect(stan.odznaka == .praca)
        #expect(stan.trwajacych == 1)
    }
}
