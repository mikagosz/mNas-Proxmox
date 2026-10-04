import Foundation

/// Rejestr zdarzeń — co się stało, kiedy i jak poszło.
///
/// > [!danger] Po co to powstało
/// > Zgłoszenie [U] z 2026-08-23: *„dostaje ikonka powiadomienia, ale jak otworzę okno
/// > to powiadomienie znika i generalnie nie wiem co się dzieje, wiem tylko że jedna akcja,
/// > ale jak? Jak przebiegła — zero informacji"*.
/// >
/// > Przyczyna nie była w chmurce, tylko w tym, że **poza nią nic nie zostawało**.
/// > Znacznik przy ikonie jest sygnałem, nie treścią: mówi „coś się wydarzyło", a po
/// > otwarciu panelu gaśnie — i wraz z nim znikała jedyna informacja, że cokolwiek było.
/// > Lista przebiegów pokazuje **stan teraz**, nie historię: przebieg, który przeszedł
/// > z „trwa" na „błąd" i z powrotem na „udany", wygląda tak samo jak taki, który po
/// > prostu się udał.
/// >
/// > Dlatego skasowanie znacznika znaczy tu **„przeczytane", nie „usunięte"**.
///
/// Rejestr przeżywa restart programu (`UserDefaults`), bo mNas bywa zamykany częściej,
/// niż zdarzają się kopie — historia trzymana wyłącznie w pamięci gasłaby razem z tym,
/// o co [U] pyta.

// MARK: - Jedno zdarzenie

nonisolated struct Zdarzenie: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var czas: Date
    /// Skąd przyszło — serwer, host, Uptime Kuma, ten Mac.
    var zrodlo: Przebieg.Zrodlo
    var nazwa: String
    /// Stan, w który mechanizm **wszedł**.
    var stan: Przebieg.Stan
    /// Stan poprzedni, gdy był znany. Bez niego „udany" nie mówi, czy coś się właśnie
    /// naprawiło, czy po prostu przeszło kolejny raz.
    var poprzedniStan: Przebieg.Stan?
    /// Wiadomość mechanizmu, tak jak ją podał.
    var opis: String?

    /// Zdanie do jednej linijki listy.
    var jednymZdaniem: String {
        if let poprzedniStan, poprzedniStan != stan {
            return String(localized: "\(poprzedniStan.opis) → \(stan.opis)")
        }
        return stan.opis
    }
}

// MARK: - Rejestr

@MainActor
@Observable
final class RejestrZdarzen {

    /// Ile zdarzeń trzymamy. Sto wystarcza na kilka tygodni nocnych kopii, a nie robi
    /// z `UserDefaults` archiwum — to nie jest baza danych i nie ma nią być.
    static let limit = 100

    private static let klucz = "mNasProxmox.zdarzenia"
    private static let kluczCzyszczenia = "mNasProxmox.zdarzeniaWyczyszczono"

    private(set) var zdarzenia: [Zdarzenie] = []

    /// Kiedy [U] ostatnio wyczyścił rejestr. `nil` = nigdy.
    ///
    /// > [!danger] 🔴 Bez tego kafel „Zdarzenia" kasował sam siebie
    /// > Zgłoszenie [U] 2026-08-23: *„jak w głównym kliknąłem wyczyść to kafelek zniknął
    /// > i się nie pojawił"*. Kafel pokazywał się pod warunkiem `!zdarzenia.isEmpty`,
    /// > a przycisk „Wyczyść rejestr" stał **w środku tego kafla** — czyli czyszczenie
    /// > wyrzucało z ekranu własny przycisk razem z całym modułem. Wracał dopiero przy
    /// > następnej zmianie stanu, czyli po godzinach albo po nocnej kopii.
    /// >
    /// > Ten znacznik trzyma kafel na ekranie po świadomym wyczyszczeniu: pusty rejestr
    /// > przestaje wtedy znaczyć „nic tu nie ma", a zaczyna „wyczyściłeś to o 22:41".
    /// > Ta sama zasada, co przy kaflu Alertów i jego `dismissedAlertCount`.
    private(set) var wyczyszczonoKiedy: Date?

    init() {
        if let dane = MagazynUstawien.domyslny.data(forKey: Self.klucz),
           let zapisane = try? JSONDecoder().decode([Zdarzenie].self, from: dane) {
            zdarzenia = zapisane
        }
        // `object(forKey:)`, nie `double(forKey:)` — to drugie zwraca 0 dla brakującego
        // klucza, czyli „wyczyszczono 1 stycznia 1970" zamiast „nigdy nie czyszczono".
        if let znacznik = MagazynUstawien.domyslny.object(forKey: Self.kluczCzyszczenia) as? Double {
            wyczyszczonoKiedy = Date(timeIntervalSince1970: znacznik)
        }
    }

    /// Dopisuje zdarzenie na górę listy.
    ///
    /// Tożsamość składa się z identyfikatora przebiegu i **znacznika czasu**, a nie
    /// z samego identyfikatora: ten sam mechanizm zgłasza się co noc i każde zgłoszenie
    /// jest osobnym zdarzeniem. `UUID()` odpada z tego samego powodu co przy `Alert` —
    /// lista jest przerysowywana i losowa tożsamość kazałaby `ForEach` budować ją od nowa.
    func dopisz(przebieg: Przebieg, poprzedniStan: Przebieg.Stan?, czas: Date = Date()) {
        let wpis = Zdarzenie(
            id: "\(przebieg.id)|\(Int(czas.timeIntervalSince1970))",
            czas: czas,
            zrodlo: przebieg.zrodlo,
            nazwa: przebieg.nazwa,
            stan: przebieg.stan,
            poprzedniStan: poprzedniStan,
            opis: przebieg.opis)

        // Ten sam przebieg w tej samej sekundzie to jedno zdarzenie, nie dwa — tura
        // odświeżania potrafi zobaczyć zmianę dwa razy, zanim stan się ustabilizuje.
        guard !zdarzenia.contains(where: { $0.id == wpis.id }) else { return }

        zdarzenia.insert(wpis, at: 0)
        if zdarzenia.count > Self.limit { zdarzenia.removeLast(zdarzenia.count - Self.limit) }
        // Rejestr znów ma treść, więc informacja „wyczyszczono o…" przestaje być prawdą
        // o tym, co widać. Bez tego kafel pokazywałby ją nad świeżą listą zdarzeń.
        wyczyszczonoKiedy = nil
        MagazynUstawien.domyslny.removeObject(forKey: Self.kluczCzyszczenia)
        zapisz()
    }

    /// Czyści rejestr. Wywoływane **wyłącznie** z jawnego przycisku — chmurka przy ikonie
    /// gaśnie sama po przeczytaniu i rejestru nie dotyka. To jest ta różnica między
    /// „przeczytane" a „usunięte", o którą poszło zgłoszenie.
    func wyczysc(czas: Date = Date()) {
        zdarzenia = []
        wyczyszczonoKiedy = czas
        MagazynUstawien.domyslny.set(czas.timeIntervalSince1970, forKey: Self.kluczCzyszczenia)
        zapisz()
    }

    private func zapisz() {
        guard let dane = try? JSONEncoder().encode(zdarzenia) else { return }
        MagazynUstawien.domyslny.set(dane, forKey: Self.klucz)
    }
}
