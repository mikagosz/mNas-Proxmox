import SwiftUI
import AppKit

/// Instrukcja w układzie Pomocy programów: duży tytuł, potem sekcje z obrazkiem programu i numerowanymi punktami,
/// te same numery przy krokach obok. Wcześniejsza instrukcja krok po kroku (token, połączenie, SSH, historia, kafle)
/// zostaje w całości pod „Więcej”, razem z poleceniami do skopiowania.
///
/// 🔴 Obrazki to gotowe pliki z `Zasoby/Pomoc/`, narysowane przez osobną kopię pokazową programu na zmyślonym
/// serwerze `pve-demo`. Sam mNas nie ma trybu pokazowego i nie pokazuje w Instrukcji niczego z prawdziwego serwera.
/// Po zmianie wyglądu okna obrazki odtwarza się w kopii pokazowej, nie tutaj.
///
/// Teksty po polsku są kluczami katalogu jak w całym programie. Polecenia powłoki idą przez `Text(verbatim:)` —
/// nie tłumaczy się ich, a muszą dać się skopiować bez zmian.
struct OknoInstrukcji: View {
    static let id = "instrukcja"
    static let szerokosc: CGFloat = 960

    var body: some View {
        ThinScrollView {
            VStack(spacing: 0) {
                naglowek
                ForEach(Array(SekcjaInstrukcji.wszystkie.enumerated()), id: \.offset) { i, s in
                    Divider().padding(.horizontal, 60)
                    WidokSekcji(sekcja: s, obrazekPoLewej: i % 2 == 0)
                }
                Divider().padding(.horizontal, 60)
                dobrzeWiedziec
                PodpisStudia()
            }
            .padding(.bottom, 40)
            .frame(width: Self.szerokosc)
            .textSelection(.enabled)
        }
        // Okno szersze od treści o miejsce, które `ThinScrollView` dokłada na pasek (3 + 5 pt).
        // Przy oknie równym treści całość wystawała po 4 pt z obu stron i pasek leżał poza oknem (do 1.2.40).
        .frame(width: Self.szerokosc + 8)
        .frame(minHeight: 480)
        .zapamietajRozmiarOkna("instrukcja")
    }

    private var naglowek: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 96, height: 96)
            Text("Pierwsze kroki z mNas").font(.system(size: 40, weight: .semibold))
            Text("Twój serwer Proxmox w jednym oknie i w pasku menu: zasoby, dyski, kontenery, kopie i rok historii na wykresach.")
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: false, vertical: true)
            ObrazekOkna(plik: "pulpit", kadr: Kadr(CGRect(x: 0, y: 0, width: 1180, height: 700), punkty: []), szeroki: true)
                .padding(.top, 8)
        }
        .padding(.top, 44).padding(.bottom, 48).padding(.horizontal, 60)
    }

    private var dobrzeWiedziec: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dobrze wiedzieć").font(.system(size: 30, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .top), GridItem(.flexible(), spacing: 20, alignment: .top)],
                      spacing: 20) {
                karta("moon.zzz", "Uśpione dyski zostają uśpione",
                      "mNas pyta o każdą rzecz tylko tak często, jak ona się zmienia, i nie budzi śpiących dysków talerzowych.")
                karta("rectangle.on.rectangle", "Ta sama historia na każdym Macu",
                      "Historię zbiera i trzyma sam serwer, więc drugi Mac od razu widzi te same wykresy — także sprzed instalacji mNas.")
                karta("lock.shield", "Certyfikat serwera",
                      "mNas zapamiętuje certyfikat serwera przy pierwszym połączeniu. Jeśli kiedyś się zmieni, program przerwie połączenie i zapyta, czy nowemu ufać.")
                karta("globe", "Język programu",
                      "Zębatka w oknie głównym otwiera **Ustawienia** — tam wybierzesz język: według systemu, polski albo angielski.")
            }
        }
        .padding(.top, 40).padding(.horizontal, 60)
    }

    private func karta(_ symbol: String, _ tytul: LocalizedStringKey, _ tekst: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor)
            Text(tytul).font(.headline)
            Text(tekst).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Sekcje

