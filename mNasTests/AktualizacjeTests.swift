import Testing
import Foundation
@testable import mNas

/// Część aktualizacji, która nie potrzebuje serwera: skąd wolno pobrać paczkę, wersja z dysku
/// i pomocnik restartu, który czeka na koniec starej kopii (`UpdateSupport.swift`).
@Suite("Aktualizacje: adres paczki, wersja z dysku, restart po końcu procesu")
struct AktualizacjeTests {

    @Test("Paczkę wolno pobrać tylko po https z downloads.fractal8.eu")
    func dozwoloneAdresy() {
        #expect(DownloadAddress.allowed(URL(string: "https://downloads.fractal8.eu/mNas/mNas%201.2.27.zip")!))
        #expect(!DownloadAddress.allowed(URL(string: "https://example.com/mNas.zip")!))
        #expect(!DownloadAddress.allowed(URL(string: "file:///Applications/mNas.app")!))
        #expect(!DownloadAddress.allowed(URL(string: "https://kto:haslo@downloads.fractal8.eu/mNas.zip")!))
        #expect(!DownloadAddress.allowed(URL(string: "smb://downloads.fractal8.eu/mNas.zip")!))
    }

    @Test("Wersja czytana z Info.plist na dysku, nie z uruchomionej paczki")
    func wersjaZDysku() throws {
        let app = FileManager.default.temporaryDirectory
            .appending(path: "mNasTest-\(UUID().uuidString).app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "9.9.9"], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        #expect(RestartAfterUpdate.versionOnDisk(app) == "9.9.9")
        #expect(RestartAfterUpdate.versionOnDisk(app.deletingLastPathComponent()) == nil)
    }

    @Test("Pomocnik otwiera nową wersję dopiero po końcu starego procesu")
    func pomocnikCzekaNaKoniec() async throws {
        let stary = Process()
        stary.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stary.arguments = ["1"]
        try stary.run()
        let znacznik = FileManager.default.temporaryDirectory
            .appending(path: "mNasRestart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: znacznik) }
        // `touch` zamiast `open`: plik znacznika powstaje w chwili „otwarcia” nowej wersji.
        try RestartAfterUpdate.launchAfterExit(pid: stary.processIdentifier, app: znacznik,
                                               opener: "/usr/bin/touch")
        try await Task.sleep(for: .milliseconds(400))
        #expect(stary.isRunning)
        #expect(!FileManager.default.fileExists(atPath: znacznik.path))
        stary.waitUntilExit()
        try await Task.sleep(for: .milliseconds(900))
        #expect(FileManager.default.fileExists(atPath: znacznik.path))
    }
}
