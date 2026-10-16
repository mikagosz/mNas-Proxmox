# upgrade.sh – tryb "-u" (instalowanie aktualizacji) dla pve-update-check.
# Ładowany przez pve-update-check po sprawdzeniu; korzysta z jego zmiennych
# (M_KIND, M_ID, … , ustawienia z config) i funkcji (trim).
# Instaluje się jako /usr/local/lib/pve-update-check/upgrade.sh.
#
# Kolejność: najpierw kontenery/VM (każdy po snapshocie), host PVE na końcu.
# Nigdy nie restartuje hosta. Kontener restartuje tylko po potwierdzeniu.

UP_DONE=() UP_FAIL=() UP_SKIP=() UP_REBOOT=() UP_IDS=() UP_SUMMARY=""
UP_START=$(date -Iseconds)
UP_RES=""    # wyniki per maszyna: typ \t id \t etykieta \t wynik \t snapshot \t problemy \t kopia \t ostrzeżenia \t do skasowania (listy rozdzielone \x1f)
up_res() { UP_RES+=$(printf '%s\t' "$@")$'\n'; }
UP_LOG="$LOG_DIR/aktualizacja-$(date +%Y%m%d-%H%M%S).log"
# Postęp 0–100 dla innych programów (mNas: pasek). Maszyna nr UP_IDX z UP_N dostaje
# równy kawałek; wewnątrz: kopia/snapshot do 15%, pakiety 15–65% (wg linii
# "Unpacking"/"Setting up" z apt względem liczby pakietów), Nextcloud 65–90%.
UP_PCT=0 UP_IDX=0 UP_N=1
up_pct() {    # up_pct <ułamek maszyny 0..1000> – ustawia UP_PCT
    local p=$(( (UP_IDX * 1000 + $1) * 95 / (UP_N * 1000) ))
    (( p > UP_PCT )) && UP_PCT=$p
    return 0
}

# Skrypt aktualizacji uruchamiany w maszynie (POSIX sh). Na końcu wypisuje znaczniki
# PUC_PKG_RC=<0/1>, PUC_NC_RC=1 (błąd Nextclouda), PUC_REBOOT=1.
GUEST_UPGRADE=$(cat <<'EOF'
export LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
rc=0
if [ "${PUC_PKG:-1}" = 1 ]; then echo "--- pakiety systemu"; fi
if [ "${PUC_PKG:-1}" != 1 ]; then
    echo "--- pakiety systemu: pominięte (zakres: aplikacje)"
elif command -v apt-get >/dev/null 2>&1; then
    # Proxmox i Debian: zawsze dist-upgrade (full-upgrade), nigdy samo "apt upgrade"
    apt-get update -q || rc=1
    [ $rc = 0 ] && { apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade || rc=1; }
    # pobrane .deb są po udanej instalacji zbędne (~200 MB na kontener) – ale kasujemy je
    # dopiero, gdy dpkg nie ma pakietów w połowie instalacji, a apt nie widzi zepsutych zależności
    if [ $rc = 0 ]; then
        audit=$(dpkg --audit 2>&1 | head -n 1)
        check=$(apt-get check -q 2>&1 >/dev/null | head -n 1)
        if [ -z "$audit" ] && apt-get check -q >/dev/null 2>&1; then
            apt-get clean && echo "--- sprzątanie: apt-get clean (dpkg i apt sprawdzone)"
        else
            echo "--- sprzątanie pominięte: dpkg --audit albo apt-get check zgłasza problem, pakiety zostają"
            echo "PUC_UWAGA apt: nie wyczyszczono pobranych pakietów – ${audit:-${check:-apt-get check zwrócił błąd}}"
            echo "PUC_DO_SKASOWANIA apt"
        fi
    fi
elif command -v apk >/dev/null 2>&1; then
    apk upgrade -U || rc=1
elif command -v dnf >/dev/null 2>&1; then
    dnf -y upgrade || rc=1
elif command -v pacman >/dev/null 2>&1; then
    pacman -Syu --noconfirm || rc=1
else
    echo "nieobslugiwany menedzer pakietow"; rc=1
fi
echo "PUC_PKG_RC=$rc"

for occ in /var/www/nextcloud/occ /var/www/html/nextcloud/occ /var/www/html/occ /usr/share/nextcloud/occ /srv/nextcloud/occ; do
    [ -f "$occ" ] || continue
    dir=${occ%/occ}
    owner=$(stat -c %U "$dir/config/config.php" 2>/dev/null || echo www-data)
    if [ "${PUC_NC_SERVER:-0}" = 1 ]; then
        # updater pobiera paczkę i robi kopię starych plików w katalogu danych – bez miejsca
        # zostawia Nextclouda w trybie konserwacji, więc sprawdzamy przed startem
        data=$(su -s /bin/sh "$owner" -c "php '$occ' config:system:get datadirectory" 2>/dev/null)
        [ -d "$data" ] || data=$dir/data
        free=$(df -Pm "$data" 2>/dev/null | awk 'NR == 2 { print $4 }')
        if [ -n "$free" ] && [ "$free" -lt "${PUC_NC_MIN_FREE_MB:-2048}" ]; then
            echo "--- Nextcloud: za mało miejsca na serwer ($free MB wolne w $data, potrzeba ${PUC_NC_MIN_FREE_MB:-2048} MB) – pomijam updater"
            echo "PUC_NC_RC=1"
        elif [ -f "$dir/updater/updater.phar" ]; then
            echo "--- Nextcloud: aktualizacja serwera (updater.phar)"
            if su -s /bin/sh "$owner" -c "php '$dir/updater/updater.phar' --no-interaction"; then
                # Stare kopie updatera kasujemy dopiero po weryfikacji, że Nextcloud naprawdę wstał
                # w nowej wersji: zainstalowany, bez trybu konserwacji, bez zaległej migracji bazy.
                st=$(su -s /bin/sh "$owner" -c "php '$occ' status --output=json" 2>/dev/null)
                nv=$(printf '%s' "$st" | sed -n 's/.*"versionstring":"\([0-9.]*\)".*/\1/p')
                ok=1    # każdy warunek osobno – kolejność pól w JSON nie jest gwarantowana
                for w in '"installed":true' '"maintenance":false' '"needsDbUpgrade":false'; do
                    printf '%s' "$st" | grep -qF "$w" || ok=0
                done
                if [ "$ok" = 1 ] && [ -n "$nv" ]; then
                    for b in "$data"/updater-*/backups; do
                        [ -d "$b" ] || continue
                        ls -1dt "$b"/nextcloud-* 2>/dev/null | tail -n +2 | while IFS= read -r old; do
                            [ "${old#"$b"/nextcloud-}" != "$old" ] || continue    # tylko kopie updatera
                            ov=$(printf '%s' "${old##*/nextcloud-}" | grep -oE '^[0-9]+(\.[0-9]+)+' | cut -d. -f1-3)
                            # kopia musi być starsza od działającej wersji
                            if [ -n "$ov" ] && [ "$ov" != "$nv" ] && [ "$(printf '%s\n%s\n' "$ov" "$nv" | sort -V | tail -n1)" = "$nv" ]; then
                                rm -r -- "$old" && echo "--- sprzątanie: usunięto starą kopię updatera ${old##*/} (działa $nv)"
                            fi
                        done
                    done
                else
                    echo "--- sprzątanie pominięte: Nextcloud nie potwierdził poprawnego stanu po aktualizacji, kopie updatera zostają"
                    why=""
                    printf '%s' "$st" | grep -qF '"installed":true' || why="$why nie odpowiada jako zainstalowany;"
                    printf '%s' "$st" | grep -qF '"maintenance":false' || why="$why jest w trybie konserwacji;"
                    printf '%s' "$st" | grep -qF '"needsDbUpgrade":false' || why="$why czeka na aktualizację bazy (occ upgrade);"
                    [ -n "$nv" ] || why="$why nie podał wersji;"
                    echo "PUC_UWAGA Nextcloud po aktualizacji:${why} stare kopie updatera nie zostały skasowane"
                    for b in "$data"/updater-*/backups; do
                        [ -d "$b" ] || continue
                        ls -1dt "$b"/nextcloud-* 2>/dev/null | tail -n +2 | while IFS= read -r old; do
                            [ "${old#"$b"/nextcloud-}" != "$old" ] && echo "PUC_DO_SKASOWANIA nc $old"
                        done
                    done
                fi
            else
                echo "PUC_NC_RC=1"
            fi
        else
            echo "--- Nextcloud: brak $dir/updater/updater.phar"; echo "PUC_NC_RC=1"
        fi
    fi
    if [ "${PUC_NC_APPS:-0}" = 1 ]; then
        echo "--- Nextcloud: aktualizacja aplikacji"
        su -s /bin/sh "$owner" -c "php '$occ' app:update --all" || echo "PUC_NC_RC=1"
    fi
    break
done

[ -f /var/run/reboot-required ] && echo "PUC_REBOOT=1"
exit 0
EOF
)