/// Gdzie wyciąć obrazek okna i gdzie stoją punkty — w punktach okna z eksportu Pokazu (obrazek ma 2×).
struct Kadr {
    let prostokat: CGRect
    /// x < 0: punkt na marginesie po lewej, na wysokości wiersza (nie zasłania tekstu); inaczej na samym obrazku.
    let punkty: [CGPoint]

    init(_ prostokat: CGRect, punkty: [CGPoint]) {
        self.prostokat = prostokat
        self.punkty = punkty
    }
}

private extension CGPoint {
    /// Punkt na marginesie, na wysokości `y` wycinka.
    static func m(_ y: CGFloat) -> CGPoint { CGPoint(x: -1, y: y) }
}

struct SekcjaInstrukcji {
    let tytul: LocalizedStringKey
    let opis: LocalizedStringKey
    let kroki: [LocalizedStringKey]
    let plik: String
    let kadr: Kadr
    /// Obrazek na całą szerokość pod tekstem — pulpit i okna historii są za szerokie na kolumnę.
    let szeroki: Bool
    let wiecej: Wiecej?

    enum Wiecej { case polaczenie, ssh, kafle, historia, aktualizacje }

    static let wszystkie: [SekcjaInstrukcji] = [
        SekcjaInstrukcji(
            tytul: "Połączenie z Proxmoksem",
            opis: "Wystarczy adres serwera i token API. SSH to dodatek — daje temperatury, wentylatory, SMART, terminal i historię temperatur.",
            kroki: ["**Adres węzła**: adres IP albo nazwa serwera, bez https i bez portu. Najpierw kliknij **Edytuj**.",
                    "**Token API**, np. **root@pam!mnas**. Jak go założyć — pod „Więcej”.",
                    "**Sekret tokenu**. Z „Zapamiętaj sekret” trafia do pęku kluczy macOS.",
                    "**Połącz**. macOS zapyta o dostęp do sieci lokalnej — kliknij **Pozwól**."],
            plik: "polaczenie",
            kadr: Kadr(CGRect(x: 180, y: 280, width: 460, height: 340), punkty: [.m(70), .m(181), .m(218), .m(308)]),
            szeroki: false, wiecej: .polaczenie),
        SekcjaInstrukcji(
            tytul: "Nagłówek okna",
            opis: "Najważniejsze przyciski stoją na górze okna głównego.",
            kroki: ["**Terminal** otwiera konsolę serwera w mNas.",
                    "**SSH**: zielony znaczek, gdy SSH działa. Tu kopiujesz klucz i testujesz połączenie.",
                    "**Auto** odświeża dane samo, **Odśwież** robi to od razu.",
                    "Znak zapytania otwiera tę instrukcję, zębatka — Ustawienia."],
            plik: "pulpit",
            // Od x 360: bez godziny odświeżenia z lewej strony nagłówka. Punkty na lewych górnych rogach przycisków.
            kadr: Kadr(CGRect(x: 360, y: 5, width: 820, height: 90),
                       punkty: [CGPoint(x: 12, y: 18), CGPoint(x: 126, y: 18), CGPoint(x: 336, y: 16), CGPoint(x: 708, y: 18)]),
            szeroki: true, wiecej: .ssh),
        SekcjaInstrukcji(
            tytul: "Pulpit i kafle",
            opis: "Każdy kafel to jedna sprawa serwera. Kliknięcie otwiera okno ze szczegółami albo historią.",
            kroki: ["CPU: zużycie, rdzenie, temperatura i obciążenie. Kliknij, żeby zobaczyć procesy.",
                    "Pamięć RAM: wolne, usługi i przydział każdej maszyny.",
                    "Dyski: kondycja i temperatura każdego dysku. Strzałka otwiera jego okno."],
            plik: "pulpit",
            kadr: Kadr(CGRect(x: 0, y: 90, width: 1180, height: 770), punkty: [.m(30), CGPoint(x: 571, y: 86), CGPoint(x: 520, y: 342)]),
            szeroki: true, wiecej: nil),
        SekcjaInstrukcji(
            tytul: "Układanie kafli",
            opis: "**Edytuj układ** w prawym górnym rogu włącza tryb układania. Kafel przeciągasz w dowolne pole.",
            kroki: ["Przycisk rozmiaru przełącza **Mały → Średni → Duży**.",
                    "Kłódka przypina kafel do miejsca, oczko go chowa.",
                    "**Ściśnij** układa kafle bez dziur, **Resetuj układ** wraca do ustawienia fabrycznego, **Gotowe** kończy edycję."],
            plik: "pulpit-edycja",
            kadr: Kadr(CGRect(x: 0, y: 50, width: 1180, height: 420), punkty: [CGPoint(x: 180, y: 110), CGPoint(x: 318, y: 110), CGPoint(x: 925, y: 27)]),
            szeroki: true, wiecej: .kafle),
        SekcjaInstrukcji(
            tytul: "Historia na wykresach",
            opis: "Kafle z historią otwierają wykres — od ostatniej godziny po cały rok.",
            kroki: ["Zakres: Godzina, Doba, Tydzień, Miesiąc albo Rok.",
                    "Wykres z wybranego zakresu.",
                    "Średnia, szczyt i — przy poborze mocy — przybliżone kWh w tym zakresie."],
            plik: "historia-moc",
            kadr: Kadr(CGRect(x: 0, y: 55, width: 720, height: 355), punkty: [.m(23), CGPoint(x: 330, y: 155), .m(310)]),
            szeroki: true, wiecej: .historia),
        SekcjaInstrukcji(
            tytul: "Miejsce na dyskach",
            opis: "Okno Miejsce pokazuje zajętość udziałów i dysków w czasie: ile przybyło i ile zwolniono.",
            kroki: ["Dyski talerzowe mają historię tylko z chwil, gdy same pracują — mNas ich nie budzi.",
                    "Wybierz, które miejsca pokazać na wykresie.",
                    "Zajętość w czasie.",
                    "Teraz, zmiana, przybyło i zwolniono w wybranym zakresie."],
            plik: "historia-miejsce",
            kadr: Kadr(CGRect(x: 0, y: 55, width: 720, height: 485), punkty: [.m(65), .m(137), CGPoint(x: 450, y: 230), .m(407)]),
            szeroki: true, wiecej: nil),
        SekcjaInstrukcji(
            tytul: "Dysk i SMART",
            opis: "Kliknij dysk na kaflu Dyski albo Pamięć masowa — otworzy się jego okno.",
            kroki: ["**Teraz** albo **Historia** temperatur dysku.",
                    "Wynik SMART, temperatura i godziny pracy.",
                    "Wskaźniki krytyczne — zielone, gdy wszystko w porządku.",
                    "Testy dysku: krótki i długi, oraz ponowny odczyt kondycji."],
            plik: "dysk",
            kadr: Kadr(CGRect(x: 0, y: 55, width: 680, height: 400), punkty: [.m(22), .m(90), .m(190), .m(358)]),
            szeroki: true, wiecej: nil),
        SekcjaInstrukcji(
            tytul: "Aktualizacje serwera",
            opis: "Najpierw raz przygotuj serwer: wgraj narzędzie i ustaw, co ma sprawdzać — kroki pod „Więcej”. Potem kliknij kafel **Aktualizacje**.",
            kroki: ["Kliknij **Sprawdź teraz**, żeby odświeżyć listę od razu. Bez tego serwer sprawdza sam codziennie o 7:30.",
                    "Sprawdź kolor kropki: pomarańczowa — poprawki bezpieczeństwa, żółta — zwykłe aktualizacje, niebieska — wszystko aktualne.",
                    "Kliknij **Zainstaluj…** przy kontenerze. mNas zrobi kopię, zainstaluje i pokaże postęp. Gdy coś pójdzie źle, kliknij **Cofnij do stanu sprzed aktualizacji…**.",
                    "Wybierz zakres: wszystko, same pakiety albo same aplikacje. Serwer Nextclouda zaktualizujesz tylko po zaznaczeniu **Także serwer Nextclouda**."],
            plik: "aktualizacje",
            kadr: Kadr(CGRect(x: 0, y: 55, width: 640, height: 530),
                       punkty: [CGPoint(x: 505, y: 10), CGPoint(x: 12, y: 46), CGPoint(x: 513, y: 128), CGPoint(x: 26, y: 406)]),
            szeroki: true, wiecej: .aktualizacje),
        SekcjaInstrukcji(
            tytul: "Pasek menu",
            opis: "Ikona w pasku menu otwiera panel. Zamknięcie okna chowa mNas do paska menu — program dalej pilnuje kopii. Pomarańczowe kółko ze strzałką przy ikonie znaczy, że na serwerze czekają aktualizacje.",
            kroki: ["Stan połączenia. Suwaki wybierają kafle panelu, strzałka odświeża.",
                    "Przebiegi, które właśnie trwają.",
                    "Co wymaga uwagi, np. nieudana kopia albo przekroczony czas.",
                    "**Otwórz okno** i **Zakończ mNas**."],
            plik: "pasek-menu",
            kadr: Kadr(CGRect(x: 0, y: 0, width: 340, height: 400), punkty: [.m(28), .m(67), .m(226), .m(383)]),
            szeroki: false, wiecej: nil),
    ]
}

