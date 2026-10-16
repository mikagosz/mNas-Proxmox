import SwiftUI

/// Ostrzeżenia o dyskach — z treścią, nie samym trójkątem.
///
/// > [!danger] Po co to powstało
/// > Zgłoszenie z 2026-08-23, zapisane wersalikami: *„miałem ostrzeżenie w Dyskach
/// > ale wiedziałem tylko że jest, zero informacji o tym który dysk i co się stało —
/// > ZERO INFORMACJI O TYM CO SIE DZIEJE"*.
/// >
/// > Przedtem kafel liczył wyłącznie `temps.allSatisfy { $0 < 55 }` i zapalał pomarańczowy
/// > trójkąt. Ani nazwy nośnika, ani wartości, ani progu, ani godziny pomiaru. Ostrzeżenie
/// > bez tych pięciu rzeczy nie jest informacją, tylko niepokojem.
///
/// Zbieranie jest **czystą funkcją** (`zbierz`) — bez sieci, bez `AppModel`, bez zegara
/// systemowego. Dzięki temu każdy próg da się przypiąć testem bez serwera.

// MARK: - Pojedyncze ostrzeżenie

nonisolated struct OstrzezenieDysku: Identifiable, Sendable, Hashable {

    enum Poziom: Sendable, Hashable {
        /// Warto wiedzieć, nic się nie sypie.
        case uwaga
        /// Dysk zgłasza uszkodzenie albo wyczerpanie — to jest powód do działania.
        case powazne
    }

    /// Nazwa urządzenia, tak jak w komendach: `nvme2n1`, `sda`.
    var nosnik: String
    /// Model dysku, gdy serwer go podaje — inaczej znów nazwa urządzenia.
    var opisNosnika: String
    /// **Co** zmierzono: „Temperatura", „Kondycja SMART", „Zużycie komórek".
    var wskaznik: String
    /// Zmierzona wartość, gotowa do pokazania, z jednostką.
    var wartosc: String
    /// Próg, po przekroczeniu którego to ostrzeżenie się zapala.
    var prog: String
    var poziom: Poziom
    /// Godzina pomiaru — nie czas otwarcia okna. To dwie różne rzeczy i mylenie ich
    /// sprawia, że zamrożony dashboard wygląda na świeży.
    var czas: Date
    /// Po ludzku: co ta liczba znaczy.
    var coZnaczy: String
    /// Po ludzku: co z tym zrobić. Puste, gdy uczciwa odpowiedź brzmi „nic".
    var coZrobic: String

    /// Tożsamość z danych, nie z `UUID()` — lista jest przeliczana co turę odświeżania
    /// i losowy identyfikator kazałby `ForEach` przebudowywać ją bez przerwy.
    var id: String { "\(nosnik)|\(wskaznik)" }

    /// Jedna linijka do kafla: nośnik, wskaźnik, wartość, próg.
    var jednymZdaniem: String {
        String(localized: "\(opisNosnika) · \(wskaznik.lowercased()) \(wartosc) · próg \(prog)")
    }
}

// MARK: - Zbieranie

nonisolated enum OstrzezeniaDyskow {

    /// Powyżej tej temperatury zapala się ostrzeżenie.
    ///
    /// 55 °C to ta sama wartość, którą kafel „Dyski" i `DiskHealthView` malują na czerwono
    /// od 2026-08-16. Stoi tutaj, żeby trzy miejsca nie rozjechały się po cichu.
    static let progTemperatury: Double = 55

    /// Zużycie komórek, powyżej którego krzyczymy — **ten sam próg co czujka na serwerze**
    /// (`PROG_ZUZYCIE=80` w `/usr/local/bin/alarm-dyskow.sh`). Dwa różne progi znaczyłyby,
    /// że ntfy dzwoni, a apka milczy — albo odwrotnie.
    static let progZuzycia = 80

    /// Składa listę ostrzeżeń z tego, co program i tak ma pod ręką.
    ///
    /// Kolejność jest celowa: najpierw poważne, potem uwagi, a wewnątrz każdej grupy
    /// alfabetycznie po nośniku. Lista przeliczana co pięć sekund musi wychodzić w tej
    /// samej kolejności, inaczej wiersze skaczą pod kursorem.
    static func zbierz(disks: [Disk],
                       temperatures: [String: Double],
                       czas: Date) -> [OstrzezenieDysku] {
        var out: [OstrzezenieDysku] = []

        for disk in disks {
            let opis = disk.model ?? disk.name

            // 1. Werdykt SMART. Dysk potrafi być zimny i mieć `FAILED` — to nie wynika
            //    z temperatury i przed 2026-08-23 apka w ogóle tego nie pokazywała,
            //    mimo że pole przychodziło z API od pierwszego dnia.
            if let health = disk.health, !health.isEmpty,
               health.uppercased() != "PASSED", health.uppercased() != "UNKNOWN" {
                out.append(OstrzezenieDysku(
                    nosnik: disk.name,
                    opisNosnika: opis,
                    wskaznik: String(localized: "Kondycja SMART"),
                    wartosc: health.uppercased(),
                    prog: "PASSED",
                    poziom: .powazne,
                    czas: czas,
                    coZnaczy: String(localized: "Sam dysk zgłasza, że jest z nim źle. To nie jest ocena programu ani serwera — to werdykt elektroniki dysku o samej sobie."),
                    coZrobic: String(localized: "Zrób kopię danych z tego nośnika, zanim zrobisz cokolwiek innego. Kliknij dysk na liście, żeby zobaczyć pełną tablicę SMART.")
                ))
            }

            // 2. Zużycie komórek. `wearout` z API to **pozostała** żywotność, więc
            //    zużycie liczy `Disk.zuzycieProcent`. Talerze podają `N/A` i wypadają tu same.
            if let zuzycie = disk.zuzycieProcent, zuzycie >= progZuzycia {
                out.append(OstrzezenieDysku(
                    nosnik: disk.name,
                    opisNosnika: opis,
                    wskaznik: String(localized: "Zużycie komórek"),
                    wartosc: "\(zuzycie)%",
                    prog: "\(progZuzycia)%",
                    poziom: .powazne,
                    czas: czas,
                    coZnaczy: String(localized: "Pamięć SSD ma policzoną liczbę zapisów. \(zuzycie)% tego zapasu jest już wykorzystane — dysk nadal działa, ale zbliża się do końca przewidzianego życia."),
                    coZrobic: String(localized: "Zaplanuj wymianę nośnika. Nic nie musi się stać dzisiaj, ale ten dysk nie powinien być jedynym miejscem, gdzie coś leży.")
                ))
            }

            // 3. Temperatura. Idzie ze `smartctl` przez SSH, nie z API — Proxmox
            //    stopni nie podaje w ogóle.
            if let temp = temperatures[disk.name], temp >= progTemperatury {
                out.append(OstrzezenieDysku(
                    nosnik: disk.name,
                    opisNosnika: opis,
                    wskaznik: String(localized: "Temperatura"),
                    wartosc: "\(Int(temp.rounded())) °C",
                    prog: "\(Int(progTemperatury)) °C",
                    poziom: .uwaga,
                    czas: czas,
                    coZnaczy: String(localized: "Dysk grzeje się powyżej progu, od którego kafel maluje wartość na czerwono. Gorący NVMe sam zwalnia, żeby ostygnąć — objawia się to spadkiem prędkości, nie błędem."),
                    coZrobic: String(localized: "Jeśli to się utrzymuje, sprawdź przepływ powietrza wokół serwera — jednorazowy skok w czasie nocnej kopii jest normalny.")
                ))
            }
        }

        return out.sorted { lewe, prawe in
            if lewe.poziom != prawe.poziom { return lewe.poziom == .powazne }
            if lewe.nosnik != prawe.nosnik { return lewe.nosnik < prawe.nosnik }
            return lewe.wskaznik < prawe.wskaznik
        }
    }
}

