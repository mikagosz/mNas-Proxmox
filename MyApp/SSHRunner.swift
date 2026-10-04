import Foundation
import os

/// Odpala komendy na serwerze przez systemowe `/usr/bin/ssh`.
/// Działa, bo aplikacja ma App Sandbox = NO. Uwierzytelnianie kluczem ed25519
/// trzymanym w Application Support — bez haseł w kodzie, bez zależności zewnętrznych.
///
/// Cały typ jest `nonisolated`: dotyka wyłącznie plików i procesów, nigdy stanu UI.
/// Bez tego `ensureKey()` było niejawnie na głównym aktorze (`SWIFT_DEFAULT_ACTOR_ISOLATION`)
/// i wołanie go z `Task.detached` dawało ostrzeżenie blokujące tryb Swift 6.
nonisolated struct SSHRunner: Sendable {
    var host: String
    var user: String

    struct Result: Sendable {
        var output: String
        var error: String
        var code: Int32
        /// Komenda przekroczyła twardy limit czasu i została przerwana.
        var timedOut: Bool = false

        var ok: Bool { code == 0 && !timedOut }
    }

    // MARK: - Ścieżki

    private static var appDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Osobny katalog od wersji pod TrueNAS-a — własny klucz i własne known_hosts,
        // tak samo jak przy Keychain. Dwa programy, dwa serwery, dwa komplety poświadczeń.
        let dir = base.appendingPathComponent("mNas-Proxmox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var keyPath: URL { appDir.appendingPathComponent("id_ed25519") }
    private static var pubPath: URL { appDir.appendingPathComponent("id_ed25519.pub") }
    private static var knownHosts: URL { appDir.appendingPathComponent("known_hosts") }

    /// Katalog gniazd multipleksowania — **celowo poza Application Support**.
    ///
    /// Ścieżka gniazda uniksowego ma twardy limit 104 bajtów. Sam `%C` (40 znaków) to za
    /// mało, żeby się zmieścić, bo ssh dokleja jeszcze 17-znakowy sufiks tymczasowy przy
    /// zakładaniu gniazda. Zmierzone na tym Macu:
    ///
    ///     /Users/<konto>/Library/Application Support/mNas-Proxmox/  55 (konto 6-znakowe)
    ///     cm-                                                        3
    ///     %C (SHA1 hex)                                             40
    ///     .6WbjYTgiBuy8ZShl (sufiks ssh)                            17
    ///                                                              ───
    ///                                                              115  > 104  ⛔
    ///
    /// Dawało to `unix_listener: path … too long for Unix domain socket` i martwy kanał SSH.
    /// Krótki katalog w katalogu domowym schodzi do 85 bajtów, czyli z zapasem. Gniazdo
    /// jest ulotne (`ControlPersist=60`), więc nie są to dane użytkownika — sam katalog
    /// dostaje `0700`, bo leży poza kontenerem aplikacji.
    private static var controlDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mnas-proxmox", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    private static var controlPath: String { controlDir.appendingPathComponent("cm-%C").path }

    /// Tworzy parę kluczy, jeśli nie istnieje. Zwraca zawartość klucza publicznego.
    @discardableResult
    static func ensureKey() -> String? {
        if !FileManager.default.fileExists(atPath: keyPath.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = ["-t", "ed25519", "-f", keyPath.path, "-N", "", "-C", "mNas", "-q"]
            try? p.run()
            p.waitUntilExit()
        }
        return publicKey
    }

    static var publicKey: String? {
        (try? String(contentsOf: pubPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Uruchamianie komend

    /// Odpala komendę zdalnie i zwraca stdout/stderr/kod wyjścia.
    ///
    /// - Parameters:
    ///   - timeout: **twardy limit całej komendy** w sekundach. Po jego upływie proces
    ///     dostaje SIGTERM, a po kolejnych 3 s SIGKILL. Wcześniej ten parametr trafiał
    ///     wyłącznie do `ConnectTimeout`, więc ograniczał tylko nawiązanie połączenia —
    ///     komenda, która już ruszyła i się zawiesiła, trzymała wątek w nieskończoność.
    ///   - connectTimeout: limit samego nawiązania połączenia (domyślnie `timeout`, nie
    ///     więcej niż 10 s).
    ///   - forceTTY: `ssh host "cmd"` bez terminala nie ma pty — na wielu systemach (m.in.
    ///     TrueNAS/Debian z `requiretty`) `sudo -n` wtedy ZAWSZE odpowiada „a password is
    ///     required", nawet gdy w sudoers jest NOPASSWD. `-tt` wymusza pty i to naprawia.
    ///     Używać tylko dla komend z sudo — przy zwykłym odczycie niepotrzebne pty potrafi
    ///     dorzucić do wyjścia baner MOTD.
    func run(_ command: String,
             timeout: Int = 10,
             connectTimeout: Int? = nil,
             forceTTY: Bool = false) async -> Result {
        let total = max(timeout, 2)
        let connect = min(max(connectTimeout ?? timeout, 3), 10)
        let host = self.host, user = self.user
        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.execute(command: command,
                                                    host: host,
                                                    user: user,
                                                    totalTimeout: total,
                                                    connectTimeout: connect,
                                                    forceTTY: forceTTY))
            }
        }
    }

    private static func execute(command: String,
                                host: String,
                                user: String,
                                totalTimeout: Int,
                                connectTimeout: Int,
                                forceTTY: Bool) -> Result {
        ensureKey()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-i", keyPath.path,
            "-o", "BatchMode=yes",                       // nigdy nie pyta o hasło
            "-o", "StrictHostKeyChecking=accept-new",    // TOFU: pierwszy klucz hosta zapamiętany, zmiana = błąd
            // Cudzysłowy są OBOWIĄZKOWE: `-o` trafia do ssh jako linia pliku konfiguracyjnego,
            // a nasza ścieżka zawiera spację („Application Support"). Bez nich ssh czyta to
            // jako LISTĘ dwóch plików — `/Users/…/Library/Application` oraz `Support/…` —
            // i zapisuje klucz hosta do pierwszego z nich. Zmierzone: w katalogu aplikacji
            // nie powstawał żaden `known_hosts`, za to w `~/Library/` leżał plik o nazwie
            // `Application` z wpisem TOFU w środku. Czyli ochrona przed podmianą serwera
            // nie działała, cicho i bez jednego komunikatu.
            "-o", "UserKnownHostsFile=\"\(knownHosts.path)\"",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=5",               // zerwane łącze wykryte, a nie wiszące
            "-o", "ServerAliveCountMax=3",
            // Multipleksowanie: pierwsze wywołanie zestawia połączenie, kolejne przez minutę
            // jadą po nim jako dodatkowe kanały. Bez tego każde odświeżenie (co 5 s) to pełny
            // handshake TCP, wymiana kluczy, uwierzytelnienie i osobny fork sshd plus wpis
            // w logu auth serwera — dwanaście razy na minutę, w kółko.
            "-o", "ControlMaster=auto",
            // Tu ten sam powód, ale skutek był głośniejszy: `ControlPath` przyjmuje
            // DOKŁADNIE jeden argument, więc spacja nie dawała cichej listy, tylko
            // twardy błąd „keyword controlpath extra arguments at end of line" —
            // i cały kanał SSH przestawał działać.
            "-o", "ControlPath=\"\(controlPath)\"",
            "-o", "ControlPersist=60",
        ]
        if forceTTY { args += ["-tt", "-o", "LogLevel=ERROR"] }
        args += ["\(user)@\(host)", command]
        p.arguments = args

        // Wyjście zbieramy do plików tymczasowych, nie do `Pipe`.
        //
        // Powód: czytanie jednego potoku do końca, a dopiero potem drugiego, zakleszcza się —
        // gdy komenda zapełni ~64 kB bufora stderr (sensors-detect, dmesg), jądro blokuje jej
        // zapis, ona przestaje pisać na stdout, a `readDataToEndOfFile()` nigdy nie wraca.
        // Równoległy odczyt dwóch potoków to naprawa podręcznikowa, ale przy ControlPersist
        // dochodzi druga pułapka: tło mastera dziedziczy deskryptory, więc potok może nie
        // dostać EOF aż do wygaśnięcia gniazda. Plik nie blokuje zapisu ani nie czeka na EOF —
        // znika cała klasa problemu, kosztem dwóch plików w /tmp na komendę.
        let stamp = UUID().uuidString
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("mNas-\(stamp).out")
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("mNas-\(stamp).err")
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: attrs)
        FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: attrs)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return Result(output: "", error: String(localized: "Nie udało się przygotować pliku na wyjście komendy."), code: -1)
        }
        p.standardOutput = outHandle
        p.standardError = errHandle
        p.standardInput = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            try? outHandle.close(); try? errHandle.close()
            Log.ssh.error("Nie udało się uruchomić ssh: \(String(describing: error), privacy: .public)")
            return Result(output: "", error: "\(error)", code: -1)
        }

        // Twardy limit czasu. `ConnectTimeout` ogranicza wyłącznie nawiązanie połączenia —
        // to jest strażnik dla komendy, która już ruszyła i się zawiesiła.
        let guardBox = ProcessGuard(p)
        let sigterm = DispatchWorkItem { guardBox.terminate() }
        let sigkill = DispatchWorkItem { guardBox.forceKill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(totalTimeout), execute: sigterm)
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(totalTimeout + 3), execute: sigkill)

        p.waitUntilExit()
        sigterm.cancel()
        sigkill.cancel()
        try? outHandle.close()
        try? errHandle.close()

        let timedOut = guardBox.didTimeOut
        if timedOut {
            Log.ssh.error("Komenda przerwana po \(totalTimeout, privacy: .public) s: \(command.prefix(80), privacy: .public)")
        }
        return Result(
            output: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
            error: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "",
            code: p.terminationStatus,
            timedOut: timedOut
        )
    }
}

/// Strażnik procesu dla limitu czasu. Sprawdza `isRunning` pod tym samym zamkiem, pod
/// którym zabija — dzięki temu nie trafi sygnałem w numer PID przydzielony już komuś innemu.
nonisolated private final class ProcessGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var timedOut = false

    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return }
        timedOut = true
        process.terminate()                                  // SIGTERM
    }

    /// `ssh -tt` ze zdalną komendą ignorującą sygnały potrafi przeżyć SIGTERM.
    func forceKill() {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return }
        timedOut = true
        kill(process.processIdentifier, SIGKILL)
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}