private struct WidokSekcji: View {
    let sekcja: SekcjaInstrukcji
    let obrazekPoLewej: Bool
    @State private var rozwinieta = false

    var body: some View {
        Group {
            if sekcja.szeroki {
                VStack(alignment: .leading, spacing: 28) {
                    tekst
                    ObrazekOkna(plik: sekcja.plik, kadr: sekcja.kadr, szeroki: true)
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .center, spacing: 44) {
                    if obrazekPoLewej { obrazek }
                    tekst
                    if !obrazekPoLewej { obrazek }
                }
            }
        }
        .padding(.vertical, 44).padding(.horizontal, 60)
    }

    private var obrazek: some View {
        ObrazekOkna(plik: sekcja.plik, kadr: sekcja.kadr, szeroki: false).frame(width: 440)
    }

    private var tekst: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sekcja.tytul).font(.system(size: 30, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(sekcja.opis).font(.system(size: 15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(sekcja.kroki.enumerated()), id: \.offset) { i, krok in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Znacznik(numer: i + 1, maly: true)
                        Text(krok).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let wiecej = sekcja.wiecej {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { rozwinieta.toggle() }
                } label: {
                    Label(rozwinieta ? "Mniej" : "Więcej", systemImage: rozwinieta ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.link)
                if rozwinieta { WiecejInstrukcji(rodzaj: wiecej).font(.callout) }
            }
        }
        .frame(maxWidth: sekcja.szeroki ? 720 : .infinity, alignment: .leading)
    }
}

/// Wycinek obrazka z `Zasoby/Pomoc/` w języku programu, z numerowanymi punktami.
private struct ObrazekOkna: View {
    let plik: String
    let kadr: Kadr
    let szeroki: Bool
    private let margines: CGFloat = 36

    private var obraz: NSImage? {
        let jezyk = Bundle.main.preferredLocalizations.first == "en" ? "en" : "pl"
        return Bundle.main.url(forResource: "pomoc-\(plik)-\(jezyk)", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    var body: some View {
        let maMargines = kadr.punkty.contains { $0.x < 0 }
        let lewy = maMargines ? margines : 0
        // Bez powiększania ponad 1:1 — obrazek ma 2×, ale większy niż okno wyglądałby jak zrzut pod lupą.
        let szer = min((szeroki ? 840 : 440) - lewy, kadr.prostokat.width)
        let skala = szer / kadr.prostokat.width
        let wys = kadr.prostokat.height * skala
        HStack(spacing: 0) {
            Color.clear.frame(width: lewy, height: wys)
            if let obraz {
                Image(nsImage: obraz.wycinek(kadr.prostokat)).resizable().interpolation(.high).frame(width: szer, height: wys)
            } else {
                Color.secondary.opacity(0.1).frame(width: szer, height: wys)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(kadr.punkty.enumerated()), id: \.offset) { i, p in
                    Znacznik(numer: i + 1).position(x: p.x < 0 ? margines / 2 + 2 : lewy + p.x * skala, y: p.y * skala)
                }
            }
            .frame(width: lewy + szer, height: wys, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private extension NSImage {
    /// Kawałek obrazka, w punktach od jego lewego górnego rogu — jak wycięty zrzut.
    func wycinek(_ r: CGRect) -> NSImage {
        NSImage(size: r.size, flipped: false) { _ in
            self.draw(in: NSRect(x: -r.minX, y: r.maxY - self.size.height, width: self.size.width, height: self.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

/// Numer na obrazku i ten sam numer przed krokiem.
private struct Znacznik: View {
    let numer: Int
    var maly = false

    var body: some View {
        Text(verbatim: "\(numer)")
            .font(.system(size: maly ? 11 : 13, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: maly ? 20 : 26, height: maly ? 20 : 26)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white, lineWidth: maly ? 0 : 2))
            .shadow(color: .black.opacity(maly ? 0 : 0.35), radius: 3, y: 1)
    }
}

// MARK: - Więcej: dawna instrukcja krok po kroku

private struct WiecejInstrukcji: View {
    let rodzaj: SekcjaInstrukcji.Wiecej

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch rodzaj {
            case .polaczenie: polaczenie
            case .ssh: ssh
            case .kafle: kafle
            case .historia: historia
            case .aktualizacje: aktualizacje
            }
        }
    }

    @ViewBuilder private var polaczenie: some View {
        sekcja("Czego potrzeba", "checklist") {
            punkt("Mac z macOS 26.6 lub nowszym i serwer z Proxmox VE 9.")
            punkt("Mac i serwer w tej samej sieci (albo połączone przez VPN).")
            punkt("Dostęp do panelu Proxmoksa w przeglądarce: **https://ADRES-SERWERA:8006**.")
        }
        sekcja("Token API — pełny dostęp", "key") {
            Text("Wszystko działa, także start i zatrzymanie kontenerów, restart serwera i SSH.")
                .foregroundStyle(.secondary)
            krok(1, "W panelu Proxmoksa: **Centrum danych → Uprawnienia → Tokeny API → Dodaj** (po angielsku: Datacenter → Permissions → API Tokens → Add).")
            krok(2, "Użytkownik: **root@pam**. Identyfikator tokenu: dowolna nazwa, np. **mnas**.")
            krok(3, "**Odznacz „Separacja uprawnień”** (Privilege Separation) — wtedy token ma prawa konta. Zaznaczona daje token bez żadnych praw.")
            krok(4, "Kliknij **Dodaj** i skopiuj **Sekret**. Proxmox pokazuje go tylko raz.")
            Text("Albo jednym poleceniem w konsoli serwera (Proxmox wypisze sekret):")
            polecenie("pveum user token add root@pam mnas --privsep 0")
        }
        sekcja("Token API — tylko podgląd", "eye") {
            Text("Bezpieczniejszy wariant: mNas tylko pokazuje, niczego na serwerze nie zmieni. Przyciski start, stop i restart zgłoszą brak uprawnień. Bez SSH — konto spoza systemu serwera nie zaloguje się przez SSH, więc nie będzie temperatur, SMART, terminala ani historii temperatur.")
                .foregroundStyle(.secondary)
            Text("W konsoli serwera:")
            polecenie("pveum user add mnas@pve")
            polecenie("pveum acl modify / --users mnas@pve --roles PVEAuditor")
            polecenie("pveum user token add mnas@pve podglad --privsep 0")
            Text("W mNas wpisujesz wtedy token **mnas@pve!podglad**.")
        }
        sekcja("Przy pierwszym połączeniu:", "network") {
            punkt("macOS zapyta o dostęp do **sieci lokalnej** — kliknij **Pozwól**, inaczej mNas nie dosięgnie serwera.")
            punkt("mNas zapamięta certyfikat serwera. Jeśli kiedyś się zmieni, program przerwie połączenie i zapyta, czy nowemu ufać.")
            punkt("Po aktualizacji programu macOS może zapytać o dostęp do pęku kluczy — kliknij **Zawsze pozwalaj** i uruchom mNas ponownie.")
        }
    }

    @ViewBuilder private var ssh: some View {
        sekcja("SSH — temperatury, wentylatory, SMART, terminal", "terminal") {
            Text("Działa z tokenem użytkownika **root@pam** — część przed znakiem @ to konto, którym mNas loguje się przez SSH.")
                .foregroundStyle(.secondary)
            krok(1, "W oknie głównym kliknij **SSH** w nagłówku, potem **Kopiuj klucz**.")
            krok(2, "W konsoli serwera dopisz klucz do konta root (w miejsce KLUCZ wklej skopiowany klucz):")
            polecenie("mkdir -p /root/.ssh && echo \"KLUCZ\" >> /root/.ssh/authorized_keys")
            krok(3, "Czujniki temperatur i wentylatorów (jeśli kafle zostają puste):")
            polecenie("apt install lm-sensors && sensors-detect --auto")
            krok(4, "Wróć do okna SSH i kliknij **Testuj SSH**.")
        }
    }

    @ViewBuilder private var kafle: some View {
        punkt("Układ zostaje po ponownym uruchomieniu.")
        punkt("W trybie edycji kliknięcie kafla niczego nie otwiera.")
    }

    @ViewBuilder private var historia: some View {
        sekcja("Zbieracz historii na serwerze", "chart.xyaxis.line") {
            Text("Historię procesora, pamięci, transferów i przebiegów mNas bierze z samego Proxmoksa. Historię temperatur, poboru mocy i zapisów na dyski zbiera na serwerze mały zbieracz.")
                .foregroundStyle(.secondary)
            krok(1, "Kliknij kafel z historią, np. **Pobór mocy**, i w oknie wybierz **Zainstaluj zbieranie historii**.")
            krok(2, "mNas doinstaluje pakiet rrdtool, wgra skrypt **/usr/local/bin/mnas-historia** i timer systemd uruchamiany co minutę. Dane leżą w **/var/lib/mnas-historia**, więc każdy Mac widzi tę samą historię.")
            Text("Wyłączenie zbieracza:")
            polecenie("systemctl disable --now mnas-historia.timer")
        }
    }

    @ViewBuilder private var aktualizacje: some View {
        sekcja("Czego potrzeba", "checklist") {
            punkt("Token **root@pam** z pełnym dostępem i działające SSH — kroki w sekcji „Połączenie z Proxmoksem”.")
            punkt("Kontenery do sprawdzania muszą być uruchomione. Zatrzymane narzędzie pomija i wypisuje w raporcie.")
        }
        sekcja("Wgranie narzędzia na serwer", "square.and.arrow.down") {
            krok(1, "Kliknij kafel **Aktualizacje**, potem **Zainstaluj narzędzie na serwerze…** i **Zainstaluj**.")
            krok(2, "mNas wgra **/usr/local/bin/pve-update-check**, ustawienia do **/etc/pve-update-check** i włączy codzienne sprawdzanie o 7:30. Samo sprawdzanie niczego nie instaluje.")
            krok(3, "Kliknij **Sprawdź teraz**. Na liście pojawią się host i wszystkie uruchomione kontenery — narzędzie znajduje je samo, niczego nie trzeba dopisywać.")
            Text("Gdy mNas ma nowszą wersję narzędzia, w tym samym miejscu pokaże **Zaktualizuj narzędzie…**. Twoje ustawienia zostają.")
                .foregroundStyle(.secondary)
        }
        sekcja("Ustawienia: co sprawdzać", "slider.horizontal.3") {
            Text("Ustawienia leżą w jednym pliku na serwerze. Otwórz go w konsoli serwera:")
            polecenie("nano /etc/pve-update-check/config")
            krok(1, "Kontener do pominięcia — wpisz jego numer, kilka oddziel spacją:")
            polecenie("EXCLUDE_IDS=\"105 110\"")
            krok(2, "Maszyny wirtualne z Linuksem — włącz je (w maszynie musi działać qemu-guest-agent):")
            polecenie("CHECK_VM=1")
            krok(3, "Kopia przed aktualizacją: na dyskach ZFS, LVM-thin i Ceph narzędzie robi snapshot. Na zwykłym katalogu robi kopię vzdump na storage z **BACKUP_STORAGE** — wpisz taki, na którym jest miejsce na cały kontener:")
            polecenie("BACKUP_STORAGE=\"local\"")
            krok(4, "Zapisz plik (Ctrl+O, Enter, Ctrl+X) i kliknij w mNas **Sprawdź teraz**.")
        }
        sekcja("Programy spoza pakietów", "shippingbox") {
            Text("Pakiety systemu i Nextclouda narzędzie sprawdza samo. Program postawiony z GitHuba albo z /opt dopisz do **/etc/pve-update-check/apps.conf**, jedna linia na program: numer kontenera, nazwa, polecenie wypisujące wersję, skąd brać najnowszą.")
                .foregroundStyle(.secondary)
            polecenie("nano /etc/pve-update-check/apps.conf")
            polecenie("105 | Vaultwarden | vaultwarden --version | github:dani-garcia/vaultwarden")
            Text("W pliku są gotowe przykłady — wystarczy usunąć # i poprawić numer kontenera.")
        }
        sekcja("Wyłączenie", "power") {
            Text("Codzienne sprawdzanie:")
            polecenie("systemctl disable --now pve-update-check.timer")
        }
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

// MARK: - Podpis

/// Podpis Fractal 8 Dev na końcu instrukcji, jak nagłówek fractal8.eu: logo duże w tle pod tą samą zasłoną co film
/// na stronie (ciemniej przy brzegach i ku dołowi), tekst na jego dolnej części — „ENDLESS RECURSION” rozstrzelone
/// o 0,42 em w kolorze akcentu (#7ee8f2 ciemny, #0a8796 jasny), „Fractal 8 Dev” SF Pro Bold ściśnięte o −0,045 em
/// z gradientem strony, pod spodem zdanie spod tytułu strony.
private struct PodpisStudia: View {
    @Environment(\.colorScheme) private var schemat
    private static let logo: NSImage? = Bundle.main.url(forResource: "studio-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        let ciemny = schemat == .dark
        let tlo = Color(nsColor: .windowBackgroundColor)
        let akcent = ciemny ? Color(red: 126 / 255, green: 232 / 255, blue: 242 / 255) : Color(red: 10 / 255, green: 135 / 255, blue: 150 / 255)
        let gradient = LinearGradient(stops: [
            .init(color: ciemny ? .white : Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255), location: 0.4),
            .init(color: ciemny ? Color(red: 159 / 255, green: 163 / 255, blue: 171 / 255) : Color(red: 91 / 255, green: 95 / 255, blue: 102 / 255), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        ZStack(alignment: .bottom) {
            if let logo = Self.logo {
                Image(nsImage: logo).resizable().interpolation(.high).frame(width: 560, height: 560)
                    .opacity(ciemny ? 0.75 : 0.55)
                    .frame(height: 440, alignment: .top)
                    .clipped()
                    // Zasłona ze strony (styles.css, .hero-sticky::after).
                    .overlay(RadialGradient(stops: [.init(color: .clear, location: 0.35), .init(color: tlo.opacity(0.75), location: 1)],
                                            center: .center, startRadius: 0, endRadius: 300))
                    .overlay(LinearGradient(stops: [.init(color: tlo.opacity(0.35), location: 0), .init(color: .clear, location: 0.3),
                                                    .init(color: tlo.opacity(0.55), location: 0.62), .init(color: tlo, location: 0.92)],
                                            startPoint: .top, endPoint: .bottom))
            }
            VStack(spacing: 0) {
                Text(verbatim: "ENDLESS RECURSION")
                    .font(.system(size: 12)).tracking(12 * 0.42).foregroundStyle(akcent)
                    .padding(.bottom, 16)
                Text(verbatim: "Fractal 8 Dev")
                    .font(.system(size: 76, weight: .bold)).tracking(-76 * 0.045)
                    .foregroundStyle(gradient)
                Text("Natywne programy dla macOS, budowane według jednego wzoru.")
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                    .padding(.top, 18)
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .padding(.top, 40)
    }
}

// MARK: - Wejścia do instrukcji

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
