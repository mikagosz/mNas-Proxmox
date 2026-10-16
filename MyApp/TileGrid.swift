import SwiftUI

/// Gdzie i jak duży jest kafel — jedna wartość przekazywana do układu.
/// `Layout` nie widzi typu widoku, więc pozycję i rozmiar musi dostać jawnie.
nonisolated struct TilePlacement: Equatable {
    var col: Int
    var row: Int
    var cols: Int
    var rows: Int
}

nonisolated struct TilePlacementKey: LayoutValueKey {
    static let defaultValue = TilePlacement(col: 0, row: 0, cols: 1, rows: 1)
}

extension View {
    /// Twardy wymiar kafla w punktach.
    func tileFrame(_ size: TileSize) -> some View {
        frame(width: TileGeometry.width(size), height: TileGeometry.height(size))
    }

    /// Miejsce kafla na siatce.
    ///
    /// Wołane **na samym końcu** łańcucha modyfikatorów danego kafla: wartość układu
    /// czyta `TileGrid` z bezpośredniego dziecka, a modyfikatory dokładane później
    /// (przeciąganie, nakładki trybu edycji) mogłyby ją przykryć.
    func tilePlacement(_ pos: GridPos, _ size: TileSize) -> some View {
        layoutValue(key: TilePlacementKey.self,
                    value: TilePlacement(col: pos.col, row: pos.row, cols: size.cols, rows: size.rows))
    }
}

/// Siatka kafli o stałych rozmiarach: kratka 144 pt, odstęp 12 pt.
///
/// Każdy kafel dostaje **własną współrzędną kratki** i stoi dokładnie tam — także
/// wtedy, gdy obok zostaje puste miejsce. Wcześniej siatka pakowała kafle po kolei
/// i sama domykała dziury, przez co nie dało się zostawić wolnego pola tam, gdzie
/// user chciał (zgłoszenie 2026-08-17). Wyliczanie pozycji siedzi
/// w `DashboardLayout` — tutaj zostaje samo rozstawianie.
nonisolated struct TileGrid: Layout {
    var cell: CGFloat = TileGeometry.cell
    var gap: CGFloat = TileGeometry.gap
    /// Dodatkowe puste wiersze pod spodem — miejsce, w które da się upuścić kafel
    /// w trybie edycji. Bez tego nie było gdzie zbudować nowego, niższego rzędu.
    var extraRows: Int = 0

    private func columnCount(for width: CGFloat?) -> Int {
        guard let width, width.isFinite, width > 0 else { return 1 }
        return max(1, Int((width + gap) / (cell + gap)))
    }

    private func length(_ units: Int) -> CGFloat {
        units <= 0 ? 0 : CGFloat(units) * cell + CGFloat(units - 1) * gap
    }

    private func usedRows(_ subviews: Subviews) -> Int {
        subviews.reduce(0) { acc, view in
            let p = view[TilePlacementKey.self]
            return max(acc, p.row + p.rows)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let columns = columnCount(for: proposal.width)
        return CGSize(width: length(columns),
                      height: length(usedRows(subviews) + extraRows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let p = view[TilePlacementKey.self]
            view.place(
                at: CGPoint(x: bounds.minX + CGFloat(p.col) * (cell + gap),
                            y: bounds.minY + CGFloat(p.row) * (cell + gap)),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: length(p.cols), height: length(p.rows))
            )
        }
    }
}

/// Przeciąganie po całej siatce: kafel ląduje w tej kratce, nad którą jest kursor.
///
/// Delegat wisi na **całej** siatce, nie na pojedynczych kaflach — inaczej puste pole
/// nie przyjmowałoby upuszczenia, a to właśnie w puste pola user chce kłaść.
/// `dropUpdated` przestawia kafel na żywo, więc widać wynik przed puszczeniem.
struct GridDropDelegate: DropDelegate {
    let layout: DashboardLayout
    let tiles: [DashTileID]
    @Binding var dragging: DashTileID?

    private var step: CGFloat { TileGeometry.cell + TileGeometry.gap }

    private func cell(at point: CGPoint) -> GridPos {
        GridPos(col: max(0, Int(point.x / step)), row: max(0, Int(point.y / step)))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let dragging {
            let target = cell(at: info.location)
            withAnimation(.snappy(duration: 0.18)) {
                layout.place(dragging, at: target, among: tiles)
            }
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragging {
            layout.place(dragging, at: cell(at: info.location), among: tiles)
        }
        dragging = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}
