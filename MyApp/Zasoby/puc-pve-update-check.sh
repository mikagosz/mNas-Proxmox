#!/usr/bin/env bash
# pve-update-check – sprawdza dostępne aktualizacje na hoście Proxmox VE,
# w uruchomionych kontenerach LXC (opcjonalnie też w VM z qemu-guest-agent)
# oraz aplikacji w nich (wtyczki checks.d + apps.conf). NICZEGO NIE AKTUALIZUJE,
# tylko zbiera raport i wysyła powiadomienie (ntfy / Telegram / e-mail).
#
# Użycie (jako root na hoście PVE):
#   pve-update-check              sprawdź wszystko i wyślij powiadomienie (jeśli jest o czym)
#   pve-update-check -n           tylko wypisz raport, bez powiadomień
#   pve-update-check -f           wyślij powiadomienie nawet gdy wszystko aktualne (test)
#   pve-update-check -t 101       sprawdź tylko kontener/VM 101 ("-t host" = tylko host)
#   pve-update-check -u           sprawdź, a potem ZAINSTALUJ aktualizacje (pyta o każdą maszynę,
#                                 przed aktualizacją CT/VM robi snapshot)
#   pve-update-check -u -y        bez pytań: tylko maszyny z AUTO_UPGRADE_IDS (np. z timera)
#   pve-update-check -u -y -t 101 bez pytań zaktualizuj tylko 101 (razem z apps.conf)
#        -o pakiety|aplikacje     przy -u: tylko pakiety systemu / tylko aplikacje (Nextcloud, apps.conf)
#        -S                       przy -u: zaktualizuj też serwer Nextclouda (updater.phar)
#   pve-update-check -r 101       cofnij ostatnią aktualizację CT/VM 101 (snapshot puc_ albo kopia vzdump);
#                                 pyta o zgodę, z -y bez pytania, z -n tylko pokazuje, co by zrobił
#   pve-update-check -c 101       skasuj ręcznie to, czego aktualizacja nie posprzątała, bo weryfikacja
#                                 coś wykryła (stare kopie updatera Nextclouda, pakiety apt); -n / -y jak przy -r
#   pve-update-check -R 101       uruchom ponownie usługi CT 101, które trzymają w pamięci podmienione biblioteki
#   pve-update-check -B 101       uruchom ponownie cały kontener 101 (dbus, systemd albo /var/run/reboot-required)
#   pve-update-check -H           uruchom ponownie host PVE; przy nowym jądrze najpierw sprawdza DKMS i ustawia
#                                 jednorazowy start na nim (pin --next-boot), po udanym starcie przypina je na stałe
# Stan dla innych programów (np. mNas): /var/lib/pve-update-check/stan.json i aktualizacja.json
#
# Pliki:
#   /etc/pve-update-check/config        ustawienia (powiadomienia, wykluczenia…)
#   /etc/pve-update-check/checks.d/*.sh wtyczki uruchamiane w każdym hoście/kontenerze/VM
#   /etc/pve-update-check/apps.conf     aplikacje sprawdzane wg wersji (np. z GitHub Releases)

set -uo pipefail
VERSION=2.8

# ---------- ustawienia domyślne (nadpisywane przez plik konfiguracyjny) ----------
ETC=${PUC_ETC:-/etc/pve-update-check}
CHECK_HOST=1            # sprawdzaj host PVE
CHECK_CT=1              # sprawdzaj kontenery LXC
CHECK_VM=0              # sprawdzaj VM (wymaga qemu-guest-agent w VM, tylko Linux)
EXCLUDE_IDS=""          # ID do pominięcia, np. "105 110"
TIMEOUT=300             # limit czasu na jedną maszynę (s)
MAX_LIST=25             # ile pakietów maks. wypisać na maszynę
NOTIFY_ALWAYS=0         # 1 = powiadamiaj także gdy wszystko aktualne
LOG_DIR=/var/log/pve-update-check
STATE_DIR=/var/lib/pve-update-check   # stan.json / aktualizacja.json dla innych programów
MIN_FREE_MB=1024        # mniej wolnego miejsca na / maszyny = błąd w raporcie

NTFY_URL=""             # np. https://ntfy.sh/moj-tajny-temat
NTFY_TOKEN=""           # opcjonalny token (Bearer)
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
MAIL_TO=""              # np. ja@example.com (wysyłka przez lokalny sendmail/postfix)
GITHUB_TOKEN=""         # opcjonalnie, podnosi limit zapytań do GitHub API

