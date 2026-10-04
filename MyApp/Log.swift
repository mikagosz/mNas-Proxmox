import os

/// Logi aplikacji przez `os.Logger` zamiast `print`. Zysk wobec `print`: poziomy
/// (debug znika w wersji wydawanej), kategorie i filtrowanie w Konsoli albo przez
/// `log show --predicate 'subsystem == "com.mikagosz.mNasProxmox"' --last 10m`.
///
/// Zasada, której trzymamy się w całym projekcie: **do logu nie trafia nic, co niesie
/// poświadczenie**. Klucz API nie jest logowany nigdzie; z odpowiedzi `auth.login_ex`
/// bierzemy wyłącznie `response_type`, bo cała odpowiedź może nieść dane sesji.
///
/// Interpolacje oznaczamy `privacy: .public` tam, gdzie wartość ma być czytelna w logu —
/// domyślnie `Logger` maskuje dynamiczne stringi jako `<private>`, a to narzędzie
/// jednego użytkownika do własnego serwera, więc adresy i nazwy metod chcemy widzieć.
nonisolated enum Log {
    /// Zgodny z bundle ID tej apki. **Nie `com.mikagosz.mNas`** — tamta wartość została
    /// z linii TrueNAS i sprawiała, że `log show` zwracał wpisy z obu programów naraz,
    /// więc przy diagnozie awarii nie było widać, która apka co powiedziała.
    private static let subsystem = "com.mikagosz.mNasProxmox"

    static let connection  = Logger(subsystem: subsystem, category: "connection")
    static let auth        = Logger(subsystem: subsystem, category: "auth")
    static let rpc         = Logger(subsystem: subsystem, category: "rpc")
    static let ssh         = Logger(subsystem: subsystem, category: "ssh")
    static let keychain    = Logger(subsystem: subsystem, category: "keychain")
    static let certificate = Logger(subsystem: subsystem, category: "certificate")
    static let gpu         = Logger(subsystem: subsystem, category: "gpu")
    /// Zapis i odczyt układu kafli z pliku `uklad-kafli.json`.
    static let uklad       = Logger(subsystem: subsystem, category: "uklad")
    /// Kliknięcia w ikonę paska menu. Dołożone 2026-08-23 po **drugiej** nieudanej
    /// naprawie przełączania: obie poszły z rozumowania, bez pomiaru, bo agent nie może
    /// kliknąć w interfejs. Ten kanał zamienia następną diagnozę w odczyt:
    /// `log show --predicate 'subsystem == "com.mikagosz.mNasProxmox"' --last 5m`
    static let pasekMenu   = Logger(subsystem: subsystem, category: "pasek-menu")
}