# run_up <kind> <id> <skrypt> – jak run_in, ale z dłuższym limitem i z stderr.
# stdin zawsze z /dev/null: GNU timeout (bez --foreground) zakłada własną grupę procesów,
# więc przy `ssh -t … -u` wszystko pod nim jest w tle względem terminala. apt-get ze stdin
# na tty sięga po niego ioctl-em i dostaje SIGTTOU – staje w stanie T (do_signal_stop) na
# godzinę, z blokadą dpkg (2026-10-16, zmierzone tym samym `timeout sh -c 'stty sane'`).
# Z mNas (bez tty) działało, bo tam stdin i tak nie był terminalem.
run_up() {
    local kind=$1 id=$2 script=$3 json
    case $kind in
        host) timeout "$UPGRADE_TIMEOUT" sh -c "$script" </dev/null 2>&1 ;;
        ct)   timeout "$UPGRADE_TIMEOUT" pct exec "$id" -- sh -c "$script" </dev/null 2>&1 ;;
        vm)
            json=$(timeout "$((UPGRADE_TIMEOUT + 30))" qm guest exec "$id" --timeout "$UPGRADE_TIMEOUT" -- sh -c "$script" 2>&1) || { echo "$json"; return 1; }
            perl -MJSON -0777 -ne 'my $j = eval { decode_json($_) } or exit 1;
                print $j->{"out-data"} // "", $j->{"err-data"} // ""; exit($j->{exitcode} // 0)' <<<"$json" ;;
    esac
}
# Zmienne dla skryptu w maszynie (próg miejsca dla updatera Nextclouda).
GUEST_UPGRADE="PUC_NC_MIN_FREE_MB=$NC_MIN_FREE_MB"$'\n'"$GUEST_UPGRADE"

