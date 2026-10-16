#!/bin/bash
# mnas-historia — zbieracz historii dla mNas. Instaluje i aktualizuje go mNas przez SSH.
# Co minutę (mnas-historia.timer) dopisuje do plików RRD w /var/lib/mnas-historia:
#   cpu.rrd             temperatura pakietu i rdzeni (hwmon coretemp / k10temp)
#   moc.rrd             licznik energii RAPL; DERIVE z min 0 => waty, przekręcenie = pusta próbka
#   dysk-<serial>.rrd   temperatura dysku: NVMe z hwmon, SSD SATA z smartctl -n standby
#   miejsce-<sciezka>.rrd  zajete i calosc systemu plikow (statfs), '/' w sciezce -> '_'  [od wersji 2]
#   io-<serial>.rrd     odczyt i zapis dysku w B/s z licznikow jadra /sys/block/*/stat    [od wersji 2]
#
# 🔴 DYSKI WIRUJĄCE NIETYKALNE. Talerz odczytany co minutę nigdy by nie zasnął.
# Rozstrzyga pole udev ID_ATA_ROTATION_RATE_RPM (0 = SSD), czytane z bazy udev,
# bez jednego polecenia wysłanego do dysku. NIE queue/rotational: za mostkiem USB
# wszystkie dyski mają tam 1, także SSD (zmierzone 2026-10-04). Brak pola = pomijamy.
# Talerze — TYLKO GDY WŁAŚNIE PRACUJĄ (decyzja 2026-10-04: „żeby sam zbieracz go
# nie wybudzał”). Co minutę porównujemy licznik jądra /sys/block/sdX/stat z poprzednią
# minutą — to odczyt z pamięci jądra, do dysku nie idzie nic. Licznik drgnął = dysk
# kręci się i tak (kopia, zapis), więc wtedy czytamy temperaturę i zajętość. Licznik
# stoi = dysk śpi albo nic nie robi — nie ruszamy go. Odczyt SMART przez passthrough
# nie liczy się do tych liczników, więc zbieracz sam siebie nie podtrzymuje; najwyżej
# o minutę–dwie opóźnia zaśnięcie po końcu pracy.
# Liczniki zapisu/odczytu (io-*.rrd) zapisujemy dla wszystkich dysków zawsze — to ten
# sam odczyt z jądra, bez polecenia do dysku.
#
# Bez `set -e`: każda sekcja osobno — brak RAPL czy czujnika nie zatrzymuje reszty.
set -u
WERSJA=3
KAT=/var/lib/mnas-historia

[ "${1:-}" = "--wersja" ] && { echo "$WERSJA"; exit 0; }
mkdir -p "$KAT"

ARCHIWA=(
  RRA:AVERAGE:0.5:1:1440   RRA:MIN:0.5:1:1440   RRA:MAX:0.5:1:1440
  RRA:AVERAGE:0.5:30:336   RRA:MIN:0.5:30:336   RRA:MAX:0.5:30:336
  RRA:AVERAGE:0.5:120:372  RRA:MIN:0.5:120:372  RRA:MAX:0.5:120:372
  RRA:AVERAGE:0.5:1440:366 RRA:MIN:0.5:1440:366 RRA:MAX:0.5:1440:366
)

# $1 plik, $2.. definicje DS. Plik powstaje raz; zmiana zestawu DS = nowy plik z ręki.
utworz() {
  local plik=$1; shift
  [ -f "$plik" ] || rrdtool create "$plik" --step 60 "$@" "${ARCHIWA[@]}"
}

# $1 plik, $2 lista DS (a:b:c), $3 wartości (v1:v2:v3)
zapisz() { rrdtool update "$1" -t "$2" "N:$3" 2>/dev/null; }

stopnie() { awk '{printf "%.1f", $1/1000}' "$1" 2>/dev/null; }

czytaj_cpu() {
  local hw="" n
  for n in /sys/class/hwmon/hwmon*/name; do
    case "$(cat "$n")" in coretemp|k10temp) hw=${n%/name}; break ;; esac
  done
  [ -n "$hw" ] || return 0
  local ds=() defs=() val=() l nazwa d
  for l in "$hw"/temp*_label; do
    [ -f "$l" ] || continue
    nazwa=$(cat "$l")
    case "$nazwa" in
      "Package id 0"|Tctl) ds+=(pakiet) ;;
      Core\ *)             ds+=("rdzen${nazwa#Core }") ;;
      *) continue ;;
    esac
    val+=("$(stopnie "${l%_label}_input")")
  done
  [ ${#ds[@]} -gt 0 ] || return 0
  for d in "${ds[@]}"; do defs+=("DS:$d:GAUGE:120:-20:150"); done
  utworz "$KAT/cpu.rrd" "${defs[@]}"
  zapisz "$KAT/cpu.rrd" "$(IFS=:; echo "${ds[*]}")" "$(IFS=:; echo "${val[*]}")"
}

czytaj_moc() {
  local f=/sys/class/powercap/intel-rapl:0/energy_uj
  [ -r "$f" ] || return 0
  utworz "$KAT/moc.rrd" DS:pakiet:DERIVE:120:0:U
  zapisz "$KAT/moc.rrd" pakiet "$(cat "$f")"
}

czytaj_nvme() {
  local n hw ctrl serial
  for n in /sys/class/hwmon/hwmon*/name; do
    [ "$(cat "$n")" = nvme ] || continue
    hw=${n%/name}
    ctrl=$(basename "$(readlink -f "$hw/device")")
    serial=$(tr -cd 'A-Za-z0-9_-' < "/sys/class/nvme/$ctrl/serial" 2>/dev/null)
    [ -n "$serial" ] || continue
    utworz "$KAT/dysk-$serial.rrd" DS:temp:GAUGE:120:-20:120
    zapisz "$KAT/dysk-$serial.rrd" temp "$(stopnie "$hw/temp1_input")"
  done
}

czytaj_sata() {
  local d n wl serial temp
  for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    n=${d##*/}
    wolno "$n" || continue
    wl=$(udevadm info -q property -n "/dev/$n" 2>/dev/null)
    serial=$(echo "$wl" | sed -n 's/^ID_SERIAL_SHORT=//p' | tr -cd 'A-Za-z0-9_-')
    [ -n "$serial" ] || continue
    temp=$(smartctl -A -n standby -j "/dev/$n" 2>/dev/null \
           | sed -n '/"temperature"/,/}/s/.*"current": *\([0-9]*\).*/\1/p' | head -1)
    [ -n "$temp" ] || continue          # dysk bez temperatury (np. NONAME S100) — bez pliku
    utworz "$KAT/dysk-$serial.rrd" DS:temp:GAUGE:120:-20:120
    zapisz "$KAT/dysk-$serial.rrd" temp "$temp"
  done
}

# Czy dysk (nazwa z /sys/block) jest NVMe albo SSD. Tylko sysfs i baza udev —
# żadnego polecenia do samego dysku.
niewirujacy() {
  case "$1" in
    nvme*) return 0 ;;
    sd*)   udevadm info -q property -n "/dev/$1" 2>/dev/null | grep -qx 'ID_ATA_ROTATION_RATE_RPM=0' ;;
    *)     return 1 ;;
  esac
}

