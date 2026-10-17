import Testing
import Foundation
import AppKit
@testable import mNas

/// Zrzut wszystkich stanów ikony paska do jednego pliku PNG.
///
/// Po co test, który niczego nie sprawdza: ikona paska menu **nie da się obejrzeć
/// inaczej**. Zrzut ekranu wymaga zgody na nagrywanie ekranu, a bez obejrzenia
/// wychodzą rzeczy takie jak biały kwadrat zamiast ptaszka (2026-08-20) — kod
/// budował się, testy logiki przechodziły, a ikona była nie do odczytania.
///
/// Plik ląduje w katalogu tymczasowym, nie w projekcie. Ścieżka jest wypisywana
/// w wyniku testu — `xcodebuild test 2>&1 | grep PODGLĄD`.
@Suite("Podgląd ikony paska menu")
@MainActor
struct PodgladIkonyTests {

    @Test("Zrzut wszystkich stanów ikony do PNG")
    func zrzutStanow() throws {
        let stany: [(String, StanPaska)] = [
            ("polaczony", StanPaska(przebiegi: [], polaczony: true)),
            ("niepolaczony", StanPaska(przebiegi: [], polaczony: false)),
            ("trwa", StanPaska(przebiegi: [
                Przebieg(id: "a", nazwa: "Kopia zapasowa", zrodlo: .serwer, stan: .trwa)
            ], polaczony: true)),
            ("blad", StanPaska(przebiegi: [
                Przebieg(id: "b", nazwa: "Kopia programów", zrodlo: .kuma, stan: .bledny)
            ], polaczony: true)),
            ("polaczony-3", StanPaska(przebiegi: [], polaczony: true, nieodczytane: 3)),
            ("trwa-12", StanPaska(przebiegi: [
                Przebieg(id: "a", nazwa: "Kopia zapasowa", zrodlo: .serwer, stan: .trwa)
            ], polaczony: true, nieodczytane: 12)),
            ("aktualizacje", StanPaska(przebiegi: [], polaczony: true, doZainstalowania: 2)),
            ("aktualizacje-3", StanPaska(przebiegi: [], polaczony: true, nieodczytane: 3, doZainstalowania: 1))
        ]

        // Skala 4×, bo ikona ma 18 pt wysokości — w oryginale nie da się ocenić,
        // czy w kółku jest ptaszek, czy plama.
        let skala: CGFloat = 4
        let odstep: CGFloat = 10
        let ikony = stany.map { ($0.0, RysunekIkony.zbuduj($0.1)) }
        let szerokosc = ikony.reduce(0) { $0 + $1.1.size.width + odstep } + odstep
        let wysokosc: CGFloat = 18 + 2 * odstep

        let plansza = NSImage(size: NSSize(width: szerokosc * skala, height: wysokosc * skala))
        plansza.lockFocus()
        // Tło paska menu w trybie ciemnym — tam ikona jest najtrudniejsza do odczytania.
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: szerokosc * skala, height: wysokosc * skala).fill()

        var x = odstep * skala
        for (_, ikona) in ikony {
            ikona.draw(in: NSRect(x: x, y: odstep * skala,
                                  width: ikona.size.width * skala,
                                  height: ikona.size.height * skala))
            x += (ikona.size.width + odstep) * skala
        }
        plansza.unlockFocus()

        let dane = try #require(plansza.tiffRepresentation)
        let mapa = try #require(NSBitmapImageRep(data: dane))
        let png = try #require(mapa.representation(using: .png, properties: [:]))
        let sciezka = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mNas-ikony-paska.png")
        try png.write(to: sciezka)

        print("PODGLĄD IKONY: \(sciezka.path)")
        print("PODGLĄD KOLEJNOŚĆ: \(stany.map(\.0).joined(separator: ", "))")
        #expect(FileManager.default.fileExists(atPath: sciezka.path))
    }

    @Test("Znak aktualizacji: pojawia się tylko przy czymś do zainstalowania i poszerza ikonę")
    func znakAktualizacji() {
        let bez = StanPaska(przebiegi: [], polaczony: true)
        let z = StanPaska(przebiegi: [], polaczony: true, doZainstalowania: 2)
        #expect(!bez.opis.contains("aktualizacje"))
        #expect(z.opis.contains("aktualizacje na serwerze: 2"))
        #expect(RysunekIkony.zbuduj(z).size.width > RysunekIkony.zbuduj(bez).size.width)
    }
}