# --- instalowanie aktualizacji (tryb -u) ---
SNAPSHOT=1              # snapshot CT/VM przed aktualizacją
REQUIRE_SNAPSHOT=1      # 1 = nie aktualizuj CT/VM, jeśli snapshot się nie udał
SNAPSHOT_KEEP=3         # ile snapshotów "puc_" trzymać na maszynę (starsze usuwa)
BACKUP_STORAGE=""       # gdy snapshot niemożliwy (storage "dir"): kopia vzdump na ten storage, np. "local"
BACKUP_KEEP=1           # ile takich kopii trzymać na maszynę (starsze usuwa – tylko własne)
NC_MIN_FREE_MB=2048     # serwer Nextclouda: bez tylu MB wolnego miejsca updater nie rusza
UPGRADE_TIMEOUT=3600    # limit czasu aktualizacji jednej maszyny (s)
NC_APPS_UPGRADE=1       # aktualizuj aplikacje Nextclouda (occ app:update --all)
NC_SERVER_UPGRADE=0     # serwer Nextclouda (updater.phar): 0 = nigdy, 1 = tak (w trybie -u pyta)
AUTO_UPGRADE_IDS=""     # dla -y: które maszyny wolno aktualizować bez pytania, np. "101 102" albo "all"
AUTO_UPGRADE_HOST=0     # dla -y: czy wolno aktualizować sam host PVE
AUTO_UPGRADE_APPS=0     # dla -y: czy wolno uruchamiać komendy aktualizacji z apps.conf

# shellcheck source=/dev/null
[[ -f $ETC/config ]] && . "$ETC/config"

NOTIFY=1 ONLY="" UPGRADE=0 ASSUME_YES=0 SCOPE=wszystko FORCE_NC_SERVER=0 ROLLBACK="" CLEANUP="" RESTART_SVC="" REBOOT_CT="" REBOOT_HOST=0
while getopts "nft:uyo:Sr:c:R:B:Hvh" opt; do
    case $opt in
        n) NOTIFY=0 ;;
        f) NOTIFY_ALWAYS=1 ;;
        t) ONLY=$OPTARG ;;
        u) UPGRADE=1 ;;
        y) ASSUME_YES=1 ;;
        o) SCOPE=$OPTARG ;;
        S) FORCE_NC_SERVER=1 ;;
        r) ROLLBACK=$OPTARG ;;
        c) CLEANUP=$OPTARG ;;
        R) RESTART_SVC=$OPTARG ;;
        B) REBOOT_CT=$OPTARG ;;
        H) REBOOT_HOST=1 ;;
        v) echo "pve-update-check $VERSION"; exit 0 ;;
        *) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

case $SCOPE in wszystko|pakiety|aplikacje) ;; *) echo "Nieznany zakres -o $SCOPE (wszystko|pakiety|aplikacje)" >&2; exit 2 ;; esac
(( FORCE_NC_SERVER )) && NC_SERVER_UPGRADE=1
if [[ -n $ONLY && ! $ONLY =~ ^([0-9]+|host)$ ]]; then echo "Złe -t $ONLY (numer CT/VM albo host)" >&2; exit 2; fi
if [[ -n $ROLLBACK && ! $ROLLBACK =~ ^[0-9]+$ ]]; then echo "Złe -r $ROLLBACK (numer CT/VM)" >&2; exit 2; fi
if [[ -n $CLEANUP && ! $CLEANUP =~ ^[0-9]+$ ]]; then echo "Złe -c $CLEANUP (numer CT)" >&2; exit 2; fi
if [[ -n $RESTART_SVC && ! $RESTART_SVC =~ ^[0-9]+$ ]]; then echo "Złe -R $RESTART_SVC (numer CT)" >&2; exit 2; fi
if [[ -n $REBOOT_CT && ! $REBOOT_CT =~ ^[0-9]+$ ]]; then echo "Złe -B $REBOOT_CT (numer CT)" >&2; exit 2; fi

if [[ $EUID -ne 0 ]]; then
    echo "Uruchom jako root na hoście Proxmox." >&2
    exit 2
fi

# tylko jedno uruchomienie naraz (sprawdzanie z timera vs ręczna aktualizacja)
if [[ -z ${PUC_NOLOCK:-} ]]; then
    exec 9>/run/pve-update-check.lock
    flock -n 9 || { echo "pve-update-check już działa (inna instancja)." >&2; exit 1; }
fi