// MARK: - Okno z treścią

/// Okno otwierane kliknięciem w ostrzeżenie na kaflu „Dyski".
///
/// Układ wybrany przez użytkownika 2026-08-23: *„skoro ostrzeżenie jest na dyskach to logiczne
/// że kliknięcie w okno Dyski w ostrzeżenia powinno odpalić okienko i pokazać dokładnie
/// i zrozumiale o co cały hałas"*. Stąd pełne zdania zamiast skrótów i osobne pola
/// „co to znaczy" / „co zrobić" — nie sama tabelka z liczbami.
struct PanelOstrzezenDyskow: View {
    @Environment(AppModel.self) private var model

    private var ostrzezenia: [OstrzezenieDysku] {
        OstrzezeniaDyskow.zbierz(disks: model.disks,
                                 temperatures: model.temperatures,
                                 czas: model.lastSuccessfulRefresh ?? Date())
    }

    var body: some View {
        PanelScaffold(title: "Ostrzeżenia o dyskach", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
            if ostrzezenia.isEmpty {
                // Pusto po otwarciu znaczy, że ostrzeżenie zgasło między kliknięciem
                // a odczytem — mówimy to wprost, zamiast pokazywać pustą stronę.
                Label("Żaden dysk nie przekracza teraz progu.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                Text("Ostrzeżenie mogło zgasnąć między kliknięciem a tym odczytem — temperatura schodzi poniżej progu sama.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(ostrzezenia) { wiersz(($0)) }
            }

            PanelSection(title: "Progi, przy których to się zapala") {
                progRow("Temperatura", "\(Int(OstrzezeniaDyskow.progTemperatury)) °C",
                        "ze `smartctl` przez SSH — Proxmox nie podaje stopni przez API")
                progRow("Zużycie komórek", "\(OstrzezeniaDyskow.progZuzycia)%",
                        "próg ostrzeżenia o zużyciu")
                progRow("Kondycja SMART", String(localized: "cokolwiek poza PASSED"),
                        "werdykt samego dysku z `/nodes/{węzeł}/disks/list`")
            }
        }
    }

    @ViewBuilder private func wiersz(_ o: OstrzezenieDysku) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: o.poziom == .powazne ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(o.poziom == .powazne ? .red : .orange)
                Text(o.opisNosnika).font(.headline)
                Text(o.nosnik).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(Self.godzina.string(from: o.czas))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }

            HStack(spacing: 24) {
                pole("Wskaźnik", o.wskaznik, .primary)
                pole("Zmierzono", o.wartosc, o.poziom == .powazne ? .red : .orange)
                pole("Próg", o.prog, .secondary)
            }

            Text(o.coZnaczy)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if !o.coZrobic.isEmpty {
                Label(o.coZrobic, systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    private func pole(_ etykieta: LocalizedStringKey, _ wartosc: String, _ kolor: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(etykieta).font(.caption2).foregroundStyle(.secondary)
            Text(wartosc).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(kolor)
        }
    }

    private func progRow(_ nazwa: LocalizedStringKey, _ prog: String, _ skad: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(nazwa).font(.caption.weight(.medium)).frame(width: 130, alignment: .leading)
            Text(prog).font(.caption.monospacedDigit().weight(.semibold))
            Text(skad).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let godzina: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
