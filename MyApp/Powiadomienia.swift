import Foundation
import UserNotifications

/// Powiadomienia systemowe o przebiegach, które poszły źle.
///
/// > [!important] Czym to **nie** jest
/// > To nie jest zamiennik ntfy. Kopie chodzą o 02:15–04:30, kiedy Mac śpi i mNas nie
/// > działa — wtedy żadne powiadomienie z tej apki nie ma jak się pokazać. Nocny kanał
/// > alarmowy to Uptime Kuma → ntfy na telefon (monitor push gaśnie sam po 25 h ciszy)
/// > i tak ma zostać. Tutejsze powiadomienia dotyczą przebiegów, które **zaczynają się
/// > przy działającej apce**, oraz zaległości zauważonych po jej uruchomieniu.
///
/// Zgody nie prosimy przy starcie programu, tylko przy **pierwszym powiadomieniu, które
/// naprawdę ma polecieć**. Okno zgody na starcie jest dla użytkownika pytaniem bez
/// kontekstu — nie wiadomo jeszcze, o czym miałaby być mowa.
nonisolated enum Powiadomienia {

    /// Stan zgody. `nil` = jeszcze nie pytaliśmy.
    private nonisolated(unsafe) static var zgoda: Bool?
    /// Kolejka anty-powtórkowa: ten sam przebieg nie zgłasza się dwa razy w krótkim czasie
    /// nawet wtedy, gdy jego stan mignie tam i z powrotem.
    private nonisolated(unsafe) static var ostatnie: [String: Date] = [:]
    private static let odstepPowtorki: TimeInterval = 15 * 60

    static func pokaz(tytul: String, tresc: String, identyfikator: String) {
        let teraz = Date()
        if let poprzednie = ostatnie[identyfikator],
           teraz.timeIntervalSince(poprzednie) < odstepPowtorki { return }
        ostatnie[identyfikator] = teraz

        Task {
            guard await maZgode() else { return }
            let tresc0 = UNMutableNotificationContent()
            tresc0.title = tytul
            tresc0.body = tresc
            tresc0.sound = .default
            // `nil` jako wyzwalacz = pokaż od razu. Identyfikator jest identyfikatorem
            // przebiegu, więc ponowne zgłoszenie tego samego podmienia poprzednie
            // powiadomienie zamiast układać stos kopii tej samej wiadomości.
            let zadanie = UNNotificationRequest(identifier: identyfikator,
                                                content: tresc0,
                                                trigger: nil)
            try? await UNUserNotificationCenter.current().add(zadanie)
        }
    }

    private static func maZgode() async -> Bool {
        if let zgoda { return zgoda }
        let centrum = UNUserNotificationCenter.current()
        let wynik = (try? await centrum.requestAuthorization(options: [.alert, .sound])) ?? false
        zgoda = wynik
        return wynik
    }
}
