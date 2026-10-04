import SwiftUI
import AppKit

/// Instrukcja: token Proxmoksa, połączenie, SSH, historia, kafle (zgłoszenie [U] 2026-10-04:
/// *„czy w programie są wszystkie wskazówki, jak użytkownik musi połączyć app z Proxmoxem?
/// jeżeli nie, zróbmy manual”*). Do tej pory ekran łączenia miał same etykiety pól.
///
/// Teksty po polsku są kluczami katalogu jak w całym programie. Polecenia powłoki idą
/// przez `Text(verbatim:)` — nie tłumaczy się ich, a muszą dać się skopiować bez zmian.
struct OknoInstrukcji: View {
    static let id = "instrukcja"

    var body: some View {
        ThinScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jak połączyć mNas z Proxmoksem").font(.title2.bold())
                    Text("Wystarczy token API. SSH jest dodatkiem — daje temperatury, wentylatory, SMART, terminal i historię temperatur.")
                        .foregroundStyle(.secondary)
                }

                sekcja("1. Czego potrzeba", "checklist") {
                    punkt("Mac z macOS 26.6 lub nowszym i serwer z Proxmox VE 9.")
                    punkt("Mac i serwer w tej samej sieci (albo połączone przez VPN).")
                    punkt("Dostęp do panelu Proxmoksa w przeglądarce: **https://ADRES-SERWERA:8006**.")
                }

                sekcja("2. Token API — pełny dostęp", "key") {
                    Text("Wszystko działa, także start i zatrzymanie kontenerów, restart serwera i SSH.")
                        .foregroundStyle(.secondary)
                    krok(1, "W panelu Proxmoksa: **Centrum danych → Uprawnienia → Tokeny API → Dodaj** (po angielsku: Datacenter → Permissions → API Tokens → Add).")
                    krok(2, "Użytkownik: **root@pam**. Identyfikator tokenu: dowolna nazwa, np. **mnas**.")
                    krok(3, "**Odznacz „Separacja uprawnień”** (Privilege Separation) — wtedy token ma prawa konta. Zaznaczona daje token bez żadnych praw.")
                    krok(4, "Kliknij **Dodaj** i skopiuj **Sekret**. Proxmox pokazuje go tylko raz.")
                    Text("Albo jednym poleceniem w konsoli serwera (Proxmox wypisze sekret):")
                        .font(.callout)
                    polecenie("pveum user token add root@pam mnas --privsep 0")
                }

                sekcja("3. Token API — tylko podgląd", "eye") {
                    Text("Bezpieczniejszy wariant: mNas tylko pokazuje, niczego na serwerze nie zmieni. Przyciski start, stop i restart zgłoszą brak uprawnień. Bez SSH — konto spoza systemu serwera nie zaloguje się przez SSH, więc nie będzie temperatur, SMART, terminala ani historii temperatur.")
                        .foregroundStyle(.secondary)
                    Text("W konsoli serwera:").font(.callout)
                    polecenie("pveum user add mnas@pve")
                    polecenie("pveum acl modify / --users mnas@pve --roles PVEAuditor")
                    polecenie("pveum user token add mnas@pve podglad --privsep 0")
                    Text("W mNas wpisujesz wtedy token **mnas@pve!podglad**.").font(.callout)
                }

                sekcja("4. Połączenie w mNas", "network") {
                    krok(1, "**Adres węzła**: adres IP albo nazwa serwera, bez https i bez portu. Port 8006 mNas dodaje sam.")
                    krok(2, "**Token API**: użytkownik, realm i nazwa tokenu, np. **root@pam!mnas**.")
                    krok(3, "**Sekret tokenu**: wartość skopiowana przy tworzeniu tokenu. Zaznacz „Zapamiętaj sekret”, żeby nie wpisywać go ponownie — trafia do pęku kluczy macOS.")
                    krok(4, "Kliknij **Połącz**.")
                    Text("Przy pierwszym połączeniu:").font(.callout.bold())
                    punkt("macOS zapyta o dostęp do **sieci lokalnej** — kliknij **Pozwól**, inaczej mNas nie dosięgnie serwera.")
                    punkt("mNas zapamięta certyfikat serwera. Jeśli kiedyś się zmieni, program przerwie połączenie i zapyta, czy nowemu ufać.")
                    punkt("Po aktualizacji programu macOS może zapytać o dostęp do pęku kluczy — kliknij **Zawsze pozwalaj** i uruchom mNas ponownie.")
                }

