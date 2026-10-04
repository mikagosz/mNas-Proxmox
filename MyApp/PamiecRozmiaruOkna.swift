import AppKit
import SwiftUI

/// Okno pamięta swój rozmiar i położenie między otwarciami i uruchomieniami (od 1.2.16).
///
/// Zgłoszenie [U] 2026-10-04: *„żeby program zapamiętywał, w jakiej wielkości użytkownik
/// ustawi sobie okno”*. SwiftUI przy `WindowGroup(for:)` otwiera nowe okno zawsze
/// w `defaultSize` — ramki nie zapisuje. Robi to AppKit, gdy okno ma `frameAutosaveName`:
/// najpierw `setFrameUsingName` (odczyt zapisanej ramki), potem `setFrameAutosaveName`
/// (od tej chwili każda zmiana zapisuje się sama w `UserDefaults`).
///
/// 🔴 Nazwa musi być jedna na okno: AppKit odmawia nadania nazwy, której używa już
/// inne otwarte okno. Dlatego panel dysku ma nazwę z nazwą dysku, nie wspólną.
private struct PamiecRozmiaruOkna: NSViewRepresentable {
    let nazwa: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { podepnij(v.window) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { podepnij(v.window) }
    }

    private func podepnij(_ okno: NSWindow?) {
        guard let okno, okno.frameAutosaveName != nazwa else { return }
        okno.setFrameUsingName(nazwa)
        okno.setFrameAutosaveName(nazwa)
    }
}

extension View {
    func zapamietajRozmiarOkna(_ nazwa: String) -> some View {
        background(PamiecRozmiaruOkna(nazwa: "mNas.okno.\(nazwa)"))
    }
}
