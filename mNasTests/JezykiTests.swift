import Testing
import Foundation
@testable import mNas

/// Dwa języki interfejsu (od 2026-10-04, tor „mNas po angielsku”).
///
/// Polskie teksty są w kodzie kluczami, angielski jest tłumaczeniem. Pułapka zmierzona
/// przy wdrażaniu: kompilator katalogu nie tworzył `pl.lproj`, bo język źródłowy uważał
/// za zapisany w kodzie — i polski system dostawał angielski. Te testy pilnują, żeby
/// to nie wróciło.
@Suite("Języki: polski i angielski w pakiecie programu")
struct JezykiTests {
    private func tabela(_ jezyk: String) -> Bundle? {
        Bundle.main.path(forResource: jezyk, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    @Test("Pakiet ma pl.lproj i en.lproj")
    func obaKatalogi() {
        #expect(tabela("pl") != nil)
        #expect(tabela("en") != nil)
    }

    @Test("Polski system dostaje polski, obcy — angielski")
    func wyborJezyka() {
        let mamy = Bundle.main.localizations
        #expect(Bundle.preferredLocalizations(from: mamy, forPreferences: ["pl-PL"]).first == "pl")
        #expect(Bundle.preferredLocalizations(from: mamy, forPreferences: ["en-GB"]).first == "en")
        #expect(Bundle.preferredLocalizations(from: mamy, forPreferences: ["de-DE"]).first == "en")
    }

    @Test("Odmiana po liczbie działa w obu językach")
    func odmiana() throws {
        let pl = try #require(tabela("pl"))
        let en = try #require(tabela("en"))
        #expect(String(localized: "co \(1) minut", bundle: pl) == "co 1 minutę")
        #expect(String(localized: "co \(2) minut", bundle: pl) == "co 2 minuty")
        #expect(String(localized: "co \(5) minut", bundle: pl) == "co 5 minut")
        #expect(String(localized: "co \(1) minut", bundle: en) == "every 1 minute")
        #expect(String(localized: "co \(5) minut", bundle: en) == "every 5 minutes")
    }

    @Test("Angielski: nazwy kafli i komunikaty po angielsku")
    func angielskiePodpisy() throws {
        let en = try #require(tabela("en"))
        #expect(en.localizedString(forKey: "Dyski", value: nil, table: nil) == "Disks")
        #expect(en.localizedString(forKey: "Zdarzenia", value: nil, table: nil) == "Events")
        #expect(en.localizedString(forKey: "Brak połączenia z serwerem.", value: nil, table: nil) == "No connection to the server.")
    }

    @Test("To samo hasło: po polsku zostaje, po angielsku jest przetłumaczone")
    func tlumaczenie() {
        #expect(tabela("pl")?.localizedString(forKey: "Rozłącz", value: nil, table: nil) == "Rozłącz")
        #expect(tabela("en")?.localizedString(forKey: "Rozłącz", value: nil, table: nil) == "Disconnect")
    }
}

/// Wybór języka w oknie ustawień — zapis do domeny programu (`AppleLanguages`).
@Suite("Języki: wybór w ustawieniach programu")
struct JezykProgramuTests {
    private func domena() -> (UserDefaults, String) {
        let nazwa = "mNasTests.jezyk.\(UUID().uuidString)"
        return (UserDefaults(suiteName: nazwa)!, nazwa)
    }

    @Test("Bez zapisu — według systemu")
    func domyslnie() {
        let (u, n) = domena(); defer { u.removePersistentDomain(forName: n) }
        #expect(JezykProgramu.odczytaj(u, domena: n) == .systemowy)
    }

    @Test("Zapis i odczyt polskiego, angielskiego i powrót do systemu")
    func zapisOdczyt() {
        let (u, n) = domena(); defer { u.removePersistentDomain(forName: n) }
        JezykProgramu.angielski.zapisz(u)
        #expect(u.persistentDomain(forName: n)?["AppleLanguages"] as? [String] == ["en"])
        #expect(JezykProgramu.odczytaj(u, domena: n) == .angielski)
        JezykProgramu.polski.zapisz(u)
        #expect(JezykProgramu.odczytaj(u, domena: n) == .polski)
        JezykProgramu.systemowy.zapisz(u)
        #expect(u.persistentDomain(forName: n)?["AppleLanguages"] == nil)
        #expect(JezykProgramu.odczytaj(u, domena: n) == .systemowy)
    }

    @Test("Język po restarcie: wybrany wprost albo z ustawień systemu")
    func docelowy() {
        let mamy = ["en", "pl"]
        #expect(JezykProgramu.angielski.docelowy(dostepne: mamy, systemowe: ["pl-PL"]) == "en")
        #expect(JezykProgramu.polski.docelowy(dostepne: mamy, systemowe: ["en-GB"]) == "pl")
        #expect(JezykProgramu.systemowy.docelowy(dostepne: mamy, systemowe: ["pl-PL"]) == "pl")
        #expect(JezykProgramu.systemowy.docelowy(dostepne: mamy, systemowe: ["de-DE"]) == "en")
    }
}

/// Audyt językowy 2026-10-04: teksty składane w modelu i odmiana po liczbie.
@Suite("Języki: audyt — model, odmiana, formy bezosobowe")
struct AudytJezykowyTests {
    private func tabela(_ jezyk: String) -> Bundle? {
        Bundle.main.path(forResource: jezyk, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    @Test("Teksty z modelu i parserów mają angielski")
    func modelPoAngielsku() throws {
        let en = try #require(tabela("en"))
        // Każdy z tych tekstów przed audytem szedł jako zwykły `String` i w angielskim zostawał po polsku.
        let klucze = ["pierwsza synchronizacja", "pierwsza synchronizacja gotowa", "wstrzymywanie kontenera",
                      "domykanie kopii", "wznawianie kontenera", "pakowanie archiwum", "usuwanie starych kopii",
                      "kopiuje", "cisza", "w spoczynku", "RAM hosta", "Procesor (RAPL)", "Procesor (pakiet)",
                      "Wykorzystanie CPU", "cokolwiek poza PASSED", "zapis nieudany", "Tryb automatyczny",
                      "…generowanie klucza…", "Restart węzła"]
        for k in klucze {
            let t = en.localizedString(forKey: k, value: "@@BRAK", table: nil)
            #expect(t != "@@BRAK" && t != k, "brak angielskiego: \(k)")
        }
        #expect(String(localized: "Rdzeń \(3)", bundle: en) == "Core 3")
        #expect(String(localized: "z \("14:32:07")", bundle: en) == "from 14:32:07")
    }

    @Test("Polska odmiana po liczbie")
    func odmianaPolska() throws {
        let pl = try #require(tabela("pl"))
        #expect(String(localized: "\(1) rdzeni", bundle: pl) == "1 rdzeń")
        #expect(String(localized: "\(2) rdzeni", bundle: pl) == "2 rdzenie")
        #expect(String(localized: "\(5) rdzeni", bundle: pl) == "5 rdzeni")
        #expect(String(localized: "\(1) dysków", bundle: pl) == "1 dysk")
        #expect(String(localized: "\(22) przebiegi w toku", bundle: pl) == "22 przebiegi w toku")
        #expect(String(localized: "\(5) przebiegi w toku", bundle: pl) == "5 przebiegów w toku")
        #expect(String(localized: "Wykryto \(2) wentylator(y).", bundle: pl) == "Wykryto 2 wentylatory.")
    }

    @Test("Katalog bez form męskich wobec użytkownika i bez kluczy kodu")
    func bezosobowo() throws {
        let url = try #require(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                subdirectory: nil, localization: "pl"))
        let tresc = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for (k, v) in tresc {
            for slowo in ["Zapoznałem", "wymieniłeś", "wymieniałeś", "powiedz, jeśli mam"] {
                #expect(!k.contains(slowo) && !v.contains(slowo), "\(slowo) w: \(k)")
            }
        }
        #expect(tresc["ata_smart_attributes"] == nil)
    }
}

/// Instrukcja połączenia (1.2.22) i komunikaty wielowierszowe, które audyt przeoczył.
@Suite("Języki: instrukcja i komunikaty wielowierszowe")
struct InstrukcjaJezykiTests {
    @Test("Instrukcja i komunikaty błędów tokenu mają angielski")
    func angielski() throws {
        let en = try #require(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        for k in ["Jak połączyć mNas z Proxmoksem", "2. Token API — pełny dostęp", "3. Token API — tylko podgląd",
                  "Kafle mają **trzy rozmiary: Mały, Średni i Duży**.", "Jak przygotować serwer i token?",
                  "Identyfikator albo sekret tokenu zawiera znak nowej linii lub znak sterujący. Najczęstsza przyczyna: skopiowanie wartości razem z łamaniem wiersza. Wklej ją ponownie, w jednym kawałku."] {
            let t = en.localizedString(forKey: k, value: "@@BRAK", table: nil)
            #expect(t != "@@BRAK" && t != k, "brak angielskiego: \(k)")
        }
    }
}