                sekcja("5. SSH — temperatury, wentylatory, SMART, terminal", "terminal") {
                    Text("Działa z tokenem użytkownika **root@pam** — część przed znakiem @ to konto, którym mNas loguje się przez SSH.")
                        .foregroundStyle(.secondary)
                    krok(1, "W oknie głównym kliknij **SSH** w nagłówku, potem **Kopiuj klucz**.")
                    krok(2, "W konsoli serwera dopisz klucz do konta root (w miejsce KLUCZ wklej skopiowany klucz):")
                    polecenie("mkdir -p /root/.ssh && echo \"KLUCZ\" >> /root/.ssh/authorized_keys")
                    krok(3, "Czujniki temperatur i wentylatorów (jeśli kafle zostają puste):")
                    polecenie("apt install lm-sensors && sensors-detect --auto")
                    krok(4, "Wróć do okna SSH i kliknij **Testuj SSH**.")
                }

                sekcja("6. Historia na wykresach", "chart.xyaxis.line") {
                    Text("Historię procesora, pamięci, transferów i przebiegów mNas bierze z samego Proxmoksa. Historię temperatur, poboru mocy i zapisów na dyski zbiera na serwerze mały zbieracz.")
                        .foregroundStyle(.secondary)
                    krok(1, "Kliknij kafel z historią, np. **Pobór mocy**, i w oknie wybierz **Zainstaluj zbieranie historii**.")
                    krok(2, "mNas doinstaluje pakiet rrdtool, wgra skrypt **/usr/local/bin/mnas-historia** i timer systemd uruchamiany co minutę. Dane leżą w **/var/lib/mnas-historia**, więc każdy Mac widzi tę samą historię.")
                    Text("Wyłączenie zbieracza:").font(.callout)
                    polecenie("systemctl disable --now mnas-historia.timer")
                }

                sekcja("7. Pulpit i kafle", "square.grid.2x2") {
                    punkt("Kafle mają **trzy rozmiary: Mały, Średni i Duży**.")
                    punkt("**Edytuj układ** (prawy górny róg okna): przeciągasz kafel w dowolne pole, przycisk rozmiaru przełącza Mały → Średni → Duży, oczko chowa kafel, kłódka przypina go do miejsca.")
                    punkt("**Ściśnij** układa kafle bez dziur, **Resetuj układ** wraca do ustawienia fabrycznego, **Gotowe** kończy edycję. Układ zostaje po ponownym uruchomieniu.")
                    punkt("Kliknięcie kafla otwiera okno ze szczegółami albo historią. W trybie edycji kliknięcie niczego nie otwiera.")
                }

                sekcja("8. Pasek menu i ustawienia", "menubar.rectangle") {
                    punkt("Ikona w pasku menu otwiera panel z wybranymi kaflami i listą przebiegów. Zamknięcie okna chowa mNas do paska menu — program dalej pilnuje kopii. **Zakończ mNas** jest w tym panelu.")
                    punkt("Zębatka w oknie głównym otwiera **Ustawienia** — tam zmienisz język programu.")
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 560, minHeight: 480)
        .zapamietajRozmiarOkna("instrukcja")
    }

    @ViewBuilder
    private func sekcja<Tresc: View>(_ tytul: LocalizedStringKey, _ ikona: String,
                                     @ViewBuilder tresc: () -> Tresc) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tytul, systemImage: ikona).font(.headline)
            tresc()
        }
    }

    private func krok(_ n: Int, _ tekst: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(tekst).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func punkt(_ tekst: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•").foregroundStyle(.secondary)
            Text(tekst).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Polecenie powłoki: bez tłumaczenia, czcionka stała, przycisk kopiowania.
    private func polecenie(_ tekst: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: tekst)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tekst, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Kopiuj polecenie")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Ikona pomocy obok zębatki — w nagłówku okna głównego i na ekranie łączenia.
struct IkonaInstrukcji: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: OknoInstrukcji.id)
        } label: {
            Label("Instrukcja", systemImage: "questionmark.circle")
        }
        .help("Instrukcja: token, połączenie, SSH, kafle")
    }
}

/// Otwiera instrukcję — z menu Pomoc, z okna Ustawienia i z ekranu łączenia.
struct PrzyciskInstrukcji: View {
    var tytul: LocalizedStringKey = "Instrukcja…"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(tytul) { openWindow(id: OknoInstrukcji.id) }
    }
}
