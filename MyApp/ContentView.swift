import SwiftUI

/// Korzeń aplikacji — pokazuje ekran łączenia albo dashboard,
/// zależnie od stanu połączenia z serwerem.
///
/// Dashboard zostaje na ekranie także w stanie `.reconnecting`: dane są (choćby zamrożone),
/// a apka sama wraca do serwera. Przerzucanie użytkownika na ekran łączenia przy każdym
/// blipie sieci kasowałoby otwarte panele i tryb edycji układu.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.status.showsDashboard {
                DashboardView()
            } else {
                ConnectionView()
            }
        }
        .animation(.default, value: model.status)
        // Paski przewijania chowamy w **jednym miejscu**: `scrollIndicators` jedzie
        // przez środowisko, więc obejmuje każdy `ScrollView` niżej — kafle, listy
        // i wyjścia terminala. Decyzja użytkownika 2026-08-19. Przewijanie gestem
        // i kółkiem działa jak działało; znika sam pasek.
        //
        // 🔴 Musi być `.never`, nie `.hidden`. `.hidden` jest **sugestią**, którą system
        // nadpisuje, gdy w Ustawieniach stoi „Pokaż paski przewijania: Zawsze" — a tak
        // jest ustawione u [U]. W tym trybie macOS rysuje klasyczne paski, które
        // zabierają szerokość układu (stąd „kabanosy"). `.never` znaczy nigdy.
        .scrollIndicators(.never)
    }
}
