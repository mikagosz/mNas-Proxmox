import Foundation

/// Buduje i odpala komendy powłoki na serwerze. Trzyma tylko adres i login — stan
/// aplikacji zostaje w `AppModel`, a parsowanie wyników w `StatsParsers`.
///
/// To jest „odblokowanie": cokolwiek zrobi root z terminala (nvidia-smi, sensors,
/// fancontrol…), mNas potrafi odpalić i pokazać. REST API nie jest sufitem — a na
/// Proxmoksie ta warstwa daje **więcej** niż API: czujniki, PWM i SMART nie mają
/// odpowiednika w `/api2/json` w ogóle.
nonisolated struct ServerCommands: Sendable {
    var host: String
    var user: String

    private var runner: SSHRunner { SSHRunner(host: host, user: user) }

    /// Czy w ogóle sięgać po `sudo`.
    ///
    /// Wersja pod TrueNAS-a logowała się kontem admina i musiała eskalować. Na Proxmoksie
    /// wchodzimy **bezpośrednio rootem**, więc `sudo` jest w najlepszym razie zbędne,
    /// a w najgorszym go po prostu nie ma — Proxmox nie instaluje `sudo` w minimalnym
    /// wariancie i komenda padałaby na „command not found" zamiast się wykonać.
    private var needsSudo: Bool { user != "root" }

    // MARK: - Higiena wejścia

    /// Cytowanie dla powłoki — wszystko, co idzie do `bash -lc`, przechodzi przez to.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Biała lista znaków dla nazw pul, dysków i usług wstawianych do komend.
    static func safeName(_ s: String) -> String {
        s.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Ścieżka PWM sprawdzana **białą listą znaków**, nie samym przedrostkiem.
    /// Sam `hasPrefix("/sys/class/hwmon/")` przepuszczał `…/pwm1;reboot` prosto do powłoki —
    /// guard wyglądał na zabezpieczenie, którym nie był (audyt P3-01).
    static func isValidPWMPath(_ path: String) -> Bool {
        guard path.hasPrefix("/sys/class/hwmon/hwmon"), path.contains("pwm") else { return false }
        return path.unicodeScalars.allSatisfy { u in
            CharacterSet.alphanumerics.contains(u) || u == "/" || u == "_" || u == "-"
        }
    }

    // MARK: - Podstawa

    /// Dowolna komenda na serwerze. Zwraca stdout+stderr złożone w jeden tekst.
    /// `timeout` jest twardym limitem całej komendy (patrz `SSHRunner.run`).
    func run(_ command: String, sudo: Bool = false, timeout: Int = 25) async -> String {
        let escalate = sudo && needsSudo
        let full = escalate ? "sudo -n bash -lc \(Self.shellQuote(command))" : command
        let r = await runner.run(full, timeout: timeout, forceTTY: escalate)
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.timedOut {
            return String(localized: "✗ komenda przekroczyła limit \(timeout) s i została przerwana.\n\(out)\n\(err)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.isEmpty && err.isEmpty { return r.ok ? String(localized: "✓ wykonano (brak wyjścia)") : String(localized: "✗ kod \(r.code) (brak wyjścia)") }
        if err.isEmpty { return Self.sudoHint(out) }
        if out.isEmpty { return Self.sudoHint(err) }
        return Self.sudoHint(out + "\n" + err)
    }

    /// Podpowiedź, gdy powłoka zażąda hasła. Na Proxmoksie oznacza to jedno: SSH loguje
    /// się kontem innym niż root, a mNas zakłada roota.
    private static func sudoHint(_ text: String) -> String {
        guard text.lowercased().contains("a password is required") else { return text }
        return text + String(localized: "\n\n→ mNas zakłada logowanie jako root. Sprawdź część przed „@\" w polu tokenu i klucz w /root/.ssh/authorized_keys.")
    }

    // MARK: - Statystyki na żywo

    /// Jedno wywołanie SSH → wszystkie statystyki naraz (CPU, RAM, ARC, czujniki, GPU).
    /// Sekcje rozdziela potem `StatsParsers.splitSections`.
    ///
    /// > **`|| true` na końcu jest konieczne, nie kosmetyczne.**
    /// > Kod wyjścia całego skryptu to kod **ostatniej** komendy, a ostatnią jest
    /// > `nvidia-smi`. Na serwerze bez karty NVIDIA nie ma jej wcale, więc skrypt kończył
    /// > się kodem **127** — i `refreshStatsViaSSH` wyrzucał przez `guard r.ok` **całą**
    /// > odpowiedź: CPU, RAM, ARC i czujniki, mimo że te sekcje przyszły komplene.
    /// > Cicho, bo `2>/dev/null` zjadał komunikat, więc do interfejsu trafiał pusty błąd.
    /// >
    /// > Zmierzone na serwerze testowym 2026-08-16: pełna komenda → 127, ta sama bez `nvidia-smi`
    /// > → 0, `command -v nvidia-smi` → brak. Skutkiem był trwale pusty kafel
    /// > „Wentylatory" i brak temperatur CPU na maszynie, która je wystawia.
    /// >
    /// > `|| true` dotyczy wyłącznie ostatniej komendy, więc realne awarie SSH
    /// > (np. 255 przy zerwanym połączeniu) nadal ustawiają niezerowy kod.
    /// Trzy sekcje dołożone 2026-08-19, wszystkie w tym samym wywołaniu — osobne
    /// połączenie SSH co pięć sekund kosztowałoby więcej niż same odczyty:
    /// - **`@@POWER`** — liczniki energii RAPL (`/sys/class/powercap`). Zwracamy surowe
    ///   mikrodżule i znacznik czasu **serwera**; waty liczy Mac z różnicy między
    ///   turami. Uśpienie na serwerze („czytaj, śpij sekundę, czytaj") wydłużyłoby
    ///   każdą turę o tę sekundę.
    /// - **`@@BLK` / `@@DF`** — mapa nośników i zajętość systemów plików. Proxmox przez
    ///   API pokazuje wyłącznie **storage'e**, więc dysk, który nie jest storagem
    ///   (na serwerze testowym `/mnt/zasoby`, 85% zajęte), nie istniał nigdzie w programie.
    /// - **`@@LVM`** — pule cienkie LVM. `df` ich nie widzi, bo to nie są zamontowane
    ///   systemy plików, tylko wolumeny maszyn. Bez tego dysk z pulą na 141 GB
    ///   pokazywał zajętość samego `/` i wyglądał na pusty.
    func liveStats(timeout: Int = 6) async -> SSHRunner.Result {
        await runner.run("""
        echo '@@STAT'; grep '^cpu' /proc/stat
        echo '@@MEM'; cat /proc/meminfo
        echo '@@ARC'; awk '$1=="size"{print $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null
        echo '@@SENSORS'; sensors -j 2>/dev/null
        echo '@@GPU'; nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw --format=csv,noheader,nounits 2>/dev/null || true
        echo '@@POWER'; date +%s%N
        for d in /sys/class/powercap/intel-rapl:*/; do
          n=$(cat "$d/name" 2>/dev/null) || continue
          e=$(cat "$d/energy_uj" 2>/dev/null) || continue
          m=$(cat "$d/max_energy_range_uj" 2>/dev/null || echo 0)
          echo "$n $e $m"
        done
        echo '@@BLK'; lsblk -b -P -o KNAME,PKNAME,TYPE,TRAN,MODEL,SIZE,MOUNTPOINT 2>/dev/null
        echo '@@DF'; df -B1 -P 2>/dev/null | tail -n +2
        echo '@@LVM'
        pvs --noheadings --units b --nosuffix -o pv_name,vg_name 2>/dev/null | awk '{print "PV " $1 " " $2}'
        lvs --noheadings --units b --nosuffix -o vg_name,lv_size,data_percent,lv_attr 2>/dev/null | awk 'NF>=4 && substr($4,1,1)=="t" {print "POOL " $1 " " $2 " " $3}'
        """, timeout: timeout)
    }

    /// Stała charakterystyka procesora — wątki, cache, gniazda, taktowanie.
    ///
    /// Osobno od `liveStats`, bo to się nie zmienia: czytane raz na połączenie, a nie
    /// co pięć sekund razem z licznikami.
    func cpuStatic(timeout: Int = 6) async -> SSHRunner.Result {
        await runner.run("LC_ALL=C lscpu", timeout: timeout)
    }

    /// Temperatury dysków — zastępstwo za `disk.temperatures` z API TrueNAS-a, którego
    /// Proxmox nie ma (`/nodes/{node}/disks/list` podaje SMART-owe „PASSED", ale nie °C).
    ///
    /// Dwie rzeczy są tu celowe:
    /// - **`-n standby`** — smartctl nie budzi dysku, który śpi. Bez tego odpytywanie
    ///   co minutę trzymałoby talerzowy dysk w kieszeni USB wiecznie rozkręcony.
    /// - **`-H`** (od 2026-09-11) — przy okazji bierzemy werdykt SMART, żeby `disks/list`
    ///   mogło chodzić z `skipsmart=1`. Ta ścieżka i tak już tu jest, chodzi co 60 s
    ///   i **nie budzi** śpiącego dysku, więc kondycja jest świeższa niż była, a talerze
    ///   śpią. Uzasadnienie i pomiar: `ProxmoxClient.disks(skipSmart:)`.
    /// - **surowy JSON na Maca** — parsowanie zostaje w `StatsParsers`, testowalne bez
    ///   serwera. Wyciąganie liczby `awk`-iem po stronie serwera wymagałoby zgadywania
    ///   formatu, który różni się między NVMe, SATA i mostkiem USB.
    func diskTemperatures(disks names: [String]) async -> SSHRunner.Result {
        let safe = names.map(Self.safeName).filter { !$0.isEmpty }
        guard !safe.isEmpty else { return SSHRunner.Result(output: "", error: "", code: 0) }
        let loop = safe.map { "echo '@@\($0)'; \(escalated("smartctl -A -H -n standby -j /dev/\($0)")) 2>/dev/null" }
            .joined(separator: "\n")
        return await runner.run(loop, timeout: 20, forceTTY: needsSudo)
    }

    /// Wykrywa narzędzia webowe stojące w kontenerach: adres kontenera + porty nasłuchu.
    ///
    /// Idzie po **działających** kontenerach (`pct list`), bo tylko one mogą czegokolwiek
    /// słuchać. Dla każdego:
    /// - adres bierzemy najpierw z `pct config` (statyczny wpis `ip=`), a gdy tam stoi
    ///   `dhcp` — pytamy sam kontener przez `pct exec`. Kolejność jest celowa: konfiguracja
    ///   węzła odpowiada zawsze, `pct exec` wymaga działających narzędzi w środku;
    /// - porty z `ss -H -tln` **wewnątrz** kontenera, bo każdy ma własną przestrzeń
    ///   sieciową i z hosta ich nie widać.
    ///
    /// Maszyny QEMU są tu świadomie pominięte: bez agenta gościa nie da się w nich
    /// niczego uruchomić, a zgadywanie portów dałoby martwe kafle.
    ///
    /// > [!important] Kontenery **równolegle**, jeden `pct config` na kontener
    /// > Każde wywołanie `pct` kosztuje ~0,77 s. Po kolei, z dwoma `pct config`, dawało
    /// > ~2,35 s na kontener — przy 12 kontenerach 29–30 s, ponad limit 25 s, więc
    /// > wykrywanie nigdy się nie kończyło, a kafel „Narzędzia” pojawiał się i znikał
    /// > (`Problem-kafel-narzedzia-wykrywanie-nie-miesci-sie-w-limicie`, 2026-09-29).
    /// > Równolegle: 6 s razem z zestawieniem SSH, wynik co do bloku ten sam.
    /// >
    /// > Każdy kontener składa swój blok w zmiennej i wypisuje go **jednym** `printf` —
    /// > blok ma kilkaset bajtów, zapis poniżej `PIPE_BUF` jest niepodzielny, więc bloki
    /// > nie przeplatają się wierszami. Kolejność bloków jest dowolna; parser i tak
    /// > sortuje wynik.
    func discoverWebServices(timeout: Int = 25) async -> SSHRunner.Result {
        await runner.run(#"""
        for id in $(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'); do
          (
            conf=$(pct config "$id" 2>/dev/null)
            name=$(printf '%s\n' "$conf" | awk -F': ' '/^hostname:/{print $2}')
            ip=$(printf '%s\n' "$conf" | grep -o 'ip=[0-9.]*' | head -n1 | cut -d= -f2)
            if [ -z "$ip" ]; then
              ip=$(pct exec "$id" -- ip -4 -br addr show 2>/dev/null | awk '$1!="lo"{split($3,a,"/"); print a[1]; exit}')
            fi
            b="@@CT $id ${name:-ct$id}"
            [ -n "$ip" ] && b="$b
        IP $ip"
            l=$(pct exec "$id" -- ss -H -tln 2>/dev/null | awk '{print "LISTEN " $4}')
            [ -n "$l" ] && b="$b
        $l"
            printf '%s\n' "$b"
          ) &
        done
        wait
        """#, timeout: timeout)
    }

    /// Stan monitorów Uptime Kumy, czytany **wprost z jej bazy** przez `pct exec`.
    ///
    /// Dlaczego nie po HTTP: Uptime Kuma nie ma publicznego REST-u. Zostają trzy drogi
    /// i dwie z nich wymagają **zmiany na serwerze**, czego przy zwykłym odczycie robić
    /// nie chcemy: `/metrics` odpowiada `401` bez wystawionego klucza API (zmierzone
    /// 2026-08-20), a `/api/status-page/…` wymaga wcześniej założonej strony statusu
    /// (`{"status":"fail","msg":"Status Page Not Found"}`). Trzecia droga — odczyt bazy —
    /// działa dziś, nie wymaga zakładania niczego i nie zostawia po sobie konfiguracji.
    ///
    /// `-readonly` jest warunkiem, nie ozdobą: baza pracującej Kumy jest w trybie WAL
    /// i zapisujące otwarcie mogłoby jej zaszkodzić. Ten odczyt **niczego nie zmienia**.
    ///
    /// Ścieżka bazy różni się między instalacją z paczki a kontenerem dockerowym, więc
    /// sprawdzamy trzy znane miejsca i bierzemy pierwsze istniejące. `@@BRAK-BAZY`
    /// znaczy „to nie jest kontener z Kumą" — inaczej niż pusty wynik, który znaczy
    /// „Kuma jest, ale nie ma monitorów".
    ///
    /// Numeru kontenera **nie wpisujemy w kod** — podaje go `AppModel`, wyszukując
    /// kontener po nazwie w liście gości, którą i tak pobieramy co turę.
    func kumaMonitory(ctid: Int, timeout: Int = 20) async -> SSHRunner.Result {
        let sql = """
        SELECT m.id||'|'||coalesce(m.name,'')||'|'||coalesce(m.type,'')||'|'||coalesce(m.active,0) \
        ||'|'||coalesce(h.status,-1)||'|'||coalesce(h.time,'') \
        ||'|'||replace(replace(coalesce(h.msg,''),char(10),' '),char(13),' ') \
        FROM monitor m LEFT JOIN heartbeat h \
        ON h.id=(SELECT id FROM heartbeat WHERE monitor_id=m.id ORDER BY time DESC LIMIT 1) \
        ORDER BY m.id;
        """
        let wewnetrzny = """
        for p in /opt/uptime-kuma/data/kuma.db /app/data/kuma.db /opt/uptime-kuma/db/kuma.db; do \
        [ -f "$p" ] && exec sqlite3 -readonly "$p" \(Self.shellQuote(sql)); done; echo '@@BRAK-BAZY'
        """
        return await runner.run("pct exec \(ctid) -- sh -lc \(Self.shellQuote(wewnetrzny))",
                                timeout: timeout)
    }

    /// Nazwy punktów montowania: udziały Samby i magazyny Proxmoksa.
    ///
    /// Czytane **raz na połączenie**, jak `cpuStatic` — nazwa udziału zmienia się raz na
    /// pół roku, a zajętość co pięć sekund. Sama zajętość przychodzi w `@@DF` razem
    /// z resztą statystyk i nie wymaga tu żadnego dodatkowego wywołania.
    ///
    /// Wyjście jest **surowe**, składanie zostaje w `Miejsce.nazwy` — testowalne bez
    /// serwera. Wyciąganie nazw `awk`-iem w kontenerze wymagałoby cytowania wzorca przez
    /// trzy powłoki (`ssh` → `pct exec` → `sh -c`), a to już raz rozsypało odczyt SMART.
    ///
    /// 🔴 **Znacznik kontenera to `CT`, nie `@@CT`** — `StatsParsers.splitSections` tnie
    /// na każdej linii zaczynającej się od `@@`, więc zagnieżdżony `@@CT` rozbiłby sekcję
    /// `SMB` na kawałki.
    ///
    /// 🔴 **`exit 0` na końcu jest konieczne.** `grep` w kontenerze bez Samby kończy się
    /// kodem 2, a wywołanie, które wraca z niezerowym kodem, potrafi zostać uznane za
    /// nieudane i wyrzucić **całe** wyjście — dokładnie tak zniknęły statystyki przez
    /// brakujące `nvidia-smi` (`Problem-nvidia-smi-zabija-caly-odczyt-statystyk`).
    func nazwyMontowan(timeout: Int = 25) async -> SSHRunner.Result {
        await runner.run(#"""
        echo '@@STORAGE'; cat /etc/pve/storage.cfg 2>/dev/null
        echo '@@BIND'
        for f in /etc/pve/lxc/*.conf; do
          [ -f "$f" ] || continue
          id=$(basename "$f" .conf)
          sed -n "s|^mp[0-9]*: \([^,]*\),.*mp=\([^,]*\).*|$id \1 \2|p" "$f"
        done
        echo '@@SMB'
        for id in $(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'); do
          echo "CT $id"
          pct exec "$id" -- grep -E '^\[|^[[:space:]]*path' /etc/samba/smb.conf 2>/dev/null
        done
        exit 0
        """#, timeout: timeout)
    }

    /// Mechanizmy, które host naprawdę uruchamia — cron, timery systemd i ich dzienniki.
    ///
    /// > [!danger] Po co to powstało
    /// > Zgłoszenie [U] z 2026-08-23: w przebiegach zostawały mechanizmy, których już nie
    /// > było, bo program pokazywał dane **wpisane w kod** (ścieżkę dziennika kopii na
    /// > Macu), zamiast brać je z serwera. Zadanie wygaszono, a wiersz dalej wisiał.
    /// >
    /// > Tutaj nic nie jest wpisane: lista bierze się z `/etc/cron.d/*` i z timerów,
    /// > a ścieżka dziennika z linii `LOG=` **w samym skrypcie**. Zadanie zdjęte z crona
    /// > znika z listy bez dotykania aplikacji — i to jest test, który to sprawdza.
    ///
    /// Trzy rzeczy zmierzone 2026-08-23 przy pisaniu tej komendy:
    /// - **komentarze trzeba odsiać po stronie hosta przy szukaniu skryptów**, inaczej
    ///   wyłączone zadanie `#30 4 * * * root /usr/local/bin/kopia-dokumentow-na-hdd.sh`
    ///   dalej wciąga swój dziennik i mechanizm nie znika — dokładnie ta usterka;
    /// - **sekcja `@@CRON` idzie surowa**, razem z komentarzami: komentarz nad zadaniem
    ///   jest jego jedyną ludzką nazwą (`# Kopia 1 — folder zdjec na NAS`);
    /// - **`vzdump` z `jobs.cfg` tu nie wchodzi** — nocną kopię widać już kanałem
    ///   `.serwer` z `/nodes/{węzeł}/tasks`, a drugi wpis dublowałby ją na liście.
    func mechanizmyHosta(timeout: Int = 20) async -> SSHRunner.Result {
        await runner.run(#"""
        echo '@@CRON'
        for f in /etc/cron.d/*; do
          [ -f "$f" ] || continue
          sed "s|^|$(basename "$f")\t|" "$f"
        done
        crontab -l 2>/dev/null | sed 's|^|crontab\t|'
        echo '@@TIMERY'
        for u in $(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
                   | awk '{print $NF}' | grep '\.service$' | sort -u); do
          skrypt=$(systemctl show -p ExecStart --value "$u" 2>/dev/null \
                   | grep -oE '/usr/local/bin/[A-Za-z0-9_.-]+' | head -1)
          [ -n "$skrypt" ] || continue
          # `printf`, nie `echo` — wbudowane `echo` bash-a drukuje `\t` dosłownie,
          # a wtedy cały wiersz przychodzi jako jedno pole i timer wypada z listy.
          #
          # Czwarte pole rozstrzyga, czy to przebieg, czy czujka: timer z `OnCalendar`
          # odpala się o wyznaczonej porze (przebieg), timer z `OnUnitActiveUSec` tyka
          # w kółko co kilka sekund (czujka). Zmierzone 2026-08-23: `pomiar-ruchu`
          # ma `OnUnitActiveUSec=10s`, `logrotate` — `OnCalendar=*-*-* 00:00:00`.
          printf '%s\t%s\t%s\t%s\n' "$u" \
            "$(systemctl show -p Description --value "${u%.service}.timer" 2>/dev/null)" "$skrypt" \
            "$(systemctl show -p TimersCalendar --value "${u%.service}.timer" 2>/dev/null | tr -d '\n')"
        done
        echo '@@LOGI'
        for s in $(for f in /etc/cron.d/*; do
                     [ -f "$f" ] && grep -vE '^[[:space:]]*#' "$f" \
                       | grep -oE '/usr/local/bin/[A-Za-z0-9_.-]+'
                   done | sort -u); do
          [ -f "$s" ] || continue
          log=$(sed -n 's|^LOG=\(/var/log/[^ ]*\)$|\1|p' "$s" | head -1)
          [ -n "$log" ] || continue
          [ -f "$log" ] || continue
          echo "### $s $log"
          tail -n 5 "$log"
        done
        exit 0
        """#, timeout: timeout)
    }

    // MARK: - Historia (zbieracz mnas-historia)

    /// Instalacja albo aktualizacja zbieracza. Treść plików idzie w base64 — żadnego
    /// cytowania heredoków w heredoku. `apt-get` tylko, gdy `rrdtool` jeszcze nie ma.
    ///
    /// 🔴 Niczego nie kasuje: pliki `.rrd` w katalogu zbieracza to cała historia,
    /// a aktualizacja podmienia wyłącznie skrypt i jednostki.
    static func poleceniInstalacjiZbieracza() -> String {
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        return """
        set -e
        command -v rrdtool >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y rrdtool
        echo '\(b64(HistoriaZbieracz.skrypt))' | base64 -d > \(HistoriaZbieracz.sciezkaSkryptu)
        chmod 755 \(HistoriaZbieracz.sciezkaSkryptu)
        echo '\(b64(HistoriaZbieracz.usluga))' | base64 -d > /etc/systemd/system/mnas-historia.service
        echo '\(b64(HistoriaZbieracz.timer))' | base64 -d > /etc/systemd/system/mnas-historia.timer
        systemctl daemon-reload
        systemctl enable --now mnas-historia.timer
        \(HistoriaZbieracz.sciezkaSkryptu) --wersja
        """
    }

    func instalujZbieracz(timeout: Int = 240) async -> SSHRunner.Result {
        await runner.run(Self.poleceniInstalacjiZbieracza(), timeout: timeout)
    }

    /// Wszystkie pliki naraz, jeden `xport` na plik. `@@BRAK` = zbieracza nie ma.
    /// Moc w pliku to µJ/s (DERIVE z µJ), więc dzielimy przez milion już na serwerze.
    static func poleceniOdczytuHistorii(_ okno: OknoRRD) -> String {
        #"""
        command -v rrdtool >/dev/null && [ -d \#(HistoriaZbieracz.katalog) ] || { echo '@@BRAK'; exit 0; }
        cd \#(HistoriaZbieracz.katalog)
        echo "@@WERSJA $(\#(HistoriaZbieracz.sciezkaSkryptu) --wersja 2>/dev/null)"
        for f in *.rrd; do
          [ -f "$f" ] || continue
          echo "@@PLIK $f"
          a=()
          for d in $(rrdtool info "$f" | sed -n 's/^ds\[\(.*\)\]\.index.*/\1/p'); do
            if [ "$f" = moc.rrd ]; then
              a+=("DEF:r$d=$f:$d:AVERAGE" "CDEF:$d=r$d,1000000,/" "XPORT:$d:$d")
            else
              a+=("DEF:$d=$f:$d:AVERAGE" "XPORT:$d:$d")
            fi
          done
          rrdtool xport --json --start -\#(okno.sekundy) --end now --step \#(okno.krokZbieracza) "${a[@]}"
        done
        exit 0
        """#
    }

    func odczytajHistorie(_ okno: OknoRRD, timeout: Int = 20) async -> SSHRunner.Result {
        await runner.run(Self.poleceniOdczytuHistorii(okno), timeout: timeout)
    }

    /// Pełniejsze dzienniki skryptów hosta pod okno historii przebiegów. Ten sam dobór
    /// skryptów co `mechanizmyHosta` (`@@LOGI`), tylko 2000 linii zamiast 5.
    func logiPrzebiegow(timeout: Int = 20) async -> SSHRunner.Result {
        await runner.run(#"""
        for s in $(for f in /etc/cron.d/*; do
                     [ -f "$f" ] && grep -vE '^[[:space:]]*#' "$f" | grep -oE '/usr/local/bin/[A-Za-z0-9_.-]+'
                   done | sort -u); do
          [ -f "$s" ] || continue
          log=$(sed -n 's|^LOG=\(/var/log/[^ ]*\)$|\1|p' "$s" | head -1)
          [ -n "$log" ] && [ -f "$log" ] || continue
          echo "### $s $log"
          tail -n 2000 "$log"
        done
        exit 0
        """#, timeout: timeout)
    }

    // MARK: - Monitor transferów — przeniesiony na REST
    //
    // 🔴 Tu stały cztery polecenia czytające `/var/log/pomiar-ruchu` i `/var/log/pomiar-polaczen`
    // po SSH. [U] skasował oba źródła na hoście 2026-08-29, a monitor poszedł na RRD
    // Proxmoksa (`ProxmoxClient.rrdWezla` / `rrdGoscia`, interpretacja w `Transfery.swift`).
    // Nie odtwarzaj ich tutaj: taki licznik służy do diagnozy sprzętu sieci
    // (rozdzielczość 10 s, ramki PAUSE), a nie do kafla w mNasie.

    /// Rozmiar rosnącego pliku archiwum kopii — jedyne źródło **żywej** prędkości.
    ///
    /// Log `vzdump` podaje tempo dopiero po zakończeniu fazy (zmierzone na biegnącym
    /// zadaniu 2026-08-20: przy pakowaniu archiwum milczy aż do końca). Prędkość liczymy
    /// więc sami, z przyrostu pliku między turami odświeżania.
    ///
    /// Zwraca same bajty albo `@@BRAK` — plik pojawia się dopiero po chwili od wypisania
    /// jego nazwy w logu i to jest **normalne**, nie błąd.
    ///
    /// Ścieżka jest cytowana: pochodzi z logu serwera, więc jest danymi, nie stałą w kodzie.
    /// Ruch na dyskach — dwie próbki `/proc/diskstats` odległe o sekundę.
    ///
    /// > [!info] Dlaczego SSH, skoro reszta kafla idzie z RRD
    /// > RRD **węzła** nie ma `diskread`/`diskwrite` — sprawdzone 2026-09-04 na pełnej
    /// > liście pól. Te pola raportują tylko kontenery, a kopia z dysku na dysk
    /// > wewnątrz hosta nie należy do żadnego kontenera. Zostaje `/proc/diskstats`.
    /// >
    /// > To **nie jest** powrót do mechanizmu skasowanego 2026-08-29. Tamten stawiał
    /// > na serwerze skrypt w `/usr/local/bin/`, timer systemd co 10 s i log
    /// > w `/var/log/pomiar-ruchu`. Tutaj nie powstaje nic — jedno polecenie odczytu,
    /// > tym samym kanałem SSH, którym apka i tak czyta SMART.
    ///
    /// > [!tip] Arytmetyka siedzi po stronie serwera
    /// > Bo tam są obie próbki i tam jest znany odstęp. Apka dostaje gotowe bajty
    /// > na sekundę i nie musi pamiętać poprzedniego odczytu ani zgadywać, ile czasu
    /// > minęło między turami odświeżania.
    ///
    /// Filtr `sd[a-z]+|nvme[0-9]+n[0-9]+` bierze **całe dyski**, pomijając partycje
    /// (`sda1`, `nvme0n1p3`) i urządzenia `loop`. Bez tego ten sam bajt liczyłby się
    /// dwa razy: raz na partycji, raz na dysku.
    ///
    /// Zwraca wiersze `nazwa odczytBajtowNaSekunde zapisBajtowNaSekunde`.
    /// Sektor to 512 B — stała jądra dla `/proc/diskstats`, niezależna od tego,
    /// jakie sektory ma fizycznie dysk.
    func przeplywDyskow(timeout: Int = 12) async -> SSHRunner.Result {
        let filtr = #"$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+)$/ {print $3, $6, $10}"#
        let roznica = #"/^---$/ {s=1; next} !s {r[$1]=$2; w[$1]=$3; next} "#
            + #"$1 in r {print $1, ($2-r[$1])*512, ($3-w[$1])*512}"#
        // Bez plików tymczasowych i bez process substitution: dwie próbki lecą jednym
        // strumieniem rozdzielonym znacznikiem. Sprawdzone na serwerze testowym — nie zostawia
        // niczego w /tmp.
        let cmd = "{ awk '\(filtr)' /proc/diskstats; echo ---; sleep 1; "
            + "awk '\(filtr)' /proc/diskstats; } | awk '\(roznica)'"
        return await runner.run(cmd, timeout: timeout)
    }

    /// Trwające kopiowania na hoście — `rsync`, `cp`, `mv`, `dd`, `tar`.
    ///
    /// > [!info] Co to naprawdę czyta
    /// > `write_bytes` z `/proc/<pid>/io` — licznik jądra mówiący, ile proces zapisał.
    /// > Działa dla `cp` i `mv`, które o postępie nie mówią nic, i nie wymaga zaglądania
    /// > w log `rsync`, którego przy ręcznym uruchomieniu i tak zwykle nie ma.
    ///
    /// > [!warning] `du -sb` liczy się dla ŹRÓDŁA i ma twardy limit 5 s
    /// > Na katalogu `PROJEKTY` (51 393 pliki, 422 GiB) zajęło 303 ms — `du` czyta
    /// > metadane, nie dane. Ale źródłem może być montowanie sieciowe albo dysk, który
    /// > właśnie zasnął, więc `timeout 5` jest tu warunkiem, nie ozdobą. Po limicie
    /// > całość wychodzi jako `0`, a widok pokazuje wtedy same megabajty bez procentu.
    ///
    /// Źródło i cel to **dwa ostatnie argumenty będące istniejącymi ścieżkami** —
    /// dzięki temu przełączniki (`-aHAX`, `--numeric-ids`) nie mylą się ze ścieżkami,
    /// niezależnie od tego, w jakiej kolejności je ktoś podał.
    ///
    /// Wiersze rozdzielone **tabulatorem**: `pid ⇥ sekundy ⇥ narzędzie ⇥ zapisano ⇥
    /// odczytano ⇥ całość ⇥ źródło ⇥ cel`. Tabulator, bo ścieżki bywają ze spacjami.
    func kopieWToku(timeout: Int = 20) async -> SSHRunner.Result {
        let cmd = """
        ps -eo pid=,etimes=,comm=,args= | awk '$3=="rsync"||$3=="cp"||$3=="mv"||$3=="dd"||$3=="tar"' |         while read -r pid etimes comm args; do         io=/proc/$pid/io; [ -r "$io" ] || continue;         wb=$(awk '/^write_bytes/{print $2}' "$io"); rb=$(awk '/^read_bytes/{print $2}' "$io");         zrodlo=""; cel="";         for a in $args; do case "$a" in -*) continue;; esac; [ -e "$a" ] || continue; zrodlo="$cel"; cel="$a"; done;         calosc=0; if [ -n "$zrodlo" ]; then calosc=$(timeout 5 du -sb "$zrodlo" 2>/dev/null | cut -f1); fi;         printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$etimes" "$comm" "${wb:-0}" "${rb:-0}" "${calosc:-0}" "${zrodlo:-?}" "${cel:-?}";         done
        """
        return await runner.run(cmd, timeout: timeout)
    }

    func rozmiarPliku(_ sciezka: String, timeout: Int = 6) async -> SSHRunner.Result {
        await runner.run("stat -c %s \(Self.shellQuote(sciezka)) 2>/dev/null || echo '@@BRAK'",
                         timeout: timeout)
    }

    /// Test dostępu SSH — sprawdza też, czy jest sterownik NVIDIA.
    func connectivityTest() async -> SSHRunner.Result {
        await runner.run("echo mNas-ok; nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo NO-NVIDIA")
    }

    // MARK: - Procesy

    /// Najbardziej obciążające procesy (kind: „cpu" albo „mem").
    func topProcesses(by kind: String) async -> String {
        let sort = kind == "mem" ? "-%mem" : "-%cpu"
        return await run("ps -eo pid,%cpu,%mem,comm --sort=\(sort) | head -n 13")
    }

    // MARK: - GPU

    func gpuProcesses() async -> String {
        await run("""
        if out=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null); then
            [ -n "$out" ] && echo "$out" || echo '(brak procesów na GPU)'
        else
            echo '(brak — sterownik nieaktywny albo brak zadań na GPU)'
        fi
        """)
    }

    func gpuFullStatus() async -> String {
        await run("nvidia-smi 2>&1")
    }

    /// Diagnostyka sterownika NVIDIA — pełny obraz jednym rzutem.
    func gpuDriverDiagnostics() async -> String {
        await run("""
        echo '### lspci'; lspci -nnk | grep -A3 -i 'vga\\|nvidia'
        echo; echo '### moduły'; lsmod | grep -i 'nvidia\\|nouveau' || echo '(brak załadowanych)'
        echo; echo '### dmesg (nvidia/nouveau)'; dmesg 2>/dev/null | grep -i 'nvidia\\|nouveau' | tail -n 15
        echo; echo '### wersja modułu vs jądro'; echo "kernel: $(uname -r)"; modinfo nvidia 2>/dev/null | grep -i vermagic || echo 'modinfo nvidia: brak'
        """, sudo: true)
    }

    /// Próba podpięcia sterownika: usunięcie nouveau + modprobe nvidia.
    func gpuTryLoadDriver() async -> String {
        await run("""
        modprobe -r nouveau 2>/dev/null
        modprobe nvidia 2>&1 && echo 'modprobe nvidia OK' || echo 'modprobe nvidia FAIL'
        nvidia-smi 2>&1 | head -n 3
        """, sudo: true)
    }

    // MARK: - Wentylatory / czujniki (it87)

    /// Ładuje moduł czujników i pokazuje efekt. Wentylatory pojawią się, gdy `it87` wejdzie.
    /// `sensors-detect` i `dmesg` potrafią sypać na stderr, więc limit czasu jest hojniejszy.
    func loadSensorsModule() async -> String {
        await run("""
        echo '### próba it87 (standard)'; modprobe it87 2>&1 && echo OK || echo 'standard FAIL'
        echo '### próba it87 force_id=0x8622'; modprobe it87 force_id=0x8622 2>&1 && echo OK || echo 'force FAIL'
        echo; echo '### sensors'; sensors 2>&1 | head -n 40
        """, sudo: true)
    }

    /// Realne wykrycie czujników sprzętowych (adres/model chipu) zamiast zgadywania force_id.
    func sensorsDetect() async -> String {
        await run("sensors-detect --auto 2>&1", sudo: true, timeout: 60)
    }

    /// Surowy odczyt czujników (wentylatory, temperatury, PWM).
    func sensorsRaw() async -> String {
        await run("sensors 2>&1")
    }

    /// Wykrywa kanały PWM (ścieżka sysfs + aktualna wartość 0–255 + tryb).
    func readPWMChannels() async -> String {
        await run("""
        for f in /sys/class/hwmon/hwmon*/pwm[0-9]; do
          [ -e "$f" ] || continue
          en="${f}_enable"; ev=$( [ -e "$en" ] && cat "$en" 2>/dev/null || echo '?')
          echo "$f = $(cat "$f" 2>/dev/null) tryb=$ev"
        done
        [ -e /sys/class/hwmon/hwmon0/pwm1 ] || echo '(brak PWM — załaduj it87)'
        """, sudo: true)
    }

    /// Ustawia PWM na wskazanej ścieżce sysfs; najpierw tryb ręczny.
    ///
    /// Dolny próg (`PWM.minimum`) jest egzekwowany **tutaj**, nie tylko na suwaku:
    /// `pwmX_enable = 1` wyłącza automatykę układu, więc wartość 0 zatrzymałaby wentylator
    /// na dobre — obroty nie wróciłyby przy wzroście temperatury (audyt P1-04).
    func setPWM(path: String, value: Int) async -> String {
        let p = path.filter { !$0.isWhitespace }
        guard Self.isValidPWMPath(p) else { return String(localized: "Nieprawidłowa ścieżka PWM.") }
        let v = max(PWM.minimum, min(PWM.maximum, value))
        let note = value < PWM.minimum ? String(localized: " (podniesione z \(value) do progu minimalnego)") : ""
        // Komunikaty wypisuje `echo` na serwerze — tekst w języku programu, przez `shellQuote`.
        let ok = Self.shellQuote("PWM \(p) = \(v)/255\(note)")
        let blad = Self.shellQuote(String(localized: "zapis nieudany"))
        return await run("echo \(PWM.manualMode) > \(p)_enable 2>/dev/null; echo \(v) > \(p) && echo \(ok) || echo \(blad)", sudo: true)
    }

    /// Przywraca automatyczne sterowanie wentylatorem (BIOS/układ).
    /// `2` to typowy tryb automatyczny, `5` używa część układów ITE — próbujemy obu.
    func setPWMAuto(path: String, timeout: Int = 25) async -> String {
        let p = path.filter { !$0.isWhitespace }
        guard Self.isValidPWMPath(p) else { return String(localized: "Nieprawidłowa ścieżka PWM.") }
        return await run("echo 2 > \(p)_enable 2>/dev/null || echo 5 > \(p)_enable; echo \(Self.shellQuote(String(localized: "Tryb automatyczny")))", sudo: true, timeout: timeout)
    }

    // MARK: - Kondycja dysków (SMART)

    /// Surowe wyjście `smartctl -j` dla jednego dysku. Parsowanie robi `StatsParsers.smart`.
    func smartRaw(disk: String) async -> SSHRunner.Result {
        await runner.run(escalated("smartctl -j -H -A -i /dev/\(Self.safeName(disk))"), timeout: 20, forceTTY: needsSudo)
    }

    func startSelfTest(disk: String, long: Bool) async -> SSHRunner.Result {
        let type = long ? "long" : "short"
        return await runner.run(escalated("smartctl -t \(type) /dev/\(Self.safeName(disk))"), timeout: 20, forceTTY: needsSudo)
    }

    /// Prefiks `sudo -n` tylko wtedy, gdy konto SSH nie jest rootem.
    private func escalated(_ command: String) -> String {
        needsSudo ? "sudo -n " + command : command
    }
}
