import SwiftUI
import AppKit

/// Język interfejsu wybierany w programie (zgłoszenie [U] 2026-10-04: *„w oknie programu
/// ma być zębatka i tam mają być ustawienia, a w nich zmiana języka”*).
///
/// Wybór zapisujemy jako `AppleLanguages` w **domenie programu** — tę samą wartość
/// ustawia macOS w Ustawieniach → Język i region → Aplikacje. Domena programu ma
/// pierwszeństwo przed globalną, więc system zostaje nietknięty. `Bundle` czyta język
/// raz, przy starcie, dlatego zmiana wymaga ponownego uruchomienia.
///
/// 🔴 Bieżący wybór czytamy z `persistentDomain`, nie `object(forKey:)`: ten drugi
/// schodzi do domeny globalnej i zwykły polski system wyglądałby jak „wybrany polski”.
nonisolated enum JezykProgramu: String, CaseIterable, Identifiable, Sendable {
    case systemowy, polski, angielski

    var id: String { rawValue }

    static let klucz = "AppleLanguages"

    /// Kod tabeli tłumaczeń; `nil` = według systemu.
    var kod: String? {
        switch self {
        case .systemowy: nil
        case .polski:    "pl"
        case .angielski: "en"
        }
    }

    static func odczytaj(_ ustawienia: UserDefaults, domena: String) -> JezykProgramu {
        guard let lista = ustawienia.persistentDomain(forName: domena)?[klucz] as? [String],
              let pierwszy = lista.first else { return .systemowy }
        return allCases.first { $0.kod == pierwszy } ?? .systemowy
    }

    func zapisz(_ ustawienia: UserDefaults) {
        if let kod { ustawienia.set([kod], forKey: Self.klucz) }
        else { ustawienia.removeObject(forKey: Self.klucz) }
    }

    /// Język, który program dostanie po ponownym uruchomieniu.
    func docelowy(dostepne: [String], systemowe: [String]) -> String? {
        kod ?? Bundle.preferredLocalizations(from: dostepne, forPreferences: systemowe).first
    }
}

/// Okno ustawień — otwierane zębatką w nagłówku, na ekranie łączenia i skrótem ⌘,.
struct OknoUstawien: View {
    static let id = "ustawienia"

    @State private var wybor = JezykProgramu.odczytaj(.standard, domena: Self.domena)

    private static var domena: String { Bundle.main.bundleIdentifier ?? "" }

    /// Język, w którym program teraz działa.
    private var biezacy: String? { Bundle.main.preferredLocalizations.first }

    private var trzebaRestartu: Bool {
        let systemowe = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[JezykProgramu.klucz] as? [String] ?? []
        return wybor.docelowy(dostepne: Bundle.main.localizations, systemowe: systemowe) != biezacy
    }

    var body: some View {
        Form {
            Section {
                Picker("Język interfejsu", selection: $wybor) {
                    Text("Według systemu").tag(JezykProgramu.systemowy)
                    Text(verbatim: "Polski").tag(JezykProgramu.polski)
                    Text(verbatim: "English").tag(JezykProgramu.angielski)
                }
                .onChange(of: wybor) { _, nowy in nowy.zapisz(.standard) }

                if trzebaRestartu {
                    HStack {
                        Text("Nowy język zadziała po ponownym uruchomieniu mNas.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Uruchom ponownie") { Self.uruchomPonownie() }
                    }
                }
            } header: {
                Label("Język", systemImage: "globe")
            }
            SekcjaAktualizacji()
            Section {
                HStack {
                    Text("Token, połączenie, SSH, historia i kafle krok po kroku.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    PrzyciskInstrukcji()
                }
            } header: {
                Label("Pomoc", systemImage: "questionmark.circle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Nowa kopia startuje dopiero, gdy ta naprawdę się skończy — inaczej dwie ikony
    /// w pasku menu naraz. Zamknięcie idzie zwykłą drogą (`applicationShouldTerminate`
    /// oddaje wentylatory automatowi).
    private static func uruchomPonownie() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let sciezka = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$0\"", sciezka]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Zębatka otwierająca okno ustawień.
struct PrzyciskUstawien: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: OknoUstawien.id)
        } label: {
            Label("Ustawienia", systemImage: "gearshape")
        }
        .help("Ustawienia programu")
    }
}

/// ⌘, i „mNas → Ustawienia…” w pasku menu u góry.
struct PolecenieUstawien: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ustawienia…") { openWindow(id: OknoUstawien.id) }
            .keyboardShortcut(",")
    }
}

/// Aktualizacje w Ustawieniach — zawsze opcjonalne (decyzja [U] 2026-10-01): przełącznik
/// comiesięcznego sprawdzania i ręczne „Sprawdź teraz”, które działa także przy wyłączonym.
struct SekcjaAktualizacji: View {
    @ObservedObject private var aktualizacje = Updates.shared
    @AppStorage(UpdateSetting.checkUpdates) private var sprawdzaj = true

    var body: some View {
        Section {
            Toggle("Sprawdzaj aktualizacje raz w miesiącu", isOn: $sprawdzaj)
                .onChange(of: sprawdzaj) { _, wlaczone in aktualizacje.enabled = wlaczone }
            HStack {
                Text(ostatnio).foregroundStyle(.secondary)
                Spacer()
                Button("Sprawdź teraz") { Task { await aktualizacje.check(manually: true) } }
            }
        } header: {
            Label("Aktualizacje", systemImage: "arrow.down.circle")
        } footer: {
            Text("Program pyta stronę fractal8.eu o numer najnowszej wersji — nic więcej nie wysyła. Nowa wersja instaluje się dopiero, gdy klikniesz „Zainstaluj”.")
                .foregroundStyle(.secondary)
        }
    }

    private var ostatnio: String {
        guard let data = aktualizacje.lastCheck else { return String(localized: "Jeszcze nie sprawdzano") }
        return String(localized: "Ostatnio: \(data.formatted(date: .abbreviated, time: .shortened))")
    }
}
