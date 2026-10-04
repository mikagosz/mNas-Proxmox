import Foundation

/// `UserDefaults` dla stanu, który testy czytają i piszą: rejestr zdarzeń, odhaczone
/// alerty i stare klucze układu kafli.
///
/// > [!danger] 🔴 Pod testami — osobna domena, nie domena programu
/// > Testy chodzą w procesie programu (`TEST_HOST`), więc `UserDefaults.standard` jest
/// > tam domeną `com.mikagosz.mNasProxmox` — tą samą, w której działający mNas trzyma
/// > historię zdarzeń [U]. Każdy przebieg testów ją kasował i nadpisywał danymi testowymi
/// > („Kopia na media”). Audyt SBW 2026-09-24, E1-S-P1-01.
/// >
/// > Tak jak `MagazynUkladu`: **przekierowanie, nie wyłączenie** — zapis dalej działa
/// > i da się go zmierzyć, tylko do pliku w katalogu tymczasowym. Pełna ścieżka jako
/// > nazwa domeny, bo zwykła nazwa ląduje w `~/Library/Preferences` i `cfprefsd`
/// > odtwarza ją po skasowaniu.
nonisolated enum MagazynUstawien {

    /// `nonisolated(unsafe)`: `UserDefaults` jest bezpieczne wątkowo (dokumentacja Apple),
    /// a SDK nie oznacza go jako `Sendable`. Wartość ustalana raz, potem tylko czytana.
    nonisolated(unsafe) static let domyslny: UserDefaults = {
        guard MagazynUkladu.podTestami else { return .standard }
        // Bez awaryjnego `.standard`: po cichu wróciłoby kasowanie danych [U].
        guard let testowa = UserDefaults(suiteName: domenaTestowa) else {
            fatalError("Nie udało się otworzyć testowej domeny UserDefaults: \(domenaTestowa)")
        }
        return testowa
    }()

    /// Jedna domena na przebieg — dwa przebiegi nie widzą swoich zapisów.
    static var domenaTestowa: String {
        NSTemporaryDirectory() + "mNasProxmox-testy-ustawienia-\(ProcessInfo.processInfo.processIdentifier)"
    }
}