# ---------- jądro po restarcie hosta ----------
# -H ustawił jednorazowy start na nowym jądrze i zostawił jego nazwę w pin-po-starcie.
# Skoro to się wykonuje, host wstał i ma sieć (timer OnBootSec / mNas po SSH) — wtedy
# przypinamy to jądro na stałe. Jeśli wstało inne (zapasowe), zostaje ślad do raportu.
if [[ -s ${STATE_DIR:-/var/lib/pve-update-check}/pin-po-starcie ]] && command -v proxmox-boot-tool >/dev/null; then
    puc_cel=$(head -n1 "$STATE_DIR/pin-po-starcie")
    mkdir -p "$LOG_DIR"
    if [[ $(uname -r) == "$puc_cel" ]]; then
        proxmox-boot-tool kernel pin "$puc_cel" >/dev/null 2>&1 \
            && echo "$(date -Iseconds) przypięto na stałe $puc_cel" >>"$LOG_DIR/jadro.log"
        unlink "$STATE_DIR/pin-po-starcie"
        [[ -e $STATE_DIR/jadro-nie-wstalo ]] && unlink "$STATE_DIR/jadro-nie-wstalo"
    elif [[ /proc/1 -nt $STATE_DIR/pin-po-starcie ]]; then
        # host wstał od tamtej pory, ale na innym jądrze
        echo "$puc_cel" >"$STATE_DIR/jadro-nie-wstalo"
        echo "$(date -Iseconds) $puc_cel nie wstało, działa $(uname -r)" >>"$LOG_DIR/jadro.log"
        unlink "$STATE_DIR/pin-po-starcie"
    fi
fi
if (( REBOOT_HOST )); then
    # shellcheck source=/dev/null
    . "${PUC_LIB:-/usr/local/lib/pve-update-check}/upgrade.sh"
    do_reboot_host
    exit $?
fi

# ---------- cofnięcie ostatniej aktualizacji (-r ID) ----------
if [[ -n $ROLLBACK ]]; then
    # shellcheck source=/dev/null
    . "${PUC_LIB:-/usr/local/lib/pve-update-check}/upgrade.sh"
    do_rollback "$ROLLBACK"
    exit $?
fi
if [[ -n $CLEANUP ]]; then
    # shellcheck source=/dev/null
    . "${PUC_LIB:-/usr/local/lib/pve-update-check}/upgrade.sh"
    do_cleanup "$CLEANUP"
    exit $?
fi
if [[ -n $RESTART_SVC || -n $REBOOT_CT ]]; then
    # shellcheck source=/dev/null
    . "${PUC_LIB:-/usr/local/lib/pve-update-check}/upgrade.sh"
    if [[ -n $RESTART_SVC ]]; then do_restart_services "$RESTART_SVC"; else do_reboot_ct "$REBOOT_CT"; fi
    exit $?
fi

# ---------- skrypt uruchamiany WEWNĄTRZ hosta/kontenera/VM (POSIX sh) ----------
# Protokół (linie na stdout):
#   OS <nazwa systemu>                  PKG <pakiet> <stara> <nowa> <bezp 0/1>
#   UPD <tekst>   aktualizacja aplikacji (liczona w podsumowaniu)
#   APP <tekst>   informacja o aplikacji (np. zainstalowana wersja, "aktualne")
#   REBOOT        potrzebny restart       INFO <tekst>       ERR <tekst>
#   FREE <MB>     wolne miejsce na /
#   SVC <jednostka>  usługa, której procesy mają w pamięci podmienione (skasowane) biblioteki
GUEST_BASE=$(cat <<'EOF'
export LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [ -r /etc/os-release ]; then . /etc/os-release; echo "OS ${PRETTY_NAME:-$ID}"; fi

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || echo "ERR apt-get update nie powiodlo sie (blokada apt / brak sieci / zle repo?)"
    apt list --upgradable 2>/dev/null | awk '
        /\[upgradable from:/ {
            split($1, a, "/"); old = $NF; sub(/\]$/, "", old)
            print "PKG", a[1], old, $2, (a[2] ~ /security/ ? 1 : 0)
        }'
elif command -v apk >/dev/null 2>&1; then
    apk update -q >/dev/null 2>&1 || echo "ERR apk update nie powiodlo sie"
    apk version -l '<' 2>/dev/null | awk 'NR > 1 && $2 == "<" { print "PKG", $1, "-", $3, 0 }'
elif command -v dnf >/dev/null 2>&1; then
    dnf -q check-update 2>/dev/null | awk 'NF == 3 && $1 ~ /\./ { print "PKG", $1, "-", $2, 0 }'
elif command -v checkupdates >/dev/null 2>&1; then
    checkupdates 2>/dev/null | awk '{ print "PKG", $1, $2, $4, 0 }'
else
    echo "ERR nieobslugiwany menedzer pakietow"
fi

[ -f /var/run/reboot-required ] && echo "REBOOT"
free=$(df -Pm / 2>/dev/null | awk 'NR == 2 { print $4 }')
[ -n "$free" ] && echo "FREE $free"
# Usługi ze starymi bibliotekami w pamięci (po aktualizacji pakietu, przed restartem usługi).
# Tylko procesy z tej samej przestrzeni PID – na hoście inaczej wyszłyby procesy kontenerów.
myns=$(readlink /proc/self/ns/pid 2>/dev/null)
for p in /proc/[0-9]*; do
    [ "$(readlink "$p/ns/pid" 2>/dev/null)" = "$myns" ] || continue
    grep -qE '\.so[.0-9]* \(deleted\)$' "$p/maps" 2>/dev/null || continue
    u=$(sed -n 's|^0::/\(.*\)$|\1|p' "$p/cgroup" 2>/dev/null | awk -F/ '{ print $NF }')
    [ -n "$u" ] && echo "SVC $u"
done | sort -u
EOF
)

