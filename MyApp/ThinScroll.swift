import SwiftUI

/// Przewijana lista z **własnym**, cienkim paskiem przewijania.
///
/// Po co własny, skoro system ma swój: AppKit daje do wyboru dwa style i żaden nie
/// pasuje. Styl klasyczny („Pokaż paski przewijania: Zawsze") jest szeroki i wrasta
/// w układ, zabierając szerokość treści. Styl nakładkowy jest wąski, ale **znika**,
/// gdy nikt nie przewija. Szerokości ani jednego, ani drugiego nie da się ustawić —
/// `NSScroller` liczy ją sam z metryki systemowej.
///
/// Ten pasek jest widoczny cały czas i ma dokładnie tyle punktów szerokości, ile
/// każe `szerokosc`. Decyzja użytkownika 2026-08-19: „cienki, ale ma być widać".
struct ThinScrollView<Content: View>: View {
    var szerokosc: CGFloat = 3
    /// Najkrótszy dopuszczalny suwak. Bez tego przy bardzo długiej liście robi się
    /// z niego kilkupikselowa kreska, w którą nie da się trafić wzrokiem.
    var minimalnySuwak: CGFloat = 24
    /// Odstęp między treścią a paskiem. Pasek jest nakładką, więc bez tego marginesu
    /// leży **na tekście** — długie nazwy usług wchodziły pod suwak.
    var odstep: CGFloat = 5
    @ViewBuilder var content: () -> Content

    @State private var przesuniecie: CGFloat = 0
    @State private var wysokoscTresci: CGFloat = 0
    @State private var wysokoscOkna: CGFloat = 0

    private struct Pomiar: Equatable {
        var przesuniecie: CGFloat
        var tresc: CGFloat
        var okno: CGFloat
    }

    var body: some View {
        ScrollView {
            // Miejsce na pasek rezerwujemy **zawsze**, nie tylko gdy jest widoczny:
            // doklejanie marginesu w chwili, gdy lista robi się przewijalna,
            // przesuwałoby cały tekst w bok przy każdym dojściu treści.
            content().padding(.trailing, szerokosc + odstep)
        }
            // Systemowy pasek wyłączony — rysujemy własny, żeby mieć szerokość.
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Pomiar.self) { geo in
                Pomiar(przesuniecie: geo.contentOffset.y,
                       tresc: geo.contentSize.height,
                       okno: geo.containerSize.height)
            } action: { _, nowy in
                przesuniecie = nowy.przesuniecie
                wysokoscTresci = nowy.tresc
                wysokoscOkna = nowy.okno
            }
            .overlay(alignment: .trailing) { pasek }
    }

    /// Pasek pojawia się dopiero, gdy jest co przewijać — przy krótkiej liście
    /// suwak na całą wysokość byłby ozdobą bez znaczenia.
    @ViewBuilder private var pasek: some View {
        if wysokoscTresci > wysokoscOkna + 1, wysokoscOkna > 0 {
            let zakresPrzewijania = wysokoscTresci - wysokoscOkna
            let wysokoscSuwaka = max(minimalnySuwak, wysokoscOkna * (wysokoscOkna / wysokoscTresci))
            let udzial = min(max(przesuniecie / zakresPrzewijania, 0), 1)
            let gora = (wysokoscOkna - wysokoscSuwaka) * udzial

            ZStack(alignment: .top) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.secondary)
                    .frame(height: wysokoscSuwaka)
                    .offset(y: gora)
            }
            .frame(width: szerokosc, height: wysokoscOkna)
            .padding(.trailing, 1)
            // Pasek jest wskaźnikiem, nie chwytakiem: kliknięcie ma trafiać w treść
            // pod spodem, a nie w kreskę o szerokości trzech punktów.
            .allowsHitTesting(false)
        }
    }
}