# Talerze, które pracowały w ostatniej minucie. Liczone raz na przebieg, przed
# wszystkim innym, i zapamiętywane w $KAT/.stan-<dysk>.
declare -A AKTYWNY=()
sprawdz_talerze() {
  local d n teraz poprzedni
  for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    n=${d##*/}
    niewirujacy "$n" && continue
    teraz=$(cat "$d/stat" 2>/dev/null) || continue
    poprzedni=$(cat "$KAT/.stan-$n" 2>/dev/null)
    echo "$teraz" > "$KAT/.stan-$n"
    [ -n "$poprzedni" ] && [ "$teraz" != "$poprzedni" ] && AKTYWNY[$n]=1
  done
}

# Wolno czytać: NVMe/SSD zawsze, talerz tylko gdy właśnie pracuje.
wolno() { niewirujacy "$1" || [ -n "${AKTYWNY[$1]:-}" ]; }

seryjny() {
  case "$1" in
    nvme*) tr -cd 'A-Za-z0-9_-' < "/sys/block/$1/device/serial" 2>/dev/null ;;
    *)     udevadm info -q property -n "/dev/$1" 2>/dev/null | sed -n 's/^ID_SERIAL_SHORT=//p' | tr -cd 'A-Za-z0-9_-' ;;
  esac
}

# Zajętość każdego systemu plików na NVMe/SSD. findmnt czyta /proc, lsblk — sysfs;
# statfs odpowiada z pamięci jądra. Ten sam nośnik pod dwiema ścieżkami liczymy raz.
czytaj_miejsce() {
  local cel zrodlo dysk plik b f s
  local -A byly=()
  while read -r cel zrodlo; do
    [ -n "${byly[$zrodlo]:-}" ] && continue
    case "$cel" in /|/mnt/*) ;; *) continue ;; esac
    # Drzewo w górę aż do dysku — działa i dla partycji, i dla LVM (`/` na pve-root,
    # gdzie PKNAME jest puste; zmierzone 2026-10-04).
    dysk=$(lsblk -snro NAME,TYPE "$zrodlo" 2>/dev/null | awk '$2=="disk"{print $1; exit}')
    [ -n "$dysk" ] && wolno "$dysk" || continue
    read -r b f s < <(stat -f -c '%b %a %S' "$cel" 2>/dev/null) || continue
    [ -n "${s:-}" ] || continue
    byly[$zrodlo]=1
    plik="$KAT/miejsce-$(echo "$cel" | tr '/' '_').rrd"
    utworz "$plik" DS:zajete:GAUGE:120:0:U DS:calosc:GAUGE:120:0:U
    # Całość = zajęte + dostępne, jak `df` i kafel Miejsce (rezerwa roota poza).
    zapisz "$plik" zajete:calosc "$(( (b - f) * s )):$(( b * s ))"
  done < <(findmnt -rn -t ext4,xfs,btrfs -o TARGET,SOURCE)
}

# Bajty odczytane i zapisane, licznik jądra (sektory po 512 B). DERIVE z min 0 => B/s.
czytaj_io() {
  local d n serial pola
  for d in /sys/block/nvme*n1 /sys/block/sd*; do
    [ -e "$d" ] || continue
    n=${d##*/}
    serial=$(seryjny "$n")
    [ -n "$serial" ] || continue
    read -r -a pola < "$d/stat" || continue
    utworz "$KAT/io-$serial.rrd" DS:odczyt:DERIVE:120:0:U DS:zapis:DERIVE:120:0:U
    zapisz "$KAT/io-$serial.rrd" odczyt:zapis "$(( pola[2] * 512 )):$(( pola[6] * 512 ))"
  done
}

command -v rrdtool >/dev/null || exit 0
sprawdz_talerze
czytaj_cpu
czytaj_moc
czytaj_nvme
czytaj_sata
czytaj_miejsce
czytaj_io
exit 0