# Doklejenie wtyczek z checks.d – każda w osobnej podpowłoce, żeby "exit" w niej
# nie przerwał pozostałych.
GUEST_SCRIPT=$GUEST_BASE
for plugin in "$ETC"/checks.d/*.sh; do
    [[ -f $plugin ]] || continue
    GUEST_SCRIPT+=$'\n'"( # wtyczka: ${plugin##*/}"$'\n'"$(cat "$plugin")"$'\n'") || true"
done
GUEST_SCRIPT+=$'\nexit 0\n'

# ---------- pomocnicze ----------
# run_in <host|ct|vm> <id> <skrypt sh> – uruchamia skrypt w danej maszynie
run_in() {
    local kind=$1 id=$2 script="PUC_ID=$2; PUC_KIND=$1; PUC_NC_MIN_FREE_MB=$NC_MIN_FREE_MB"$'\n'"$3" json
    case $kind in
        host) timeout "$TIMEOUT" sh -c "$script" 2>/dev/null ;;
        ct)   timeout "$TIMEOUT" pct exec "$id" -- sh -c "$script" 2>/dev/null ;;
        vm)
            json=$(timeout "$((TIMEOUT + 10))" qm guest exec "$id" --timeout "$TIMEOUT" -- sh -c "$script" 2>/dev/null) || return $?
            perl -MJSON -0777 -ne 'my $j = eval { decode_json($_) } or exit 1;
                print $j->{"out-data"} // ""; exit($j->{exitcode} // 0)' <<<"$json" ;;
    esac
}

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
# pierwszy numer wersji w tekście, np. "v1.32.7-alpine" -> "1.32.7"
vnum() { grep -oE '[0-9]+(\.[0-9]+)+' <<<"$1" | head -n1; }

declare -A LATEST_CACHE=()
# latest_version <źródło> – ustawia zmienną LATEST
latest_version() {
    local src=$1 auth=()
    if [[ -n ${LATEST_CACHE[$src]+x} ]]; then LATEST=${LATEST_CACHE[$src]}; return; fi
    case $src in
        github:*)
            [[ -n $GITHUB_TOKEN ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
            LATEST=$(curl -fsSL -m 20 "${auth[@]}" "https://api.github.com/repos/${src#github:}/releases/latest" 2>/dev/null |
                perl -MJSON -0777 -ne 'print eval { decode_json($_)->{tag_name} } // ""') ;;
        url:*) LATEST=$(curl -fsSL -m 20 "${src#url:}" 2>/dev/null | head -c 500) ;;
        cmd:*) LATEST=$(timeout 60 bash -c "${src#cmd:}" 2>/dev/null | head -c 500) ;;
        *)     LATEST="" ;;
    esac
    LATEST_CACHE[$src]=$LATEST
}

