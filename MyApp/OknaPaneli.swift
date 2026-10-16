import SwiftUI

// Panele, które do 1.2.13 były arkuszami (`.sheet`) przyklejonymi do okna programu:
// CPU, RAM, Transfery i panel pojedynczego dysku. Zgłoszenie 2026-10-04: okna historii
// CPU i Transferów „wiszą na oknie programu i nie da się ich przesuwać”, a okna
// pozostałych historii (`OknoHistorii`) da się. Od 1.2.14 to zwykłe okna macOS —
// ten sam wzór co `OknoHistorii`: `WindowGroup(for:)`, ponowny klik wyciąga
// istniejące okno zamiast otwierać drugie.
//
// `PanelScaffold` zostaje bez zmian: jego przycisk zamykania woła `dismiss`, a ten
// w oknie `WindowGroup` zamyka okno tak samo, jak zamykał arkusz.

enum OknoPaneluTrwalego {
    static let id = "panel"

    enum Cel: Codable, Hashable {
        case cpu
        case ram
        case transfery
        case zdarzenia
        case uslugi
        /// Nazwa dysku z Proxmoksa (`/dev/…`) — sam `Disk` nie jest `Codable`,
        /// a okno musi dać się odtworzyć po samej wartości.
        case dysk(String)
    }
}

struct OknoPaneluTrwalegoWidok: View {
    @Environment(AppModel.self) private var model
    var cel: OknoPaneluTrwalego.Cel

    var body: some View {
        Group {
            switch cel {
            case .cpu:
                CPUPanel()
            case .ram:
                MemoryPanel()
            case .transfery:
                PanelTransferow()
            case .zdarzenia:
                OknoZdarzen()
            case .uslugi:
                OknoUslug()
            case .dysk(let nazwa):
                if let d = model.disks.first(where: { $0.name == nazwa }) {
                    DiskHealthView(disk: d)
                } else {
                    // Lista dysków jeszcze się nie wczytała albo dysk zniknął z serwera.
                    ContentUnavailableView("Brak dysku \(nazwa)", systemImage: "internaldrive",
                                           description: Text("Serwer nie zgłasza teraz tego dysku."))
                        .frame(minWidth: 420, minHeight: 300)
                }
            }
        }
        .navigationTitle(tytul)
        .zapamietajRozmiarOkna(nazwaRamki)
    }

    private var nazwaRamki: String {
        switch cel {
        case .dysk(let nazwa): return "panel.dysk.\(nazwa)"
        default:               return "panel.\(cel)"
        }
    }

    private var tytul: String {
        switch cel {
        case .cpu:             return String(localized: "Procesor")
        case .ram:             return String(localized: "Pamięć RAM")
        case .transfery:       return String(localized: "Transfery — historia")
        case .zdarzenia:       return String(localized: "Zdarzenia")
        case .uslugi:          return String(localized: "Usługi")
        case .dysk(let nazwa): return model.disks.first { $0.name == nazwa }?.model ?? nazwa
        }
    }
}