# up_state <trwa|ok|bledy|nic|przerwana> [etap/podsumowanie] – $STATE_DIR/aktualizacja.json dla innych programów
up_state() {
    UP_TRWA=$([[ $1 == trwa ]] && echo 1 || echo 0)    # w podpowłoce (follow_progress) nie wraca – i dobrze
    mkdir -p "$STATE_DIR" || return
    local f=$STATE_DIR/aktualizacja.json
    PUC_S=$1 PUC_TXT=${2:-} PUC_LOG=$UP_LOG PUC_ONLY=$ONLY PUC_SCOPE=$SCOPE PUC_START=$UP_START \
    PUC_END=$([[ $1 == trwa ]] || date -Iseconds) PUC_PID=$$ PUC_RES=$UP_RES \
    PUC_PCT=$([[ $1 == trwa ]] && echo "$UP_PCT" || echo 100) perl -MJSON::PP -e '
        use Encode qw(decode); my %e = map { $_ => decode("UTF-8", $ENV{$_} // "") } keys %ENV;
        my $trwa = $e{PUC_S} eq "trwa";
        my @w = map { my @f = split /\t/, $_, -1;
                      { typ => $f[0], id => "$f[1]", etykieta => $f[2], wynik => $f[3],
                        snapshot => ($f[4] || undef), problemy => ($f[5] || undef), kopia => ($f[6] || undef),
                        ostrzezenia => [ grep { length } split /\x1f/, ($f[7] // "") ],
                        do_sprzatania => [ grep { length } split /\x1f/, ($f[8] // "") ] } }
                grep { length } split /\n/, $e{PUC_RES};
        print JSON::PP->new->utf8->canonical->pretty->encode({
            stan => $e{PUC_S}, maszyna => ($e{PUC_ONLY} || undef), zakres => $e{PUC_SCOPE},
            start => $e{PUC_START}, koniec => ($trwa ? undef : $e{PUC_END}), pid => $e{PUC_PID} + 0,
            etap => ($trwa ? $e{PUC_TXT} : undef), podsumowanie => ($trwa ? undef : $e{PUC_TXT}),
            wyniki => \@w, postep => $e{PUC_PCT} + 0,
            log => $e{PUC_LOG} });
    ' > "$f.tmp" && mv "$f.tmp" "$f"
}

# Przerwanie w trakcie (Ctrl+C, zerwane SSH, kill, exit w pół drogi): wynik idzie do
# aktualizacja.json jako "przerwana", żeby nie został "trwa" z martwym pid – mNas pokazywał
# wtedy pasek bez końca (2026-10-16). SIGKILL-a złapać się nie da: na to mNas sam
# sprawdza, czy pid żyje. Pakiety, które apt właśnie instaluje, mogą chodzić dalej w tle.
UP_TRWA=0
up_przerwij() {    # up_przerwij <sygnał|EXIT> <kod wyjścia>
    trap - EXIT INT TERM HUP
    if (( UP_TRWA )); then
        local co="sygnał $1"
        [[ $1 == EXIT ]] && co="skrypt zakończył się w trakcie (kod $2)"
        echo "!!! przerwane: $co" >>"$UP_LOG" 2>/dev/null
        up_state przerwana "Przerwane: $co. Wynik niepełny – sprawdź log: $UP_LOG"
    fi
    [[ $1 == EXIT ]] || exit "$2"
}
trap 'up_przerwij EXIT $?' EXIT
trap 'up_przerwij SIGINT 130' INT
trap 'up_przerwij SIGTERM 143' TERM
trap 'up_przerwij SIGHUP 129' HUP

# follow_progress <etykieta> <plik> <liczba pakietów> – czyta wyjście aktualizacji z stdin,
# dopisuje je do logu i <pliku>, przy -u bez -y pokazuje na ekranie, i odświeża postęp
follow_progress() {
    local label=$1 out=$2 npk=$3 l steps=0 frac stage="$1" last=$SECONDS now
    while IFS= read -r l; do
        printf '%s\n' "$l" >>"$out"; printf '%s\n' "$l" >>"$UP_LOG"
        (( ASSUME_YES )) || printf '    | %s\n' "$l"
        case $l in
            "--- pakiety systemu"*)            stage="$label: pakiety systemu"; up_pct 150 ;;
            "Unpacking "*|"Setting up "*)      steps=$((steps + 1))
                                                frac=$(( (steps + 1) / 2 )); (( frac > npk )) && frac=$npk
                                                up_pct "$(( 150 + 500 * steps / (2 * npk) > 650 ? 650 : 150 + 500 * steps / (2 * npk) ))"
                                                stage="$label: pakiety ($frac/$npk)" ;;
            "PUC_PKG_RC="*)                    up_pct 650 ;;
            "--- Nextcloud: aktualizacja serwera"*) stage="$label: serwer Nextclouda"; up_pct 660 ;;
            "--- Nextcloud: aktualizacja aplikacji"*) stage="$label: aplikacje Nextclouda"; up_pct 800 ;;
            *) continue ;;
        esac
        # linie apt najwyżej raz na sekundę (potrafi ich wypisać setki naraz);
        # nowy etap (znacznik "--- ") zapisuje się od razu – updater Nextclouda po nim milczy
        now=0; [[ $l == "--- "* ]] && now=1
        (( now || SECONDS != last )) && { up_state trwa "$stage"; last=$SECONDS; }
    done
    up_pct 900; up_state trwa "$stage"
}

ask() {    # ask <pytanie> – 0 gdy "t"/"tak"
    local a
    read -r -p "$1 [t/N] " a </dev/tty || return 1
    [[ $a == [tTyY]* ]]
}

auto_ok() {    # czy w trybie -y wolno aktualizować tę maszynę
    [[ -n $ONLY && $ONLY == "$2" ]] && return 0     # jawnie wskazana przez -t
    [[ $1 == host ]] && return $(( ! AUTO_UPGRADE_HOST ))
    [[ $AUTO_UPGRADE_IDS == all || " $AUTO_UPGRADE_IDS " == *" $2 "* ]]
}

# make_snapshot <kind> <id> – ustawia SNAP_NAME; usuwa stare snapshoty puc_
# snapshot_possible <kind> <id> – czy Proxmox w ogóle zrobi snapshot. Bez tego sprawdzenia
# nieudana próba zostawia w Proxmoksie zadanie z błędem „snapshot feature is not available”,
# które mNas (i panel) pokazują jako alert. Nie da się: storage typu dir/nfs/cifs (plik .raw)
# i kontener z podpiętym katalogiem hosta (bind mount, „mpN: /…”).
snapshot_possible() {
    local kind=$1 id=$2 cfg vol st typ
    [[ $kind == vm ]] && return 0      # VM: zostawiamy decyzję Proxmoksowi
    cfg=$(pct config "$id" 2>/dev/null) || return 1
    if grep -qE '^mp[0-9]+: /' <<<"$cfg"; then SNAP_WHY="podpięty katalog hosta (bind mount)"; return 1; fi
    while IFS= read -r vol; do
        st=${vol%%:*}
        typ=$(awk -v s="$st" '$1 == s { print $2 }' < <(pvesm status 2>/dev/null))
        case $typ in
            dir|nfs|cifs|glusterfs|"") SNAP_WHY="storage $st (${typ:-?}) bez snapshotów"; return 1 ;;
        esac
    done < <(sed -nE 's/^(rootfs|mp[0-9]+): ([^,]+).*/\2/p' <<<"$cfg")
    return 0
}

make_snapshot() {
    local kind=$1 id=$2 tool=pct old
    [[ $kind == vm ]] && tool=qm
    SNAP_WHY=""
    if ! snapshot_possible "$kind" "$id"; then
        echo "  snapshot niemożliwy: $SNAP_WHY" | tee -a "$UP_LOG"
        return 1
    fi
    SNAP_NAME="puc_$(date +%Y%m%d_%H%M%S)"
    $tool snapshot "$id" "$SNAP_NAME" --description "pve-update-check: przed aktualizacją" >>"$UP_LOG" 2>&1 || return 1
    for old in $($tool listsnapshot "$id" 2>/dev/null | grep -oE 'puc_[0-9]{8}_[0-9]{6}' | sort -u | head -n "-$SNAPSHOT_KEEP"); do
        $tool delsnapshot "$id" "$old" >>"$UP_LOG" 2>&1 && echo "  usunięto stary snapshot $old"
    done
    return 0
}

# make_backup <kind> <id> – kopia vzdump na $BACKUP_STORAGE, gdy snapshot jest niemożliwy
# (storage "dir"). Ustawia BACKUP_VOL; zapisuje ją w $STATE_DIR/kopie i usuwa starsze
# WŁASNE kopie tej maszyny ponad BACKUP_KEEP (cudzych kopii nie dotyka).
make_backup() {
    local kind=$1 id=$2 out vol list=$STATE_DIR/kopie old n
    BACKUP_VOL=""
    [[ -n $BACKUP_STORAGE ]] || return 1
    local label; label=$(label_of "$id")
    # Na storage "dir" vzdump robi najpierw pełną kopię roboczą kontenera, potem archiwum –
    # chwilowo zajmuje ok. 2× tyle, ile kontener ma danych. Bez tego miejsca nie zaczynamy.
    local path used=0 free0=0 free pct
    path=$(awk -v s="$BACKUP_STORAGE" '/^[a-z]+: / { cur = $2 } $1 == "path" && cur == s { print $2 }' /etc/pve/storage.cfg)
    [[ $kind == ct ]] && used=$(pct exec "$id" -- df -P -B1M / 2>/dev/null | awk 'NR == 2 { print $3 }')
    [[ -n $path ]] && free0=$(df -P -B1M "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [[ $used =~ ^[0-9]+$ && $free0 =~ ^[0-9]+$ ]] && (( used > 0 && free0 < used * 22 / 10 )); then
        echo "  ! za mało miejsca na kopię: $free0 MB wolne na $BACKUP_STORAGE, potrzeba ok. $(( used * 22 / 10 )) MB" | tee -a "$UP_LOG"
        return 1
    fi
    echo "  kopia vzdump na $BACKUP_STORAGE (to potrwa kilka minut)…"
    up_pct 20; up_state trwa "$label: kopia przed aktualizacją"
    out=$(mktemp)
    vzdump "$id" --storage "$BACKUP_STORAGE" --mode snapshot --compress zstd \
        --notes-template "pve-update-check: przed aktualizacją" >"$out" 2>&1 &
    local vpid=$! rc
    # postęp kopii: ile miejsca na storage'u ubyło względem ~2× danych kontenera
    while kill -0 "$vpid" 2>/dev/null; do
        sleep 3
        if [[ $used =~ ^[1-9][0-9]*$ && $free0 =~ ^[0-9]+$ ]]; then
            free=$(df -P -B1M "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')
            [[ $free =~ ^[0-9]+$ ]] || continue
            pct=$(( (free0 - free) * 100 / (2 * used) )); (( pct < 0 )) && pct=0; (( pct > 99 )) && pct=99
            up_pct $(( 20 + pct * 125 / 100 )); up_state trwa "$label: kopia przed aktualizacją ($pct%)"
        fi
    done
    wait "$vpid"; rc=$?
    cat "$out" >>"$UP_LOG"; rm -f "$out"
    (( rc == 0 )) || return 1
    # najnowsza kopia tej maszyny na storage'u (volid zawiera datę, więc sort wystarcza)
    vol=$(pvesm list "$BACKUP_STORAGE" --content backup --vmid "$id" 2>/dev/null | awk 'NR > 1 { print $1 }' | sort | tail -n1)
    [[ -n $vol ]] || return 1
    BACKUP_VOL=$vol
    mkdir -p "$STATE_DIR"
    printf '%s %s %s\n' "$kind" "$id" "$vol" >>"$list"
    n=$(awk -v k="$kind" -v i="$id" '$1 == k && $2 == i' "$list" | wc -l)
    while (( n > BACKUP_KEEP )); do
        old=$(awk -v k="$kind" -v i="$id" '$1 == k && $2 == i { print $3; exit }' "$list")
        pvesm free "$old" >>"$UP_LOG" 2>&1 && echo "  usunięto starą kopię $old"
        awk -v k="$kind" -v i="$id" -v v="$old" '!($1 == k && $2 == i && $3 == v)' "$list" >"$list.tmp" && mv "$list.tmp" "$list"
        n=$((n - 1))
    done
    return 0
}

label_of() {    # etykieta maszyny z listy do aktualizacji (albo samo ID)
    local i
    for i in "${!M_ID[@]}"; do [[ ${M_ID[i]} == "$1" ]] && { echo "${M_LABEL[i]}"; return; }; done
    echo "$1"
}

app_upgrade_cmd() {    # app_upgrade_cmd <id> <nazwa> – 5. pole z apps.conf
    local aid aname acmd asrc aupg
    while IFS='|' read -r aid aname acmd asrc aupg; do
        [[ $(trim "$aid") == "$1" && $(trim "$aname") == "$2" ]] && { trim "$aupg"; return; }
    done < "$ETC/apps.conf"
}

upgrade_one() {
    local i=$1 kind=${M_KIND[$1]} id=${M_ID[$1]} label=${M_LABEL[$1]}
    local nc_srv=0 apps_ok=0 snap="" kopia="" tmp rc prc a aname cmd app_fail="" problems=""

    echo
    echo ">>> $label: ${M_PKG[i]} pakietów, ${M_APP[i]} nowych wersji aplikacji"
    if [[ $SCOPE == pakiety && ${M_PKG[i]} == 0 ]] || [[ $SCOPE == aplikacje && ${M_APP[i]} == 0 ]]; then
        echo "  nic do zrobienia w zakresie \"$SCOPE\""; return
    fi
    if (( ASSUME_YES )); then
        auto_ok "$kind" "$id" || { echo "  pomijam (brak zgody w AUTO_UPGRADE_*)"; UP_SKIP+=("$label"); up_res "$kind" "$id" "$label" pominieto "" "brak zgody"; return; }
        (( NC_SERVER_UPGRADE && M_NCSRV[i] )) && nc_srv=1
        (( AUTO_UPGRADE_APPS )) || [[ -n $ONLY && $ONLY == "$id" ]] && apps_ok=1
    else
        if [[ $kind == host ]]; then
            echo "  UWAGA: to aktualizacja samego Proxmoxa – snapshotu hosta nie da się zrobić."
            echo "  Po aktualizacji kernela host będzie wymagał restartu (zrób go sam, w dogodnej chwili)."
            read -r -p "  Wpisz TAK, aby zaktualizować host: " a </dev/tty
            [[ $a == TAK ]] || { UP_SKIP+=("$label"); up_res "$kind" "$id" "$label" pominieto "" "odmowa"; return; }
        else
            ask "  Zaktualizować?" || { UP_SKIP+=("$label"); up_res "$kind" "$id" "$label" pominieto "" "odmowa"; return; }
        fi
        if (( NC_SERVER_UPGRADE && M_NCSRV[i] )); then
            ask "  Jest nowa wersja serwera Nextcloud. Zaktualizować też serwer (updater)?" && nc_srv=1
        fi
        if [[ -n ${M_APPUP[i]} ]]; then
            ask "  Uruchomić aktualizację aplikacji z apps.conf ($(tr '\n' ' ' <<<"${M_APPUP[i]}"))?" && apps_ok=1
        fi
    fi

    if [[ $kind != host ]] && (( SNAPSHOT )); then
        if make_snapshot "$kind" "$id"; then
            snap=$SNAP_NAME; echo "  snapshot: $snap"
        elif [[ -n $BACKUP_STORAGE ]] && make_backup "$kind" "$id"; then
            kopia=$BACKUP_VOL; echo "  snapshot niemożliwy – zrobiona kopia: $kopia"
        elif (( REQUIRE_SNAPSHOT )); then
            local why="snapshot się nie udał"; [[ -n $BACKUP_STORAGE ]] && why+=" i kopia vzdump też"
            echo "  ! $why – pomijam (REQUIRE_SNAPSHOT=1)"
            UP_FAIL+=("$label: $why, nic nie zmieniono")
            up_res "$kind" "$id" "$label" blad "" "$why, nic nie zmieniono"; return
        else
            echo "  ! snapshot się nie udał – aktualizuję bez snapshotu (REQUIRE_SNAPSHOT=0)"
        fi
    fi

    [[ $SCOPE == pakiety ]] && { nc_srv=0; apps_ok=0; }
    UP_IDS+=("$id")
    up_pct 150; up_state trwa "$label"
    echo "===== $label – $(date '+%F %T')${snap:+ – snapshot $snap}${kopia:+ – kopia $kopia} =====" >>"$UP_LOG"
    local pkg=1 nc_apps=$NC_APPS_UPGRADE
    [[ $SCOPE == aplikacje ]] && pkg=0
    [[ $SCOPE == pakiety ]] && nc_apps=0
    tmp=$(mktemp)
    # wyjście idzie na żywo do logu (mNas pokazuje jego koniec) i do $tmp (znaczniki PUC_*);
    # po drodze liczymy postęp z etapów i linii apt
    local npk=$(( ${M_PKG[i]} > 0 ? ${M_PKG[i]} : 1 ))
    # sed wycina sekwencje sterujące terminala (updater.phar rysuje nimi paski 0–100%)
    run_up "$kind" "$id" "PUC_PKG=$pkg; PUC_NC_APPS=$nc_apps; PUC_NC_SERVER=$nc_srv"$'\n'"$GUEST_UPGRADE" |
        sed -u -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r//g' |
        follow_progress "$label" "$tmp" "$npk"
    rc=${PIPESTATUS[0]}
    up_pct 900    # follow_progress liczył w podpowłoce – tu wyrównujemy

    if (( apps_ok )); then
        while IFS= read -r aname; do
            [[ -z $aname ]] && continue
            cmd=$(app_upgrade_cmd "$id" "$aname")
            echo "  aplikacja $aname: $cmd"
            echo "--- apps.conf: $aname: $cmd" >>"$UP_LOG"
            run_up "$kind" "$id" "$cmd" >>"$UP_LOG" 2>&1 || app_fail+=" $aname"
        done <<<"${M_APPUP[i]}"
    fi

    prc=$(grep -oE 'PUC_PKG_RC=[0-9]' "$tmp" | tail -n1 | cut -d= -f2)
    (( rc == 124 )) && problems+=" przekroczony czas;"
    [[ $prc != 0 ]] && problems+=" pakiety;"
    grep -q 'PUC_NC_RC=1' "$tmp" && problems+=" Nextcloud;"
    [[ -n $app_fail ]] && problems+=" aplikacje:$app_fail;"

    # weryfikacja przed sprzątaniem coś wykryła: ostrzeżenie w wyniku, lista do ręcznego
    # skasowania (pve-update-check -c ID) – kasuje tylko to, co tu zapisane
    local uwagi="" dosk="" US=$'\x1f' l
    while IFS= read -r l; do uwagi+="${l#PUC_UWAGA }$US"; done < <(grep '^PUC_UWAGA ' "$tmp")
    grep '^PUC_DO_SKASOWANIA ' "$tmp" | cut -d' ' -f2- >"$STATE_DIR/sprzatanie-$id.tmp"
    if [[ -s $STATE_DIR/sprzatanie-$id.tmp ]]; then
        mv "$STATE_DIR/sprzatanie-$id.tmp" "$STATE_DIR/sprzatanie-$id"
        while IFS= read -r l; do dosk+="$l$US"; done <"$STATE_DIR/sprzatanie-$id"
        echo "  ! weryfikacja przed sprzątaniem: ${uwagi//$US/ } – do ręcznego skasowania: pve-update-check -c $id"
    else
        unlink "$STATE_DIR/sprzatanie-$id.tmp"
    fi

    local reboot=0
    grep -q 'PUC_REBOOT=1' "$tmp" && reboot=1
    if [[ $kind == host ]]; then
        local newest; newest=$(boot_kernel)
        [[ -n $newest && $newest != "$(uname -r)" ]] && reboot=1
    fi
    rm -f "$tmp"

    if [[ -n $problems ]]; then
        echo "  ! BŁĄD:$problems szczegóły w $UP_LOG"
        UP_FAIL+=("$label – błąd:$problems${snap:+ cofnięcie: pve-update-check -r $id}${kopia:+ cofnięcie z kopii: pve-update-check -r $id}")
        up_res "$kind" "$id" "$label" blad "$snap" "${problems# }" "$kopia" "$uwagi" "$dosk"
    else
        echo "  OK"
        UP_DONE+=("$label${snap:+ (snapshot $snap)}${kopia:+ (kopia $kopia)}${uwagi:+ – UWAGA: ${uwagi//$US/ }}")
        up_res "$kind" "$id" "$label" ok "$snap" "" "$kopia" "$uwagi" "$dosk"
    fi

    if (( reboot )); then
        if [[ $kind == ct ]] && (( ! ASSUME_YES )) && ask "  Kontener wymaga restartu. Zrestartować teraz?"; then
            pct reboot "$id" && echo "  zrestartowano"
        else
            UP_REBOOT+=("$label")
        fi
    fi
}

do_upgrades() {
    local i order=()
    if (( ${#M_ID[@]} == 0 )); then
        echo; echo "Nie ma czego aktualizować."
        up_state nic "Nie ma czego aktualizować."
        return
    fi
    if (( ! ASSUME_YES )) && ! { : </dev/tty; } 2>/dev/null; then
        echo "Brak terminala do pytań – uruchom ręcznie albo z -y (wtedy tylko AUTO_UPGRADE_*)." >&2
        exit 1
    fi
    mkdir -p "$LOG_DIR"
    UP_N=${#M_ID[@]}; up_state trwa "start"
    echo
    echo "===== Instalowanie aktualizacji (pełny log: $UP_LOG) ====="
    for i in "${!M_ID[@]}"; do [[ ${M_KIND[i]} != host ]] && order+=("$i"); done
    for i in "${!M_ID[@]}"; do [[ ${M_KIND[i]} == host ]] && order+=("$i"); done
    for i in "${order[@]}"; do upgrade_one "$i"; UP_IDX=$((UP_IDX + 1)); up_pct 0; done
    up_state trwa "sprawdzanie po aktualizacji"

    local x
    (( ${#UP_DONE[@]} ))   && { UP_SUMMARY+="Zaktualizowano:"$'\n'; for x in "${UP_DONE[@]}"; do UP_SUMMARY+="• $x"$'\n'; done; }
    (( ${#UP_FAIL[@]} ))   && { UP_SUMMARY+="Błędy:"$'\n'; for x in "${UP_FAIL[@]}"; do UP_SUMMARY+="• $x"$'\n'; done; }
    (( ${#UP_SKIP[@]} ))   && UP_SUMMARY+="Pominięte: ${UP_SKIP[*]}"$'\n'
    (( ${#UP_REBOOT[@]} )) && UP_SUMMARY+="Wymagają restartu: ${UP_REBOOT[*]}"$'\n'
    UP_SUMMARY+="Log: $UP_LOG"
    echo; echo "===== Podsumowanie ====="; echo "$UP_SUMMARY"

    # ponowne sprawdzenie zaktualizowanych maszyn, żeby stan.json pokazywał stan po aktualizacji
    for x in "${UP_IDS[@]}"; do
        PUC_NOLOCK=1 bash "$0" -n -t "$x" >/dev/null 2>&1
    done
    if (( ${#UP_FAIL[@]} )); then up_state bledy "$UP_SUMMARY"
    elif (( ${#UP_DONE[@]} )); then up_state ok "$UP_SUMMARY"
    else up_state nic "$UP_SUMMARY"; fi
}

# ---------- cofnięcie (-r ID) ----------
# Ostatni snapshot puc_ (pct/qm rollback) albo ostatnia własna kopia vzdump z
# $STATE_DIR/kopie (pct restore na ten sam storage). Kontener/VM wraca do stanu
# sprzed aktualizacji; jeśli działał – zostaje uruchomiony ponownie.
do_rollback() {
    local id=$1 kind tool snap="" vol="" was_running=0 st rc=0 a storage label
    if pct config "$id" >/dev/null 2>&1; then kind=ct tool=pct
    elif qm config "$id" >/dev/null 2>&1; then kind=vm tool=qm
    else echo "Nie ma CT/VM $id." >&2; return 2; fi
    label="$([[ $kind == ct ]] && echo CT || echo VM) $id"
    snap=$($tool listsnapshot "$id" 2>/dev/null | grep -oE 'puc_[0-9]{8}_[0-9]{6}' | sort -u | tail -n1)
    [[ -z $snap && -f $STATE_DIR/kopie ]] && vol=$(awk -v k="$kind" -v i="$id" '$1 == k && $2 == i { v = $3 } END { print v }' "$STATE_DIR/kopie")
    # lista `kopie` pamięta kopię także po skasowaniu jej pliku (ręcznie albo przez BACKUP_KEEP)
    if [[ -n $vol ]]; then local p; p=$(pvesm path "$vol" 2>/dev/null); [[ -n $p && -e $p ]] || vol=""; fi
    if [[ -z $snap && -z $vol ]]; then echo "Brak snapshotu puc_ i kopii dla $label – nie ma do czego wrócić." >&2; return 1; fi
    if [[ -n $vol && $kind == vm ]]; then
        echo "Cofnięcie VM z kopii rób ręcznie: qmrestore $vol $id --force" >&2; return 1
    fi
    if [[ -n $vol ]]; then
        storage=$(pct config "$id" | awk -F'[ :]+' '/^rootfs:/ { print $2 }')
        if pct config "$id" | grep -qE '^mp[0-9]+: [^/]'; then
            echo "$label ma dodatkowe woluminy – cofnij ręcznie: pct restore $id $vol --force" >&2; return 1
        fi
    fi
    if [[ -n $snap ]]; then echo "$label: powrót do snapshotu $snap"
    else echo "$label: przywrócenie z kopii $vol (storage $storage) – wszystko po kopii przepadnie"; fi
    (( NOTIFY )) || { echo "(-n: tylko podgląd, nic nie zmieniono)"; return 0; }
    if (( ! ASSUME_YES )); then
        read -r -p "Wpisz TAK, aby cofnąć: " a </dev/tty || return 1
        [[ $a == TAK ]] || { echo "Przerwano."; return 1; }
    fi
    mkdir -p "$LOG_DIR"
    UP_LOG="$LOG_DIR/cofniecie-$(date +%Y%m%d-%H%M%S).log"
    ONLY=$id SCOPE=cofniecie
    up_state trwa "$label: cofanie"
    st=$($tool status "$id" 2>/dev/null | awk '{ print $2 }'); [[ $st == running ]] && was_running=1
    {
        if [[ -n $snap ]]; then
            [[ $kind == ct ]] && (( was_running )) && pct stop "$id"
            $tool rollback "$id" "$snap" || rc=1
        else
            (( was_running )) && pct stop "$id"
            pct restore "$id" "$vol" --force --storage "$storage" || rc=1
        fi
        if (( rc == 0 && was_running )) && [[ $($tool status "$id" | awk '{ print $2 }') != running ]]; then
            $tool start "$id" || rc=1
        fi
    } >>"$UP_LOG" 2>&1
    if (( rc == 0 )); then
        up_res "$kind" "$id" "$label" ok "$snap" "" "$vol"
        up_state ok "Cofnięto $label${snap:+ do snapshotu $snap}${vol:+ z kopii $vol}. Log: $UP_LOG"
        echo "Cofnięto. Log: $UP_LOG"
    else
        up_res "$kind" "$id" "$label" blad "$snap" "cofnięcie nie wyszło" "$vol"
        up_state bledy "Cofnięcie $label nie wyszło – szczegóły w $UP_LOG"
        echo "Cofnięcie nie wyszło – szczegóły w $UP_LOG" >&2
    fi
    PUC_NOLOCK=1 bash "$0" -n -t "$id" >/dev/null 2>&1
    return $rc
}

# ---------- ręczne sprzątanie (-c ID) ----------
# Kasuje to, czego aktualizacja nie skasowała sama, bo weryfikacja coś wykryła – i tylko to,
# co zapisała w $STATE_DIR/sprzatanie-<ID>. Każda pozycja jest sprawdzana jeszcze raz.
do_cleanup() {
    local id=$1 list=$STATE_DIR/sprzatanie-$1 l what path a mb rc=0 label done_txt=""
    label="CT $id"
    [[ -f $list ]] || { echo "Dla $label nie ma nic do ręcznego sprzątania." >&2; return 1; }
    pct config "$id" >/dev/null 2>&1 || { echo "Nie ma CT $id." >&2; return 2; }
    local ok=() opis=()
    while IFS= read -r l; do
        what=${l%% *}; path=${l#* }
        case $what in
            apt) ok+=("apt"); opis+=("pobrane pakiety apt (/var/cache/apt)") ;;
            nc)
                if [[ $path =~ ^/[A-Za-z0-9/_.-]+/updater-[A-Za-z0-9]+/backups/nextcloud-[0-9][0-9.]*-[0-9]+$ && $path != *..* ]]; then
                    mb=$(pct exec "$id" -- du -sm "$path" 2>/dev/null | awk '{ print $1 }')
                    ok+=("nc $path"); opis+=("kopia updatera Nextclouda ${path##*/} (${mb:-?} MB)")
                else
                    echo "Pomijam podejrzaną pozycję: $l" >&2
                fi ;;
            *) echo "Pomijam nieznaną pozycję: $l" >&2 ;;
        esac
    done <"$list"
    (( ${#ok[@]} )) || { echo "Nic poprawnego do skasowania." >&2; return 1; }
    echo "$label – do skasowania:"; printf '  - %s\n' "${opis[@]}"
    (( NOTIFY )) || { echo "(-n: tylko podgląd, nic nie zmieniono)"; return 0; }
    if (( ! ASSUME_YES )); then
        read -r -p "Wpisz TAK, aby skasować: " a </dev/tty || return 1
        [[ $a == TAK ]] || { echo "Przerwano."; return 1; }
    fi
    mkdir -p "$LOG_DIR"
    UP_LOG="$LOG_DIR/sprzatanie-$(date +%Y%m%d-%H%M%S).log"
    ONLY=$id SCOPE=sprzatanie
    up_state trwa "$label: ręczne sprzątanie"
    for l in "${ok[@]}"; do
        if [[ $l == apt ]]; then
            pct exec "$id" -- apt-get clean >>"$UP_LOG" 2>&1 && done_txt+="apt-get clean; " || rc=1
        else
            path=${l#nc }
            pct exec "$id" -- rm -r -- "$path" >>"$UP_LOG" 2>&1 && done_txt+="usunięto ${path##*/}; " || rc=1
        fi
    done
    if (( rc == 0 )); then
        unlink "$list"
        up_res ct "$id" "$label" ok "" "" ""
        up_state ok "Wyczyszczono $label: ${done_txt%; }. Log: $UP_LOG"
        echo "Wyczyszczono: ${done_txt%; }"
    else
        up_res ct "$id" "$label" blad "" "sprzątanie nie wyszło w całości" ""
        up_state bledy "Sprzątanie $label nie wyszło w całości – szczegóły w $UP_LOG"
        echo "Sprzątanie nie wyszło w całości – $UP_LOG" >&2
    fi
    return $rc
}

# ---------- ponowne uruchomienie usług (-R ID) i kontenera (-B ID) ----------
# Jednostki, których nie restartujemy pojedynczo – wymagają restartu całego kontenera.
PUC_SVC_KONTENER='^(dbus\.service|dbus-broker\.service|init\.scope|systemd-.*|user@.*|-\.slice)$'

svc_scan() {    # svc_scan <CT> – świeża lista jednostek ze starymi bibliotekami
    pct exec "$1" -- sh -c '
myns=$(readlink /proc/self/ns/pid 2>/dev/null)
for p in /proc/[0-9]*; do
    [ "$(readlink "$p/ns/pid" 2>/dev/null)" = "$myns" ] || continue
    grep -qE "\.so[.0-9]* \(deleted\)$" "$p/maps" 2>/dev/null || continue
    sed -n "s|^0::/\(.*\)$|\1|p" "$p/cgroup" 2>/dev/null | awk -F/ "{ print \$NF }"
done | sort -u' 2>/dev/null
}

do_restart_services() {
    local id=$1 u ok=() rc=0 label="CT $1" done_txt=""
    pct config "$id" >/dev/null 2>&1 || { echo "Nie ma CT $id." >&2; return 2; }
    [[ $(pct status "$id" | awk '{ print $2 }') == running ]] || { echo "$label nie działa." >&2; return 1; }
    while IFS= read -r u; do
        [[ -n $u && $u =~ ^[A-Za-z0-9@:._-]+\.service$ ]] || continue
        [[ $u =~ $PUC_SVC_KONTENER ]] && continue
        ok+=("$u")
    done < <(svc_scan "$id")
    (( ${#ok[@]} )) || { echo "$label: żadna usługa nie wymaga ponownego uruchomienia (poza ewentualnie dbus/systemd – to -B)."; return 0; }
    echo "$label – ponowne uruchomienie: ${ok[*]}"
    (( NOTIFY )) || { echo "(-n: tylko podgląd, nic nie zmieniono)"; return 0; }
    if (( ! ASSUME_YES )); then
        read -r -p "Wpisz TAK, aby uruchomić ponownie: " a </dev/tty || return 1
        [[ $a == TAK ]] || { echo "Przerwano."; return 1; }
    fi
    mkdir -p "$LOG_DIR"; UP_LOG="$LOG_DIR/restart-$(date +%Y%m%d-%H%M%S).log"
    ONLY=$id SCOPE=restart
    up_state trwa "$label: ponowne uruchomienie usług"
    for u in "${ok[@]}"; do
        if pct exec "$id" -- systemctl restart "$u" >>"$UP_LOG" 2>&1 && \
           [[ $(pct exec "$id" -- systemctl is-active "$u" 2>/dev/null) == active ]]; then
            done_txt+="$u; "
        else
            rc=1; echo "nie wstała: $u" >>"$UP_LOG"
        fi
    done
    PUC_NOLOCK=1 bash "$0" -n -t "$id" >/dev/null 2>&1
    if (( rc == 0 )); then
        up_res ct "$id" "$label" ok "" "" ""
        up_state ok "Uruchomiono ponownie w $label: ${done_txt%; }. Log: $UP_LOG"
        echo "OK: ${done_txt%; }"
    else
        up_res ct "$id" "$label" blad "" "nie każda usługa wstała" ""
        up_state bledy "W $label nie każda usługa wstała po restarcie – szczegóły w $UP_LOG"
        echo "Nie każda usługa wstała – $UP_LOG" >&2
    fi
    return $rc
}

do_reboot_ct() {
    local id=$1 rc=0 label="CT $1" i
    pct config "$id" >/dev/null 2>&1 || { echo "Nie ma CT $id." >&2; return 2; }
    [[ $(pct status "$id" | awk '{ print $2 }') == running ]] || { echo "$label nie działa." >&2; return 1; }
    # nie w trakcie kopii zapasowej – restart przerwałby vzdump/PBS
    if pgrep -x vzdump >/dev/null || pgrep -f "proxmox-backup-client" >/dev/null; then
        echo "Trwa kopia zapasowa – $label uruchom ponownie później." >&2; return 1
    fi
    echo "$label: ponowne uruchomienie całego kontenera (usługi w nim na chwilę znikną)"
    (( NOTIFY )) || { echo "(-n: tylko podgląd, nic nie zmieniono)"; return 0; }
    if (( ! ASSUME_YES )); then
        read -r -p "Wpisz TAK, aby uruchomić ponownie: " a </dev/tty || return 1
        [[ $a == TAK ]] || { echo "Przerwano."; return 1; }
    fi
    mkdir -p "$LOG_DIR"; UP_LOG="$LOG_DIR/restart-$(date +%Y%m%d-%H%M%S).log"
    ONLY=$id SCOPE=restart
    up_state trwa "$label: ponowne uruchomienie kontenera"
    pct reboot "$id" >>"$UP_LOG" 2>&1 || rc=1
    for i in $(seq 1 60); do
        [[ $(pct status "$id" | awk '{ print $2 }') == running ]] && pct exec "$id" -- true 2>/dev/null && break
        sleep 2
    done
    [[ $(pct status "$id" | awk '{ print $2 }') == running ]] || rc=1
    sleep 5
    local failed; failed=$(pct exec "$id" -- systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | tr '\n' ' ')
    echo "po restarcie failed: ${failed:-brak}" >>"$UP_LOG"
    PUC_NOLOCK=1 bash "$0" -n -t "$id" >/dev/null 2>&1
    if (( rc == 0 )); then
        up_res ct "$id" "$label" ok "" "${failed:+jednostki failed: $failed}" ""
        up_state ok "Uruchomiono ponownie $label${failed:+ (failed: $failed)}. Log: $UP_LOG"
        echo "OK${failed:+ – failed: $failed}"
    else
        up_res ct "$id" "$label" blad "" "kontener nie wstał" ""
        up_state bledy "$label nie wstał po restarcie – szczegóły w $UP_LOG"
        echo "$label nie wstał – $UP_LOG" >&2
    fi
    return $rc
}

# ---------- restart hosta (-H) ----------
# Przez SSH/roota, nie przez API (token mNas nie ma Sys.PowerMgmt). Przy nowym jądrze:
# bez modułów DKMS dla niego nie ruszamy (karta sieciowa r8152), przy przypiętym jądrze
# ustawiamy jednorazowy start na nowym – po udanym starcie przypnie je pve-update-check.
do_reboot_host() {
    local run new pinned
    run=$(uname -r); new=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1)
    if pgrep -x vzdump >/dev/null || pgrep -f proxmox-backup-client >/dev/null; then
        echo "Trwa kopia zapasowa – restart hosta później." >&2; return 1
    fi
    for u in pve-update-check.service pve-update-check-upgrade.service; do
        systemctl is-active --quiet "$u" && { echo "Trwa $u – restart hosta później." >&2; return 1; }
    done
    if [[ -n $new && $new != "$run" ]]; then
        if [[ $(dkms_ready_u "$new") != 1 ]]; then
            echo "Moduły DKMS (sterownik karty sieciowej) nie są zbudowane dla $new – host mógłby wstać bez sieci. Nie restartuję." >&2
            return 1
        fi
        echo "Host wstanie na nowym jądrze $new (teraz $run)."
    else
        echo "Host wstanie na tym samym jądrze $run."
    fi
    (( NOTIFY )) || { echo "(-n: tylko podgląd, nic nie zmieniono)"; return 0; }
    if (( ! ASSUME_YES )); then
        read -r -p "Wpisz TAK, aby uruchomić ponownie host: " a </dev/tty || return 1
        [[ $a == TAK ]] || { echo "Przerwano."; return 1; }
    fi
    mkdir -p "$LOG_DIR" "$STATE_DIR"; UP_LOG="$LOG_DIR/restart-hosta-$(date +%Y%m%d-%H%M%S).log"
    ONLY=host SCOPE=restart
    pinned=$( [[ -s /etc/kernel/proxmox-boot-pin ]] && head -n1 /etc/kernel/proxmox-boot-pin )
    if [[ -n $new && $new != "$run" && -n $pinned && $pinned != "$new" ]]; then
        proxmox-boot-tool kernel pin "$new" --next-boot >>"$UP_LOG" 2>&1 || { echo "Nie udało się ustawić startu na $new." >&2; return 1; }
        echo "$new" >"$STATE_DIR/pin-po-starcie"
        echo "jednorazowy start: $new (przypięte na stałe: $pinned)" >>"$UP_LOG"
    fi
    up_res host host "Host $(hostname)" ok "" "" ""
    up_state ok "Restart hosta zlecony $(date '+%H:%M')${new:+ – wstanie $([[ $new != "$run" ]] && echo "nowe jądro $new" || echo "jądro $run")}. Serwer wróci za 2–3 min."
    systemd-run --on-active=5 --unit=pve-update-check-restart-hosta --collect systemctl reboot >>"$UP_LOG" 2>&1
    echo "Restart za 5 s."
}

dkms_ready_u() {
    local k=$1 m
    command -v dkms >/dev/null || { echo 1; return; }
    for m in $(dkms status 2>/dev/null | awk -F'[,:]' -v r="$(uname -r)" '$0 ~ "installed" && $2 ~ r { gsub(/ /, "", $1); print $1 }' | sort -u); do
        dkms status 2>/dev/null | grep -F "$m" | grep -F "$k" | grep -q installed || { echo 0; return; }
    done
    echo 1
}