# check_apps <kind> <id> – wpisy z apps.conf dla danego ID; wypisuje linie UPD/APP/ERR
check_apps() {
    local kind=$1 id=$2 aid aname acmd asrc aupg cur lat
    [[ -f $ETC/apps.conf ]] || return 0
    while IFS='|' read -r aid aname acmd asrc aupg; do
        aid=$(trim "$aid")
        [[ -z $aid || $aid == \#* || $aid != "$id" ]] && continue
        aname=$(trim "$aname"); acmd=$(trim "$acmd"); asrc=$(trim "$asrc")
        cur=$(vnum "$(run_in "$kind" "$id" "$acmd" 2>/dev/null)")
        latest_version "$asrc"; lat=$(vnum "$LATEST")
        if [[ -z $cur || -z $lat ]]; then
            echo "ERR $aname: nie udało się ustalić wersji (lokalna: '${cur:-?}', najnowsza: '${lat:-?}')"
        elif [[ $cur != "$lat" && $(printf '%s\n%s\n' "$cur" "$lat" | sort -V | tail -n1) == "$lat" ]]; then
            echo "UPD $aname: $cur -> $lat"
            [[ -n $(trim "$aupg") ]] && echo "APPUP $aname"
        else
            echo "APP $aname: $cur (aktualne)"
        fi
    done < "$ETC/apps.conf"
}

# boot_kernel – kernel, z którym host wstanie po restarcie: przypięty przez
# proxmox-boot-tool (kernel pin), a bez przypięcia najnowszy w /boot
boot_kernel() {
    local f
    for f in /etc/kernel/next-boot-pin /etc/kernel/proxmox-boot-pin; do
        [[ -s $f ]] && { head -n1 "$f"; return; }
    done
    ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1
}

newest_kernel() { ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1; }

# dkms_ready <jądro> – 1, gdy każdy moduł DKMS zainstalowany dla uruchomionego jądra jest też
# zainstalowany dla <jądra> (u nas r8152 karty sieciowej: bez niego host wstanie bez sieci)
dkms_ready() {
    local k=$1 m
    command -v dkms >/dev/null || { echo 1; return; }
    for m in $(dkms status 2>/dev/null | awk -F'[,:]' -v r="$(uname -r)" '$0 ~ "installed" && $2 ~ r { gsub(/ /, "", $1); print $1 }' | sort -u); do
        dkms status 2>/dev/null | grep -F "$m" | grep -F "$k" | grep -q installed || { echo 0; return; }
    done
    echo 1
}

want() {    # czy sprawdzać to ID
    [[ -n $ONLY && $ONLY != "$1" ]] && return 1
    [[ " $EXCLUDE_IDS " == *" $1 "* ]] && return 1
    return 0
}

# ---------- zbieranie wyników ----------
HOST=$(hostname)
NOW=$(TZ=Europe/Warsaw date '+%Y-%m-%d %H:%M')
REPORT="" SHORT=""
TOTAL_PKG=0 TOTAL_SEC=0 TOTAL_APP=0 MACHINES=0 MACHINES_UPD=0 REBOOTS=0 ERRORS=0
STATE_TSV=""

# write_state – zapisuje $STATE_DIR/stan.json (przy -t dopisuje/podmienia tylko tę maszynę)
write_state() {
    mkdir -p "$STATE_DIR" || return
    local f=$STATE_DIR/stan.json
    printf '%s' "$STATE_TSV" | PUC_MERGE=$([[ -n $ONLY ]] && echo 1 || echo 0) PUC_FILE=$f \
        PUC_HOST=$HOST PUC_VER=$VERSION PUC_TIME=$(date -Iseconds) perl -MJSON::PP -e '
        use strict; use Encode qw(decode);
        my $js = JSON::PP->new->utf8->canonical->pretty;
        my ($T, $F) = (JSON::PP::true, JSON::PP::false);
        my %m;
        if ($ENV{PUC_MERGE} && open(my $fh, "<", $ENV{PUC_FILE})) {
            local $/; my $o = eval { $js->decode(<$fh>) };
            if ($o) { $m{"$_->{typ}:$_->{id}"} = $_ for @{ $o->{maszyny} || [] } }
        }
        binmode STDIN, ":encoding(UTF-8)";
        while (my $l = <STDIN>) {
            chomp $l; next unless length $l;
            my ($typ, $id, $et, $os, $n, $sec, $nu, $ncs, $rb, $upd, $err, $pk, $free, $ncv, $ncg, $svc, $kern) = split /\t/, $l, -1;
            my @lista = map { my @f = split / /; { nazwa => $f[0], z => $f[1], na => $f[2], bezpieczenstwo => ($f[3] ? $T : $F) } }
                        grep { length } split /\x1f/, ($pk // "");
            $m{"$typ:$id"} = {
                typ => $typ, id => $id, etykieta => $et, system => $os,
                pakiety => $n + 0, bezpieczenstwo => $sec + 0, aplikacje => $nu + 0,
                nextcloud_serwer => ($ncs ? $T : $F), restart => ($rb ? $T : $F),
                nowe_wersje => [ grep { length } split /\x1f/, ($upd // "") ],
                bledy => [ grep { length } split /\x1f/, ($err // "") ],
                lista_pakietow => \@lista, sprawdzono => $ENV{PUC_TIME},
                wolne_mb => (defined $free && $free =~ /^\d+$/ ? $free + 0 : undef),
                nextcloud_zainstalowany => (length($ncv // "") ? $ncv : undef),
                nextcloud_glowna => ($ncg ? $T : $F),
                uslugi_do_restartu => [ grep { length } split /\x1f/, ($svc // "") ],
                (length($kern // "") ? do { my @k = split / /, $kern;
                    (jadro_uruchomione => $k[0], jadro_nowe => $k[1], dkms_gotowe => ($k[2] ? $T : $F)) } : ()),
            };
        }
        my %ord = (host => 0, ct => 1, vm => 2);
        my @all = sort { ($ord{$a->{typ}} // 9) <=> ($ord{$b->{typ}} // 9) || ($a->{id} =~ /^\d+$/ ? $a->{id} : 0) <=> ($b->{id} =~ /^\d+$/ ? $b->{id} : 0) } values %m;
        $_->{id} = "" . $_->{id} for @all;   # id zawsze jako tekst (porównanie liczbowe wyżej zmienia typ)
        print $js->encode({ format => 1, wersja => $ENV{PUC_VER}, host => decode("UTF-8", $ENV{PUC_HOST}),
                            sprawdzono => $ENV{PUC_TIME}, maszyny => \@all });
    ' > "$f.tmp" && mv "$f.tmp" "$f" || { rm -f "$f.tmp"; echo "Nie udało się zapisać $f" >&2; }
}

# maszyny z dostępnymi aktualizacjami (do trybu -u)
M_KIND=() M_ID=() M_LABEL=() M_PKG=() M_APP=() M_APPUP=() M_NCSRV=()

# process <kind> <id> <etykieta> <wyjście skryptu gościa> [restart 0/1]
process() {
    local kind=$1 id=$2 label=$3 out=$4 reboot=${5:-0}
    local os="" n=0 sec=0 nu=0 list="" apps="" info="" err="" line p o v s appup="" ncsrv=0 ncv="" ncnew="" ncg=0
    local updl="" errl="" pkgl="" US=$'\x1f' free="" svcl="" kern=""
    while IFS= read -r line; do
        case $line in
            "OS "*)  os=${line#OS } ;;
            "PKG "*)
                read -r _ p o v s <<<"$line"
                n=$((n + 1)); [[ $s == 1 ]] && sec=$((sec + 1))
                (( n <= 200 )) && pkgl+="$p $o $v $s$US"
                if (( n <= MAX_LIST )); then
                    list+="    - $p  $o -> $v"; [[ $s == 1 ]] && list+="  [bezpieczeństwo]"; list+=$'\n'
                fi ;;
            "REBOOT"*) reboot=1 ;;
            "FREE "*) free=${line#FREE } ;;
            "SVC "*)  svcl+="${line#SVC }$US" ;;
            "KERNEL "*) kern=${line#KERNEL } ;;
            "UPD "*)  apps+="    * NOWA WERSJA: ${line#UPD }"$'\n'; nu=$((nu + 1)); updl+="${line#UPD }$US"
                      if [[ $line == "UPD Nextcloud: Nextcloud "*" is available"* ]]; then
                          ncsrv=1; ncnew=$(vnum "${line#UPD Nextcloud: Nextcloud }")
                      fi ;;
            "APPUP "*) appup+="${line#APPUP }"$'\n' ;;
            "APP "*)  apps+="    - ${line#APP }"$'\n'
                      [[ $line == "APP Nextcloud: zainstalowany Nextcloud "* ]] && ncv=$(vnum "${line#APP Nextcloud: zainstalowany Nextcloud }") ;;
            "INFO "*) info+="  i ${line#INFO }"$'\n' ;;
            "ERR "*)  err+="  ! ${line#ERR }"$'\n'; errl+="${line#ERR }$US" ;;
        esac
    done <<<"$out"
    (( n > MAX_LIST )) && list+="    ... i jeszcze $((n - MAX_LIST))"$'\n'
    [[ -z $os ]] && err+="  ! brak danych z maszyny (skrypt nie zwrócił wyniku)"$'\n' && errl+="brak danych z maszyny$US"
    if [[ $free =~ ^[0-9]+$ ]] && (( free < MIN_FREE_MB )); then
        err+="  ! mało miejsca na dysku: $free MB wolne"$'\n'; errl+="mało miejsca na dysku: $free MB wolne$US"
    fi
    # nowa wersja SERWERA Nextclouda z innej linii (34 -> 35) = wersja główna: obecna linia jest aktualna
    [[ -n $ncv && -n $ncnew && ${ncv%%.*} != "${ncnew%%.*}" ]] && ncg=1
    STATE_TSV+=$(printf '%s\t' "$kind" "$id" "$label" "$os" "$n" "$sec" "$nu" "$ncsrv" "$reboot" "${updl//$'\t'/ }" "${errl//$'\t'/ }" "$pkgl" "$free" "$ncv" "$ncg" "$svcl" "$kern")$'\n'

    MACHINES=$((MACHINES + 1))
    if (( n > 0 || nu > 0 )); then
        M_KIND+=("$kind") M_ID+=("$id") M_LABEL+=("$label") M_PKG+=("$n") M_APP+=("$nu")
        M_APPUP+=("$appup") M_NCSRV+=("$ncsrv")
    fi
    TOTAL_PKG=$((TOTAL_PKG + n)); TOTAL_SEC=$((TOTAL_SEC + sec)); TOTAL_APP=$((TOTAL_APP + nu))
    [[ -n $err ]] && ERRORS=$((ERRORS + 1))
    (( reboot )) && REBOOTS=$((REBOOTS + 1))

    REPORT+="== $label${os:+ ($os)} =="$'\n'
    if (( n > 0 )); then
        REPORT+="  Pakiety do aktualizacji: $n (bezpieczeństwa: $sec)"$'\n'"$list"
    elif [[ -n $os ]]; then
        REPORT+="  Pakiety: aktualne"$'\n'
    fi
    [[ -n $apps ]] && REPORT+="  Aplikacje:"$'\n'"$apps"
    (( reboot )) && REPORT+="  ! Wymagany restart"$'\n'
    [[ -n $svcl ]] && REPORT+="  i Usługi ze starymi bibliotekami w pamięci: ${svcl//$US/ }"$'\n'
    REPORT+="$info$err"$'\n'

    if (( n > 0 || nu > 0 || reboot )) || [[ -n $err ]]; then
        (( n > 0 || nu > 0 )) && MACHINES_UPD=$((MACHINES_UPD + 1))
        local s_line="• $label:"
        (( n > 0 )) && s_line+=" $n pak." && (( sec > 0 )) && s_line+=" ($sec bezp.)"
        (( nu > 0 )) && s_line+=" aplikacje: $nu"
        (( reboot )) && s_line+=" [restart]"
        [[ -n $err ]] && s_line+=" [błąd]"
        SHORT+="$s_line"$'\n'
    fi
}

# check_machine <kind> <id> <etykieta> [restart]
check_machine() {
    local kind=$1 id=$2 label=$3 reboot=${4:-0} out rc
    out=$(run_in "$kind" "$id" "$GUEST_SCRIPT"); rc=$?
    (( rc != 0 )) && out+=$'\n'"ERR uruchomienie zakończone kodem $rc (124 = przekroczony czas)"
    out+=$'\n'"$(check_apps "$kind" "$id")"
    [[ $kind == host ]] && command -v pveversion >/dev/null && out+=$'\n'"INFO $(pveversion)"
    [[ $kind == host ]] && out+=$'\n'"KERNEL $(uname -r) $(newest_kernel) $(dkms_ready "$(newest_kernel)")"
    if [[ $kind == host && -s $STATE_DIR/jadro-nie-wstalo ]]; then
        out+=$'\n'"ERR jądro $(head -n1 "$STATE_DIR/jadro-nie-wstalo") nie wstało przy ostatnim restarcie – działa $(uname -r)"
    fi
    process "$kind" "$id" "$label" "$out" "$reboot"
}

# Host
if (( CHECK_HOST )) && want host; then
    # kernel, z którym host wstanie, inny niż uruchomiony => potrzebny restart hosta
    # Najnowsze zainstalowane, nie „to, z którym wstanie” – przy przypiętym jądrze host wstałby
    # na starym i restart nigdy by się nie zgłosił (tak było 2026-10-16: pin na 7.0.14-19, nowe 7.0.14-24).
    host_reboot=0
    newest=$(newest_kernel)
    [[ -n $newest && $newest != "$(uname -r)" ]] && host_reboot=1
    check_machine host host "Host $HOST" "$host_reboot"
fi

# Kontenery LXC
if (( CHECK_CT )) && command -v pct >/dev/null; then
    for id in $(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" { print $1 }'); do
        want "$id" || continue
        name=$(pct config "$id" 2>/dev/null | awk '/^hostname:/ { print $2 }')
        check_machine ct "$id" "CT $id ${name:-?}"
    done
    stopped=$(pct list 2>/dev/null | awk 'NR > 1 && $2 == "stopped" { printf "%s ", $1 }')
    [[ -n $stopped && -z $ONLY ]] && REPORT+="(Pominięte zatrzymane kontenery: $stopped)"$'\n\n'
fi

# Maszyny wirtualne (przez qemu-guest-agent)
if (( CHECK_VM )) && command -v qm >/dev/null; then
    for id in $(qm list 2>/dev/null | awk 'NR > 1 && $3 == "running" { print $1 }'); do
        want "$id" || continue
        cfg=$(qm config "$id" 2>/dev/null)
        name=$(awk '/^name:/ { print $2 }' <<<"$cfg")
        [[ $(awk '/^ostype:/ { print $2 }' <<<"$cfg") == l2* ]] || continue   # tylko Linux
        if ! timeout 15 qm agent "$id" ping >/dev/null 2>&1; then
            process vm "$id" "VM $id ${name:-?}" "ERR brak odpowiedzi qemu-guest-agent"; continue
        fi
        check_machine vm "$id" "VM $id ${name:-?}"
    done
fi

# ---------- raport ----------
SUMMARY="Razem: $TOTAL_PKG pakietów ($TOTAL_SEC bezpieczeństwa) na $MACHINES_UPD z $MACHINES maszyn"
(( TOTAL_APP > 0 )) && SUMMARY+=", nowe wersje aplikacji: $TOTAL_APP"
(( REBOOTS > 0 )) && SUMMARY+=", restart: $REBOOTS"
(( ERRORS > 0 )) && SUMMARY+=", błędy: $ERRORS"

FULL="Raport aktualizacji Proxmox – $HOST – $NOW"$'\n\n'"$REPORT$SUMMARY"
echo "$FULL"

[[ -z $ONLY ]] && mkdir -p "$LOG_DIR" && echo "$FULL" > "$LOG_DIR/ostatni.txt"
write_state

# ---------- instalowanie aktualizacji (tryb -u) ----------
if (( UPGRADE )); then
    # shellcheck source=/dev/null
    . "${PUC_LIB:-/usr/local/lib/pve-update-check}/upgrade.sh"
    do_upgrades
fi

# ---------- powiadomienia ----------
(( NOTIFY )) || exit 0
if (( UPGRADE )); then
    (( ${#UP_DONE[@]} + ${#UP_FAIL[@]} > 0 )) || exit 0
    TITLE="[$HOST] Proxmox: zaktualizowano ${#UP_DONE[@]}, bledy ${#UP_FAIL[@]}"
    SHORT_MSG="$UP_SUMMARY"
    FULL+=$'\n\n'"$UP_SUMMARY"
else
    (( TOTAL_PKG + TOTAL_APP + REBOOTS + ERRORS > 0 || NOTIFY_ALWAYS )) || exit 0
    TITLE="[$HOST] Proxmox: $TOTAL_PKG pakietow, $TOTAL_APP aplikacji"   # ASCII – bezpiecznie w nagłówkach
    SHORT_MSG="${SHORT:-Wszystko aktualne.}"$'\n'"$SUMMARY"
fi
SHORT_MSG=${SHORT_MSG:0:3500}

if [[ -n $NTFY_URL ]]; then
    args=(-fsS -m 20 -H "Title: $TITLE" -H "Tags: package")
    (( TOTAL_SEC > 0 )) && args+=(-H "Priority: high")
    [[ -n $NTFY_TOKEN ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl "${args[@]}" --data-binary "$SHORT_MSG" "$NTFY_URL" >/dev/null || echo "Nie udało się wysłać do ntfy" >&2
fi

if [[ -n $TELEGRAM_BOT_TOKEN && -n $TELEGRAM_CHAT_ID ]]; then
    curl -fsS -m 20 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$TITLE"$'\n\n'"$SHORT_MSG" >/dev/null || echo "Nie udało się wysłać do Telegrama" >&2
fi

if [[ -n $MAIL_TO ]]; then
    subj="=?UTF-8?B?$(printf '%s' "$TITLE" | base64 -w0)?="
    printf 'To: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$MAIL_TO" "$subj" "$FULL" | /usr/sbin/sendmail -t || echo "Nie udało się wysłać e-maila" >&2
fi
exit 0
