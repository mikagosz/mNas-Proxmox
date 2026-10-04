import Foundation
@testable import mNas

/// Zapisane odpowiedzi serwera — kształt dokładnie taki, jaki wraca z TrueNAS-a przez SSH.
/// Dzięki nim regresja w parsowaniu wychodzi z testu, a nie z patrzenia na dashboard.
enum Fixtures {

    /// `pvesh get /nodes/<węzeł>/rrddata --timeframe hour` — pięć wierszy, wszystkie pola,
    /// serwer testowy 2026-10-04. Pod historię CPU i RAM hosta.
    static let rrdWezlaPelny = #"""
    [{"arcsize": 1440, "cpu": 0.0818336299541966, "iowait": 0.0156300456162832, "loadavg": 0.56, "maxcpu": 6, "memavailable": 21968391918.9333, "memtotal": 25025552384, "memused": 3057160465.06667, "netin": 3392.02666666667, "netout": 1815.34666666667, "pressurecpusome": 0.0556666666666667, "pressureiofull": 1.89233333333333, "pressureiosome": 1.917, "pressurememoryfull": 0, "pressurememorysome": 0, "roottotal": 89615622144, "rootused": 12596064938.6667, "swaptotal": 8149528576, "swapused": 1681533610.66667, "time": 1791071700}, {"arcsize": 1440, "cpu": 0.0796891493488815, "iowait": 0.0161372595014036, "loadavg": 0.711, "maxcpu": 6, "memavailable": 21955358720, "memtotal": 25025552384, "memused": 3070193664, "netin": 1629.68333333333, "netout": 1616.84, "pressurecpusome": 0.0406666666666667, "pressureiofull": 2.47066666666667, "pressureiosome": 2.57, "pressurememoryfull": 0, "pressurememorysome": 0, "roottotal": 89615622144, "rootused": 12596098525.8667, "swaptotal": 8149528576, "swapused": 1681523507.2, "time": 1791071760}, {"arcsize": 1440, "cpu": 0.0615580278428918, "iowait": 0.0148660502018276, "loadavg": 0.709666666666667, "maxcpu": 6, "memavailable": 21922277239.4667, "memtotal": 25025552384, "memused": 3103275144.53333, "netin": 962.31, "netout": 1601.11, "pressurecpusome": 0.0426666666666667, "pressureiofull": 2.184, "pressureiosome": 2.185, "pressurememoryfull": 0, "pressurememorysome": 0, "roottotal": 89615622144, "rootused": 12596133341.8667, "swaptotal": 8149528576, "swapused": 1681516953.6, "time": 1791071820}, {"arcsize": 1440, "cpu": 0.0728945822467049, "iowait": 0.01458551156851, "loadavg": 0.625333333333334, "maxcpu": 6, "memavailable": 21940404087.4667, "memtotal": 25025552384, "memused": 3085148296.53333, "netin": 912.403333333333, "netout": 1540.84333333333, "pressurecpusome": 0.166333333333333, "pressureiofull": 1.965, "pressureiosome": 1.99733333333333, "pressurememoryfull": 0, "pressurememorysome": 0, "roottotal": 89615622144, "rootused": 12602327722.6667, "swaptotal": 8149528576, "swapused": 1681511901.86667, "time": 1791071880}, {"arcsize": 1440, "cpu": 0.0645451613497717, "iowait": 0.0148249297059607, "loadavg": 0.759666666666667, "maxcpu": 6, "memavailable": 21963402444.8, "memtotal": 25025552384, "memused": 3062149939.2, "netin": 1635.39666666667, "netout": 3508.23666666667, "pressurecpusome": 0.00366666666666667, "pressureiofull": 1.919, "pressureiosome": 1.95, "pressurememoryfull": 0, "pressurememorysome": 0, "roottotal": 89615622144, "rootused": 12604605508.2667, "swaptotal": 8149528576, "swapused": 1681354888.53333, "time": 1791071940}]
    """#

    /// To samo dla kontenera 104 (samba): `mem`, `maxmem`, `cpu`.
    static let rrdKonteneraPelny = #"""
    [{"cpu": 0.000292579331121893, "disk": 1029300224, "diskread": 1501.86666666667, "diskwrite": 136.533333333333, "maxcpu": 1, "maxdisk": 8350298112, "maxmem": 536870912, "mem": 41021166.9333333, "netin": 449.656666666667, "netout": 230.083333333333, "pressurecpufull": 0, "pressurecpusome": 0, "pressureiofull": 0, "pressureiosome": 0, "pressurememoryfull": 0, "pressurememorysome": 0, "time": 1791071700}, {"cpu": 0.000216262884694453, "disk": 1029300224, "diskread": 0, "diskwrite": 136.533333333333, "maxcpu": 1, "maxdisk": 8350298112, "maxmem": 536870912, "mem": 40935424, "netin": 379.643333333333, "netout": 21.8, "pressurecpufull": 0, "pressurecpusome": 0, "pressureiofull": 0, "pressureiosome": 0, "pressurememoryfull": 0, "pressurememorysome": 0, "time": 1791071760}, {"cpu": 0.000207458212123254, "disk": 1029300224, "diskread": 0, "diskwrite": 136.533333333333, "maxcpu": 1, "maxdisk": 8350298112, "maxmem": 536870912, "mem": 40982118.4, "netin": 334.49, "netout": 80.1166666666666, "pressurecpufull": 0, "pressurecpusome": 0, "pressureiofull": 0, "pressureiosome": 0, "pressurememoryfull": 0, "pressurememorysome": 0, "time": 1791071820}, {"cpu": 0.000160852576887988, "disk": 1029300224, "diskread": 0, "diskwrite": 136.533333333333, "maxcpu": 1, "maxdisk": 8350298112, "maxmem": 536870912, "mem": 41023624.5333333, "netin": 316.963333333333, "netout": 21.8, "pressurecpufull": 0, "pressurecpusome": 0, "pressureiofull": 0, "pressureiosome": 0, "pressurememoryfull": 0, "pressurememorysome": 0, "time": 1791071880}, {"cpu": 0.000225683673040649, "disk": 1029300224, "diskread": 136.533333333333, "diskwrite": 136.533333333333, "maxcpu": 1, "maxdisk": 8350298112, "maxmem": 536870912, "mem": 40979660.8, "netin": 296.213333333333, "netout": 83.4433333333334, "pressurecpufull": 0, "pressurecpusome": 0, "pressureiofull": 0, "pressureiosome": 0, "pressurememoryfull": 0, "pressurememorysome": 0, "time": 1791071940}]
    """#


    /// Odpowiedź `ServerCommands.poleceniOdczytuHistorii` — prawdziwe wyjście
    /// `rrdtool 1.7.2 xport --json` z serwera testowego, zdjęte 2026-10-04 kilka minut po
    /// instalacji zbieracza (stąd `null` na początku i na końcu okna). Serial NVMe zamieniony
    /// na `SERIAL1`. Moc już w watach (CDEF /1e6 po stronie serwera).
    static let xportProbka = """
    @@WERSJA 1
    @@PLIK cpu.rrd
    { "about": "RRDtool graph JSON output",
      "meta": {
        "start": 1791071160,
        "end": 1791071640,
        "step": 60,
        "legend": [
          "pakiet",
          "rdzen0",
          "rdzen1",
          "rdzen2",
          "rdzen3",
          "rdzen4",
          "rdzen5"
              ]
         },
      "data": [
        [ null, null, null, null, null, null, null ],
        [ null, null, null, null, null, null, null ],
        [ null, null, null, null, null, null, null ],
        [ 4.6000000000e+01, 4.3994212183e+01, 4.5000000000e+01, 4.3502893908e+01, 4.3994212183e+01, 4.5497106092e+01, 4.4000000000e+01 ],
        [ 4.6000000000e+01, 4.3994212183e+01, 4.5000000000e+01, 4.3502893908e+01, 4.3994212183e+01, 4.5497106092e+01, 4.4000000000e+01 ],
        [ 4.6000000000e+01, 4.2077520850e+01, 4.4077520850e+01, 4.4000000000e+01, 4.3000000000e+01, 4.5000000000e+01, 4.4000000000e+01 ],
        [ 4.6000000000e+01, 4.2839144300e+01, 4.4839144300e+01, 4.2321711400e+01, 4.2160855700e+01, 4.5000000000e+01, 4.3160855700e+01 ],
        [ null, null, null, null, null, null, null ],
        [ null, null, null, null, null, null, null ]
      ]
    }
    @@PLIK moc.rrd
    { "about": "RRDtool graph JSON output",
      "meta": {
        "start": 1791071160,
        "end": 1791071640,
        "step": 60,
        "legend": [
          "pakiet"
              ]
         },
      "data": [
        [ null ],
        [ null ],
        [ null ],
        [ 4.8577399565e+00 ],
        [ 4.8577399565e+00 ],
        [ 4.6307678076e+00 ],
        [ 4.1366379540e+00 ],
        [ null ],
        [ null ]
      ]
    }
    @@PLIK dysk-SERIAL1.rrd
    { "about": "RRDtool graph JSON output",
      "meta": {
        "start": 1791071160,
        "end": 1791071640,
        "step": 60,
        "legend": [
          "temp"
              ]
         },
      "data": [
        [ null ],
        [ null ],
        [ null ],
        [ 3.4900000000e+01 ],
        [ 3.4900000000e+01 ],
        [ 3.4900000000e+01 ],
        [ 3.4900000000e+01 ],
        [ null ],
        [ null ]
      ]
    }
    """


    /// `grep '^cpu' /proc/stat` — pierwszy pomiar.
    static let procStatFirst = """
    cpu  1200000 500 300000 9000000 4000 0 3000 0 0 0
    cpu0 300000 125 75000 2250000 1000 0 750 0 0 0
    cpu1 300000 125 75000 2250000 1000 0 750 0 0 0
    cpu2 300000 125 75000 2250000 1000 0 750 0 0 0
    cpu3 300000 125 75000 2250000 1000 0 750 0 0 0
    """

    /// Ten sam odczyt 5 s później: łącznie +1000 jiffies, z czego 750 bezczynnych → 25 %.
    static let procStatSecond = """
    cpu  1200150 500 300100 9000750 4000 0 3000 0 0 0
    cpu0 300050 125 75000 2250150 1000 0 750 0 0 0
    cpu1 300025 125 75025 2250200 1000 0 750 0 0 0
    cpu2 300000 125 75025 2250200 1000 0 750 0 0 0
    cpu3 300075 125 75050 2250200 1000 0 750 0 0 0
    """

    /// `cat /proc/meminfo` (skrócone do pól, których używamy).
    static let meminfo = """
    MemTotal:       32819208 kB
    MemFree:          524288 kB
    MemAvailable:   16777216 kB
    Buffers:           98765 kB
    Cached:          8388608 kB
    SwapCached:            0 kB
    Active:          6291456 kB
    """

    /// `sensors -j` — coretemp (4 rdzenie + pakiet) i układ ITE z trzema wentylatorami.
    /// Klucze „Adapter" są Stringiem, nie słownikiem — parser musi je pominąć.
    static let sensorsJSON = """
    {
       "coretemp-isa-0000":{
          "Adapter": "ISA adapter",
          "Package id 0":{ "temp1_input": 45.000, "temp1_max": 80.000, "temp1_crit": 100.000 },
          "Core 0":{ "temp2_input": 41.000, "temp2_max": 80.000 },
          "Core 1":{ "temp3_input": 43.000, "temp3_max": 80.000 },
          "Core 2":{ "temp4_input": 39.000, "temp4_max": 80.000 },
          "Core 3":{ "temp5_input": 44.000, "temp5_max": 80.000 }
       },
       "it8622-isa-0a40":{
          "Adapter": "ISA adapter",
          "fan3":{ "fan3_input": 0.000, "fan3_min": 0.000 },
          "fan1":{ "fan1_input": 1234.000, "fan1_min": 0.000 },
          "fan2":{ "fan2_input": 876.000, "fan2_min": 0.000 },
          "in0":{ "in0_input": 1.048 }
       },
       "nvme-pci-0400":{
          "Adapter": "PCI adapter",
          "Composite":{ "temp1_input": 38.850 }
       }
    }
    """

    /// `nvidia-smi --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw
    ///  --format=csv,noheader,nounits`
    static let nvidiaCSV = "NVIDIA GeForce GTX 1650, 12, 45, 512, 3903, 24.35"

    /// Wyjście skryptu wykrywającego kanały PWM. Ostatni wiersz to próba wstrzyknięcia —
    /// walidacja białą listą znaków musi go odrzucić.
    static let pwmChannels = """
    /sys/class/hwmon/hwmon2/pwm1 = 128 tryb=1
    /sys/class/hwmon/hwmon2/pwm2 = 255 tryb=2
    /sys/class/hwmon/hwmon2/pwm1;reboot = 100 tryb=1
    (brak PWM — załaduj it87)
    """

    /// `smartctl -j -H -A -i /dev/sda` przez `ssh -tt`: baner MOTD przed JSON-em
    /// i „Connection closed" po nim — dokładnie to, co psuło dekodowanie bez `extractJSON`.
    static let smartctlWithBanner = """
    Linux truenas 6.12.15-production+truenas #1 SMP PREEMPT_DYNAMIC
    Welcome to TrueNAS
    {
      "model_name": "WDC WD40EFRX-68N32N0",
      "serial_number": "WD-TESTSN000009",
      "smart_status": { "passed": true },
      "temperature": { "current": 38 },
      "power_on_time": { "hours": 21453 },
      "ata_smart_data": {
        "self_test": { "status": { "string": "completed without error" } }
      },
      "ata_smart_attributes": {
        "table": [
          { "id": 5,   "name": "Reallocated_Sector_Ct", "raw": { "value": 0, "string": "0" } },
          { "id": 197, "name": "Current_Pending_Sector", "raw": { "value": 0, "string": "0" } },
          { "id": 198, "name": "Offline_Uncorrectable", "raw": { "value": 2, "string": "2" } },
          { "id": 199, "name": "UDMA_CRC_Error_Count", "raw": { "value": 7, "string": "7" } },
          { "id": 194, "name": "Temperature_Celsius", "raw": { "value": 38, "string": "38" } }
        ]
      }
    }
    Connection to 192.168.10.28 closed.
    """

    /// Dysk NVMe — osobny log zdrowia zamiast tablicy atrybutów ATA.
    static let smartctlNVMe = """
    {
      "model_name": "Samsung SSD 980 PRO 1TB",
      "serial_number": "TESTSN00000008",
      "smart_status": { "passed": true },
      "nvme_smart_health_information_log": {
        "critical_warning": 0,
        "temperature": 41,
        "percentage_used": 73,
        "power_on_hours": 8123
      }
    }
    """

    /// Całe wyjście jednego wywołania SSH — tak, jak składa je `ServerCommands.liveStats`.
    static var liveStats: String {
        """
        @@STAT
        \(procStatFirst)
        @@MEM
        \(meminfo)
        @@ARC
        4294967296
        @@SENSORS
        \(sensorsJSON)
        @@GPU
        \(nvidiaCSV)
        """
    }

    // MARK: - Nośniki i zajętość (zapisane z serwera testowego 2026-08-19)

    /// `lsblk -b -P -o KNAME,PKNAME,TYPE,TRAN,MODEL,SIZE,MOUNTPOINT` — pięć nośników,
    /// trzy w kieszeniach USB, jeden NVMe pod LVM-em, jeden bez montowania.
    static let lsblkPairs = """
    KNAME="loop0" PKNAME="" TYPE="loop" TRAN="" MODEL="" SIZE="8589934592" MOUNTPOINT=""
    KNAME="loop1" PKNAME="" TYPE="loop" TRAN="" MODEL="" SIZE="8589934592" MOUNTPOINT=""
    KNAME="loop2" PKNAME="" TYPE="loop" TRAN="" MODEL="" SIZE="8589934592" MOUNTPOINT=""
    KNAME="loop3" PKNAME="" TYPE="loop" TRAN="" MODEL="" SIZE="21474836480" MOUNTPOINT=""
    KNAME="sda" PKNAME="" TYPE="disk" TRAN="usb" MODEL="SSD250SATA1" SIZE="250059350016" MOUNTPOINT=""
    KNAME="sda1" PKNAME="sda" TYPE="part" TRAN="" MODEL="" SIZE="250058113024" MOUNTPOINT="/mnt/zdjecia"
    KNAME="sdb" PKNAME="" TYPE="disk" TRAN="usb" MODEL="DYSK HDD1000A" SIZE="1000204886016" MOUNTPOINT=""
    KNAME="sdb1" PKNAME="sdb" TYPE="part" TRAN="" MODEL="" SIZE="1000203820544" MOUNTPOINT=""
    KNAME="sdd" PKNAME="" TYPE="disk" TRAN="usb" MODEL="NONAME S100" SIZE="240057409536" MOUNTPOINT=""
    KNAME="sdd1" PKNAME="sdd" TYPE="part" TRAN="" MODEL="" SIZE="240056344064" MOUNTPOINT="/mnt/aplikacje"
    KNAME="nvme1n1" PKNAME="" TYPE="disk" TRAN="nvme" MODEL="SSD NVME256-A" SIZE="256060514304" MOUNTPOINT=""
    KNAME="nvme1n1p1" PKNAME="nvme1n1" TYPE="part" TRAN="nvme" MODEL="" SIZE="1031168" MOUNTPOINT=""
    KNAME="nvme1n1p2" PKNAME="nvme1n1" TYPE="part" TRAN="nvme" MODEL="" SIZE="1073741824" MOUNTPOINT="/boot/efi"
    KNAME="nvme1n1p3" PKNAME="nvme1n1" TYPE="part" TRAN="nvme" MODEL="" SIZE="254475764224" MOUNTPOINT=""
    KNAME="dm-0" PKNAME="nvme1n1p3" TYPE="lvm" TRAN="" MODEL="" SIZE="8149532672" MOUNTPOINT="[SWAP]"
    KNAME="dm-1" PKNAME="nvme1n1p3" TYPE="lvm" TRAN="" MODEL="" SIZE="91649736704" MOUNTPOINT="/"
    KNAME="dm-2" PKNAME="nvme1n1p3" TYPE="lvm" TRAN="" MODEL="" SIZE="1543503872" MOUNTPOINT=""
    KNAME="dm-4" PKNAME="dm-2" TYPE="lvm" TRAN="" MODEL="" SIZE="151586340864" MOUNTPOINT=""
    KNAME="dm-5" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="151586340864" MOUNTPOINT=""
    KNAME="dm-6" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="4294967296" MOUNTPOINT=""
    KNAME="dm-8" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="8589934592" MOUNTPOINT=""
    KNAME="dm-9" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="4294967296" MOUNTPOINT=""
    KNAME="dm-10" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="8589934592" MOUNTPOINT=""
    KNAME="dm-11" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="4194304" MOUNTPOINT=""
    KNAME="dm-12" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="32212254720" MOUNTPOINT=""
    KNAME="dm-3" PKNAME="nvme1n1p3" TYPE="lvm" TRAN="" MODEL="" SIZE="151586340864" MOUNTPOINT=""
    KNAME="dm-4" PKNAME="dm-3" TYPE="lvm" TRAN="" MODEL="" SIZE="151586340864" MOUNTPOINT=""
    KNAME="dm-5" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="151586340864" MOUNTPOINT=""
    KNAME="dm-6" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="4294967296" MOUNTPOINT=""
    KNAME="dm-8" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="8589934592" MOUNTPOINT=""
    KNAME="dm-9" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="4294967296" MOUNTPOINT=""
    KNAME="dm-10" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="8589934592" MOUNTPOINT=""
    KNAME="dm-11" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="4194304" MOUNTPOINT=""
    KNAME="dm-12" PKNAME="dm-4" TYPE="lvm" TRAN="" MODEL="" SIZE="32212254720" MOUNTPOINT=""
    KNAME="nvme0n1" PKNAME="" TYPE="disk" TRAN="nvme" MODEL="SSD NVME1000-C" SIZE="1000204886016" MOUNTPOINT=""
    KNAME="nvme0n1p1" PKNAME="nvme0n1" TYPE="part" TRAN="nvme" MODEL="" SIZE="1000203702272" MOUNTPOINT="/mnt/zasoby"
    KNAME="nvme2n1" PKNAME="" TYPE="disk" TRAN="nvme" MODEL="SSD_NVME512-B" SIZE="512110190592" MOUNTPOINT=""
    KNAME="nvme2n1p1" PKNAME="nvme2n1" TYPE="part" TRAN="nvme" MODEL="" SIZE="256053870592" MOUNTPOINT="/mnt/wspolny"
    KNAME="nvme2n1p2" PKNAME="nvme2n1" TYPE="part" TRAN="nvme" MODEL="" SIZE="256054919168" MOUNTPOINT="/mnt/multimedia"
    """

    /// `df -B1 -P` z tego samego przebiegu. `/mnt/zasoby` zajęte w 85 % — ten dysk
    /// **nie jest** magazynem Proxmoksa i przed 2026-08-19 nie pojawiał się w apce.
    static let dfBytes = """
    udev                   3343495168            0   3343495168       0% /dev
    tmpfs                   815194112      2560000    812634112       1% /run
    efivarfs                   327680        74890       247670      24% /sys/firmware/efi/efivars
    /dev/mapper/pve-root  89615622144   9685651456  75503575040      12% /
    tmpfs                  4075962368     47923200   4028039168       2% /dev/shm
    tmpfs                     5242880            0      5242880       0% /run/lock
    tmpfs                     1048576            0      1048576       0% /run/credentials/systemd-journald.service
    tmpfs                  4075962368        40960   4075921408       1% /tmp
    /dev/nvme1n1p2         1071628288      9461760   1062166528       1% /boot/efi
    /dev/nvme0n1p1       983352680448 822684856320 153651048448      85% /mnt/zasoby
    /dev/nvme2n1p1       250898313216      2445312 248318554112       1% /mnt/wspolny
    /dev/nvme2n1p2       250899361792  10526826496 237795209216       5% /mnt/multimedia
    /dev/fuse               134217728        24576    134193152       1% /etc/pve
    tmpfs                     1048576            0      1048576       0% /run/credentials/getty@tty1.service
    /dev/sdd1            235151441920     21856256 232712245248       1% /mnt/aplikacje
    /dev/sda1            244995190784     26054656 242451779584       1% /mnt/zdjecia
    tmpfs                   815190016         4096    815185920       1% /run/user/0
    """

    /// Dwie próbki `@@POWER` w odstępie dokładnie 5 s. `package-0` przyrasta
    /// o 52 000 000 µJ → 10,4 W; `core` o 39 500 000 µJ → 7,9 W.
    static let raplFirst = """
    1787155301911627842
    package-0 174952721431 262143328850
    core 120000000000 262143328850
    dram 30000000000 262143328850
    """

    static let raplSecond = """
    1787155306911627842
    package-0 175004721431 262143328850
    core 120039500000 262143328850
    dram 30002500000 262143328850
    """

    /// Licznik tuż przed przewinięciem — 328 850 µJ poniżej `max_energy_range_uj`.
    static let raplBeforeWrap = """
    1787155311911627842
    package-0 262143000000 262143328850
    core 120079000000 262143328850
    """

    /// Ta sama domena 5 s później, **po przewinięciu**: wartość spada niemal do zera,
    /// choć pobór był dodatni (te same 10,4 W). Bez korekty o `max_energy_range_uj`
    /// różnica wychodzi ujemna i kafel gasł.
    static let raplAfterWrap = """
    1787155316911627842
    package-0 51671150 262143328850
    core 120118500000 262143328850
    """

    /// Wyjście `discoverWebServices` z serwera testowego **po skasowaniu AdGuarda** (2026-08-19).
    /// Na porcie 3000 stoi teraz Forgejo z kontenera 105; trzy kontenery Samby
    /// nasłuchują na 139 i 445.
    static let pctListen = """
    @@CT 101 kuma
    IP 192.168.10.42
    LISTEN 0.0.0.0:3001
    LISTEN *:22
    @@CT 104 samba
    IP 192.168.10.45
    LISTEN 0.0.0.0:139
    LISTEN 0.0.0.0:445
    @@CT 105 forgejo
    IP 192.168.10.46
    LISTEN *:3000
    LISTEN *:22
    @@CT 108 nextcloud
    IP 192.168.10.49
    LISTEN 127.0.0.1:3306
    LISTEN *:80
    """

    /// `smartctl -j -H -A -i /dev/sdd` — NONAME S100 w kieszeni USB. Dziewięć
    /// wskaźników, **ani jednego** z listy krytycznej i **bez** bloku `temperature`.
    static let smartctlSsdUsb = """
    {
      "model_name": "NONAME S100",
      "serial_number": "TESTSN0000000000003",
      "smart_status": { "passed": true },
      "power_on_time": { "hours": 20000 },
      "ata_smart_attributes": { "table": [
        { "id": 1,   "name": "Raw_Read_Error_Rate", "raw": { "value": 0, "string": "0" } },
        { "id": 9,   "name": "Power_On_Hours",      "raw": { "value": 20000, "string": "20000" } },
        { "id": 12,  "name": "Power_Cycle_Count",   "raw": { "value": 3835, "string": "3835" } },
        { "id": 168, "name": "Unknown_Attribute",   "raw": { "value": 0, "string": "0" } },
        { "id": 170, "name": "Unknown_Attribute",   "raw": { "value": 285, "string": "285" } },
        { "id": 173, "name": "Unknown_Attribute",   "raw": { "value": 21037408, "string": "21037408" } },
        { "id": 192, "name": "Power-Off_Retract_Count", "raw": { "value": 301, "string": "301" } },
        { "id": 218, "name": "Unknown_Attribute",   "raw": { "value": 224, "string": "224" } },
        { "id": 241, "name": "Total_LBAs_Written",  "raw": { "value": 28001, "string": "28001" } }
      ] }
    }
    """


    /// Sekcja `@@LVM` z serwera testowego. Po odsianiu po stronie serwera zostaje **sama pula**
    /// (`lv_attr` zaczyna się od `t`) — wolumeny maszyn mają własny `data_percent`,
    /// ale ich zajętość jest już wliczona w pulę.
    static let lvmReport = """
    PV /dev/nvme1n1p3 pve
    POOL pve 151586340864 19.07
    """

    /// Ta sama sekcja **bez odsiewania** — tak wyglądała, zanim doszedł warunek na
    /// `lv_attr`. Suma z tego wychodzi prawie dwa razy za duża.
    static let lvmReportZWolumenami = """
    PV /dev/nvme1n1p3 pve
    POOL pve 151586340864 19.07
    POOL pve 4294967296 28.16
    POOL pve 8589934592 34.56
    POOL pve 4294967296 25.31
    POOL pve 8589934592 14.33
    POOL pve 4194304 9.38
    POOL pve 32212254720 11.73
    """

}

// MARK: - Układ kafli pod testami

/// Magazyn układu na własnym pliku — jeden na zestaw testów.
///
/// 🔴 Bez tego dwa zestawy widziałyby swoje zapisy nawzajem, a testy trwałości
/// („przeżywa restart") przechodziłyby z cudzych danych. Nazwa pliku bierze się
/// z etykiety zestawu, więc każdy ma swój.
@MainActor
enum UkladTestowy {

    static func magazyn(_ etykieta: String) -> MagazynUkladu {
        let plik = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mNasProxmox-test-\(etykieta).json")
        let m = MagazynUkladu(plik: plik)
        m.wyczysc()
        return m
    }

    /// Świeży układ na czystym pliku, z **zmierzoną** szerokością okna.
    static func uklad(_ etykieta: String, columns: Int = 4) -> DashboardLayout {
        // Stare klucze `UserDefaults` też czyścimy: `init` migruje z nich, gdy pliku
        // nie ma, więc bez tego test dziedziczyłby układ z prawdziwej apki.
        for klucz in ["mNasProxmox.dash.order", "mNasProxmox.dash.size",
                      "mNasProxmox.dash.hidden", "mNasProxmox.dash.positions",
                      "mNasProxmox.dash.locked", "mNasProxmox.dash.dismissedAlerts"] {
            MagazynUstawien.domyslny.removeObject(forKey: klucz)
        }
        let uklad = DashboardLayout(magazyn: magazyn(etykieta))
        uklad.ustawKolumny(columns)
        return uklad
    }
}
