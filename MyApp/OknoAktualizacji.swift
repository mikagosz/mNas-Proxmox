import SwiftUI

/// Okno „Aktualizacje serwera” (od 1.2.30) — co ma aktualizacje, instalacja jednym
/// kliknięciem z potwierdzeniem, pasek postępu i koniec logu na żywo, cofnięcie po błędzie.
///
/// Wszystko dzieje się na serwerze (`pve-update-check` w jednostce `systemd-run`),
/// więc okno można zamknąć w trakcie — po ponownym otwarciu postęp czyta się od nowa.
struct OknoAktualizacji: View {
    static let id = "aktualizacje"

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var zakresy: [String: ZakresAktualizacji] = [:]
    @State private var serwerNC: [String: Bool] = [:]
    @State private var doPotwierdzenia: MaszynaAktualizacji?
    @State private var cofnijPytanie: PostepAktualizacji.Wynik?
    @State private var sprzatajPytanie: PostepAktualizacji.Wynik?
    @State private var restartPytanie: (m: MaszynaAktualizacji, caly: Bool)?
    /// Restart hosta: dwa ostrzeżenia — 1 = co się zatrzyma, 2 = jakie jądro wstanie.
    @State private var hostKrok: Int?
    @State private var hostMaszyna: MaszynaAktualizacji?
    @State private var instalacjaPytanie = false
    @State private var komunikat: String?
    @State private var pracuje = false
    /// Maszyna kliknięta przed chwilą — jej karta pokazuje postęp, zanim serwer zapisze pierwszy stan.
    @State private var uruchomiona: String?

    private var odczyt: OdczytAktualizacji? { model.aktualizacje }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Aktualizacje serwera", systemImage: DashTileID.aktualizacje.ikona)
                    .font(.title3.bold())
                    .foregroundStyle(DashTileID.aktualizacje.kolor)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            ThinScrollView {
                VStack(alignment: .leading, spacing: 14) { tresc }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(.background)
        .navigationTitle("Aktualizacje serwera")
        .scrollIndicators(.never)
        .zapamietajRozmiarOkna("aktualizacje")
        // Co 3 s, gdy coś trwa (pasek ma się ruszać), inaczej co 30 s. Zamknięte okno nie pyta.
        .task {
            await model.odswiezAktualizacje()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.aktualizacjaTrwa ? 3 : 30))
                await model.odswiezAktualizacje()
            }
        }
        .confirmationDialog(tytulPotwierdzenia, isPresented: Binding(get: { doPotwierdzenia != nil },
                                                                   set: { if !$0 { doPotwierdzenia = nil } }),
                            presenting: doPotwierdzenia) { m in
            Button("Zainstaluj") { Task { await instaluj(m) } }
            Button("Anuluj", role: .cancel) {}
        } message: { m in
            Text(opisPotwierdzenia(m))
        }
        .confirmationDialog("Cofnąć ostatnią aktualizację?", isPresented: Binding(get: { cofnijPytanie != nil },
                                                                              set: { if !$0 { cofnijPytanie = nil } }),
                            presenting: cofnijPytanie) { w in
            Button("Cofnij", role: .destructive) { Task { await cofnij(w) } }
            Button("Anuluj", role: .cancel) {}
        } message: { w in
            Text(w.snapshot != nil
                 ? "\(w.etykieta) wróci do snapshotu \(w.snapshot ?? "") sprzed aktualizacji. Kontener zostanie na chwilę zatrzymany i uruchomiony ponownie."
                 : "\(w.etykieta) zostanie przywrócony z kopii \(w.kopia ?? ""). Wszystko, co zmieniło się w nim po kopii, przepadnie.")
        }
        .confirmationDialog("Skasować ręcznie to, czego aktualizacja nie posprzątała?",
                            isPresented: Binding(get: { sprzatajPytanie != nil }, set: { if !$0 { sprzatajPytanie = nil } }),
                            presenting: sprzatajPytanie) { w in
            Button("Skasuj", role: .destructive) { Task { await sprzataj(w) } }
            Button("Anuluj", role: .cancel) {}
        } message: { w in
            Text("W \(w.etykieta) zostanie skasowane: \(w.doSprzataniaOpis.joined(separator: ", ")). Zrób to dopiero, gdy sprawdzisz, co wykryła weryfikacja.")
        }
        .confirmationDialog(restartPytanie?.caly == true ? "Uruchomić ponownie cały kontener?" : "Uruchomić ponownie usługi?",
                            isPresented: Binding(get: { restartPytanie != nil }, set: { if !$0 { restartPytanie = nil } })) {
            Button("Uruchom ponownie") { if let r = restartPytanie { Task { await restartuj(r.m, caly: r.caly) } } }
            Button("Anuluj", role: .cancel) {}
        } message: {
            if let r = restartPytanie {
                Text(r.caly
                     ? "\(r.m.etykieta) zostanie uruchomiony ponownie — wszystkie jego usługi znikną na kilkanaście sekund. Nie w trakcie kopii zapasowej (narzędzie to sprawdza)."
                     : "W \(r.m.etykieta) zostaną uruchomione ponownie: \(r.m.uslugiPojedynczo.joined(separator: ", ")). Każda zniknie na chwilę.")
            }
        }
        .confirmationDialog("Uruchomić ponownie serwer?", isPresented: Binding(get: { hostKrok == 1 }, set: { if !$0, hostKrok == 1 { hostKrok = nil } })) {
            if hostMaszyna?.czekaNoweJadro == true {
                Button("Dalej…") { Task { try? await Task.sleep(for: .milliseconds(300)); hostKrok = 2 } }
            } else {
                Button("Uruchom ponownie", role: .destructive) { hostKrok = nil; Task { await restartujHost() } }
            }
            Button("Anuluj", role: .cancel) { hostKrok = nil }
        } message: {
            Text("Zatrzymają się wszystkie kontenery i usługi na serwerze. Serwer wróci po ok. 2–3 minutach, a mNas połączy się sam. Restart nie ruszy, gdy trwa kopia zapasowa albo aktualizacja.")
        }
        .confirmationDialog("Wstanie nowe jądro — na pewno?", isPresented: Binding(get: { hostKrok == 2 }, set: { if !$0, hostKrok == 2 { hostKrok = nil } })) {
            Button("Uruchom ponownie na nowym jądrze", role: .destructive) { hostKrok = nil; Task { await restartujHost() } }
            Button("Anuluj", role: .cancel) { hostKrok = nil }
        } message: {
            if let m = hostMaszyna {
                Text("Teraz działa \(m.jadroUruchomione ?? "?"), wstanie \(m.jadroNowe ?? "?"). Sterownik karty sieciowej (DKMS) jest zbudowany dla nowego jądra. Start na nim jest jednorazowy — gdyby serwer nie wrócił do sieci w 5 minut, wyłącz go i włącz przyciskiem: wstanie na sprawdzonym jądrze. Po udanym starcie narzędzie przypnie nowe jądro na stałe.")
            }
        }
        .confirmationDialog("Zainstalować na serwerze narzędzie aktualizacji?", isPresented: $instalacjaPytanie) {
            Button("Zainstaluj") { Task { await instalujNarzedzie() } }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("mNas wgra pve-update-check \(NarzedzieAktualizacji.wersja) do /usr/local/bin i timer systemd (sprawdzanie codziennie o 7:30). Samo sprawdzanie niczego nie aktualizuje — odświeża tylko listy pakietów w kontenerach. Istniejące ustawienia w /etc/pve-update-check zostają.")
        }
    }

    // MARK: Treść

    @ViewBuilder private var tresc: some View {
        if !model.gpuSSHEnabled || model.status != .connected {
            Label("Aktualizacje wymagają połączenia SSH z hostem.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if odczyt == nil {
            HStack { ProgressView().controlSize(.small); Text("Czytam stan z serwera…").foregroundStyle(.secondary) }
        } else if let odczyt {
            if let blad = model.bladAktualizacji ?? komunikat {
                Label(blad, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            narzedzie(odczyt)
            if model.aktualizacjaTrwa, kartaPostepu(odczyt) == nil { postep(odczyt) }
            else if !model.aktualizacjaTrwa, let p = odczyt.postep, ["ok", "bledy", "przerwana"].contains(p.stan),
                    // przerwana bez zapisanego wyniku nie ma `koniec` — liczy się wtedy start
                    let koniec = AktualizacjeParsers.data(p.koniec ?? (p.przerwana ? p.start : nil)),
                    Date().timeIntervalSince(koniec) < 24 * 3600 {
                ostatniWynik(p, koniec: koniec, ogonLogu: odczyt.ogonLogu)
            }
            if let stan = odczyt.stan { maszyny(stan) }
        }
    }

    @ViewBuilder private func narzedzie(_ o: OdczytAktualizacji) -> some View {
        switch o.narzedzie {
        case .jest: EmptyView()
        case .brak, .staraWersja:
            VStack(alignment: .leading, spacing: 8) {
                if case .staraWersja(let w) = o.narzedzie {
                    Text("Na serwerze jest pve-update-check \(w), mNas ma \(NarzedzieAktualizacji.wersja).").font(.callout)
                } else {
                    Text("Na serwerze nie ma narzędzia, które sprawdza i instaluje aktualizacje.").font(.callout)
                }
                HStack {
                    Button(o.narzedzie == .brak ? "Zainstaluj narzędzie na serwerze…" : "Zaktualizuj narzędzie…") {
                        instalacjaPytanie = true
                    }
                    .disabled(model.instalujeNarzedzieAktualizacji || model.aktualizacjaTrwa)
                    if model.instalujeNarzedzieAktualizacji { ProgressView().controlSize(.small) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
    }

    /// ID maszyny, której karta ma pokazać postęp — ta z `aktualizacja.json`, a zaraz po
    /// kliknięciu ta kliknięta. `nil` = postęp na górze okna (sprawdzanie, start bez karty).
    private func kartaPostepu(_ o: OdczytAktualizacji) -> String? {
        guard model.aktualizacjaTrwa else { return nil }
        let id = o.postep?.trwa == true ? o.postep?.maszyna : uruchomiona
        guard let id, (o.stan?.maszyny ?? []).contains(where: { $0.id == id && ($0.maAktualizacje || !$0.bledy.isEmpty) })
        else { return nil }
        return id
    }

    private func postep(_ o: OdczytAktualizacji) -> some View {
        postepTresc(o)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.08)))
    }

    private func postepTresc(_ o: OdczytAktualizacji) -> some View {
        let p = o.postep?.trwa == true ? o.postep : nil
        let etap = p?.etap ?? (o.sprawdzaTeraz ? String(localized: "Sprawdzanie aktualizacji na wszystkich maszynach…")
                                               : String(localized: "Uruchamianie na serwerze…"))
        let start = AktualizacjeParsers.data(p?.start)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(etap).font(.callout.bold()).lineLimit(2)
                Spacer()
                if let p { Text("\(p.postep ?? 0)%").font(.callout.monospacedDigit().bold()) }
            }
            if let p {
                ProgressView(value: p.ulamek).tint(.green)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.green)
            }
            if !o.ogonLogu.isEmpty && p != nil {
                Text(o.ogonLogu.suffix(8).joined(separator: "\n"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(8).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
                    .textSelection(.enabled)
            }
            HStack {
                // Licznik od startu na serwerze — bez niego okno wygląda na zawieszone,
                // gdy etap długo się nie zmienia (kopia vzdump, updater Nextclouda).
                if let start {
                    TimelineView(.periodic(from: .now, by: 1)) { kontekst in
                        Text("trwa \(Self.czas(od: start, do: kontekst.date))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Okno można zamknąć — aktualizacja idzie dalej na serwerze, także gdy Mac uśnie.")
                    .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
            }
        }
    }

    static func czas(od: Date, do teraz: Date) -> String {
        let s = max(0, Int(teraz.timeIntervalSince(od)))
        return s >= 60 ? String(localized: "\(s / 60) min \(s % 60) s") : String(localized: "\(s) s")
    }

    private func ostatniWynik(_ p: PostepAktualizacji, koniec: Date, ogonLogu: [String]) -> some View {
        let uwagi = p.wyniki.flatMap { $0.ostrzezenia ?? [] }
        let ok = p.stan == "ok"
        let czysto = ok && uwagi.isEmpty
        let tytul: LocalizedStringKey = switch p.zakres {
        case "cofniecie":  ok ? "Cofnięto" : (p.przerwana ? "Cofnięcie przerwane" : "Cofnięcie nie wyszło")
        case "sprzatanie": ok ? "Wyczyszczono" : (p.przerwana ? "Sprzątanie przerwane" : "Sprzątanie nie wyszło")
        case "restart":    ok ? "Uruchomiono ponownie" : (p.przerwana ? "Ponowne uruchomienie przerwane" : "Ponowne uruchomienie nie wyszło")
        default:           ok ? (uwagi.isEmpty ? "Zaktualizowano" : "Zaktualizowano — weryfikacja przed sprzątaniem coś wykryła")
                              : (p.przerwana ? "Aktualizacja przerwana" : "Aktualizacja z błędami")
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label(tytul, systemImage: czysto ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout.bold()).foregroundStyle(czysto ? .green : .orange)
            if p.przerwanaBezWyniku {
                Text("Proces na serwerze już nie działa i nie zapisał wyniku. Zanim spróbujesz ponownie, zajrzyj do logu.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if p.przerwana {
                przerwanaLog(p, ogonLogu: ogonLogu)
            }
            ForEach(uwagi, id: \.self) { u in
                Label(u, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let w = p.doSprzatania, AktualizacjeParsers.poprawneID(w.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nic nie zostało skasowane. Do ręcznego skasowania:").font(.caption.bold())
                    ForEach(w.doSprzataniaOpis, id: \.self) { Text("• \($0)").font(.caption) }
                }
                Button("Wyczyść ręcznie…") { sprzatajPytanie = w }
                    .disabled(pracuje || model.aktualizacjaTrwa)
            }
            if let s = p.podsumowanie {
                Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if p.przerwanaBezWyniku {
                Text("Start \(koniec.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(koniec.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            if !ok, let w = p.moznaCofnac, AktualizacjeParsers.poprawneID(w.id) {
                Button("Cofnij do stanu sprzed aktualizacji…") { cofnijPytanie = w }
                    .disabled(pracuje || model.aktualizacjaTrwa)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill((czysto ? Color.green : .orange).opacity(0.08)))
    }

    /// Log przerwanej aktualizacji: ścieżka na serwerze (do skopiowania) i jego koniec.
    @ViewBuilder private func przerwanaLog(_ p: PostepAktualizacji, ogonLogu: [String]) -> some View {
        if let log = p.log, AktualizacjeParsers.poprawnyLog(log) {
            HStack(spacing: 6) {
                Text("Log: \(log)").font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Kopiuj ścieżkę") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                }
                .controlSize(.small)
            }
            if !ogonLogu.isEmpty {
                Text(ogonLogu.suffix(8).joined(separator: "\n"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(8).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func maszyny(_ stan: StanAktualizacji) -> some View {
        HStack {
            if let d = AktualizacjeParsers.data(stan.sprawdzono) {
                Text("Sprawdzono \(d.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sprawdź teraz") { Task { await sprawdz() } }
                .disabled(pracuje || model.aktualizacjaTrwa || odczyt?.narzedzie == .brak)
        }
        let doAkt = stan.doAktualizacji.sorted { $0.pilnosc > $1.pilnosc }
        let zBledami = stan.maszyny.filter { !$0.maAktualizacje && !$0.bledy.isEmpty }
        let aktualne = stan.maszyny.filter { !$0.maAktualizacje && $0.bledy.isEmpty }
        if doAkt.allSatisfy({ $0.pilnosc == .wersjaGlowna }) {
            Label("Wszystko aktualne.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
        ForEach(doAkt + zBledami) { m in karta(m) }
        if !aktualne.isEmpty {
            Text("Aktualne: \(aktualne.map(\.etykieta).joined(separator: ", "))")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func karta(_ m: MaszynaAktualizacji) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(Self.kolor(m)).frame(width: 9, height: 9)
                Text(m.etykieta).font(.headline)
                if let s = m.system { Text(s).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer()
                if m.restart { Label("restart", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange) }
            }
            if m.tylkoWersjaGlowna {
                Label(m.nextcloudZainstalowany.map { String(localized: "Aktualne — Nextcloud \($0).") } ?? String(localized: "Aktualne."),
                      systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.blue)
                Text("Jest nowa wersja główna. To duży skok — instaluj świadomie, po sprawdzeniu, czy Twoje aplikacje Nextclouda ją obsługują (zaznacz „Także serwer Nextclouda”).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if m.maAktualizacje { Text(Self.opis(m)).font(.callout) }
            ForEach(m.noweWersjeKrotko, id: \.self) { w in
                Label(w, systemImage: "sparkles").font(.caption).foregroundStyle(.green)
            }
            ForEach(m.bledy, id: \.self) { b in
                Label(b, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lista = m.listaPakietow, !lista.isEmpty {
                DisclosureGroup("Pakiety (\(m.pakiety))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lista, id: \.self) { p in
                            HStack(spacing: 6) {
                                Text(p.nazwa).font(.caption.monospaced())
                                Text("\(p.z) → \(p.na)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                if p.bezpieczenstwo { Image(systemName: "shield.lefthalf.filled").font(.caption2).foregroundStyle(.orange) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            if let o = odczyt, kartaPostepu(o) == m.id {
                Divider()
                postepTresc(o)
            } else {
                if m.wymagaRestartu { restartSekcja(m) }
                if m.maAktualizacje { sterowanie(m) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    /// Po aktualizacji bibliotek usługi dalej mają w pamięci stare wersje — poprawka działa
    /// dopiero po ich ponownym uruchomieniu.
    @ViewBuilder private func restartSekcja(_ m: MaszynaAktualizacji) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Wymaga ponownego uruchomienia", systemImage: "arrow.clockwise.circle")
                .font(.caption.bold()).foregroundStyle(.yellow)
            if !m.uslugiPojedynczo.isEmpty {
                Text("Usługi ze starymi bibliotekami w pamięci: \(m.uslugiPojedynczo.map { $0.replacingOccurrences(of: ".service", with: "") }.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if m.wymagaRestartuKontenera {
                Text(m.restart ? "System zgłasza, że potrzebny jest restart." : "dbus i systemd odświeżą się dopiero przy ponownym uruchomieniu całego kontenera.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if m.jestHostem {
                if m.czekaNoweJadro {
                    Text(m.dkmsGotowe == true
                         ? "Czeka nowe jądro \(m.jadroNowe ?? "") (teraz \(m.jadroUruchomione ?? "")) — sterownik karty sieciowej jest gotowy."
                         : "Czeka nowe jądro \(m.jadroNowe ?? ""), ale sterownik karty sieciowej (DKMS) nie jest dla niego zbudowany — po restarcie serwer mógłby wstać bez sieci.")
                        .font(.caption).foregroundStyle(m.dkmsGotowe == true ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Uruchom ponownie serwer…") { hostMaszyna = m; hostKrok = 1 }
                        .disabled(pracuje || model.aktualizacjaTrwa || (m.czekaNoweJadro && m.dkmsGotowe != true))
                }
            } else if AktualizacjeParsers.poprawneID(m.id), m.typ == "ct" {
                HStack {
                    Spacer()
                    if !m.uslugiPojedynczo.isEmpty {
                        Button("Uruchom ponownie usługi…") { restartPytanie = (m, false) }
                            .disabled(pracuje || model.aktualizacjaTrwa)
                    }
                    if m.wymagaRestartuKontenera || !m.uslugiPojedynczo.isEmpty {
                        Button("Uruchom ponownie kontener…") { restartPytanie = (m, true) }
                            .disabled(pracuje || model.aktualizacjaTrwa)
                    }
                }
            }
        }
    }

    @ViewBuilder private func sterowanie(_ m: MaszynaAktualizacji) -> some View {
        if m.jestHostem {
            Text("Sam Proxmox aktualizuj w SSH (pve-update-check -u -t host): nowe jądro wymaga nagłówków i przebudowy sterownika karty sieciowej, a hosta nie da się zsnapshotować.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if AktualizacjeParsers.poprawneID(m.id) {
            let zakres = Binding(get: { zakresy[m.klucz] ?? .wszystko }, set: { zakresy[m.klucz] = $0 })
            VStack(alignment: .leading, spacing: 6) {
                if m.pakiety > 0 && m.aplikacje > 0 {
                    Picker("Zakres", selection: zakres) {
                        ForEach(ZakresAktualizacji.allCases) { Text($0.opis).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if m.nextcloudSerwer && zakres.wrappedValue != .pakiety {
                    Toggle("Także serwer Nextclouda (kilka minut trybu konserwacji)",
                           isOn: Binding(get: { serwerNC[m.klucz] ?? false }, set: { serwerNC[m.klucz] = $0 }))
                        .font(.caption)
                    if let wolne = m.wolneMb, wolne < 2048 {
                        Text("W kontenerze jest tylko \(wolne) MB wolnego miejsca — updater Nextclouda potrzebuje ok. 2 GB i bez tego się nie uruchomi (pakiety i aplikacje tak).")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    // Sama wersja główna Nextclouda bez serwera = tylko kopia (~16 GB) i nic więcej.
                    let nicDoZrobienia = m.tylkoWersjaGlowna && !(m.nextcloudSerwer && serwerNC[m.klucz] == true)
                    Button("Zainstaluj…") { doPotwierdzenia = m }
                        .buttonStyle(.borderedProminent)
                        .disabled(pracuje || model.aktualizacjaTrwa || nicDoZrobienia)
                        .help(nicDoZrobienia ? String(localized: "Zaznacz „Także serwer Nextclouda” — bez tego nie ma tu nic do zainstalowania.") : "")
                }
            }
        }
    }

    // MARK: Teksty

    /// Kolor kropki maszyny — ten sam w kaflu i w oknie.
    static func kolor(_ m: MaszynaAktualizacji) -> Color {
        switch m.pilnosc {
        case .pilne:        return .orange
        case .aktualizacje: return .yellow
        case .wersjaGlowna, .aktualne: return .blue
        }
    }

    /// „3 pakiety (1 bezp.) · serwer Nextcloud 34.0.5” — ten sam opis w kaflu i w oknie.
    static func opis(_ m: MaszynaAktualizacji) -> String {
        var czesci: [String] = []
        if m.pakiety > 0 {
            czesci.append(m.bezpieczenstwo > 0 ? String(localized: "\(m.pakiety) pak. (\(m.bezpieczenstwo) bezp.)")
                                               : String(localized: "\(m.pakiety) pak."))
        }
        czesci += m.noweWersjeKrotko
        if m.wymagaRestartu && !m.maAktualizacje {
            czesci.append(m.uslugiPojedynczo.isEmpty ? String(localized: "restart kontenera")
                                                     : String(localized: "restart usług: \(m.uslugiPojedynczo.count)"))
        }
        return czesci.joined(separator: " · ")
    }

    private var tytulPotwierdzenia: String {
        guard let m = doPotwierdzenia else { return "" }
        return String(localized: "Zaktualizować \(m.etykieta)?")
    }

    private func opisPotwierdzenia(_ m: MaszynaAktualizacji) -> String {
        let zakres = zakresy[m.klucz] ?? .wszystko
        var t: [String] = []
        switch zakres {
        case .wszystko:  t.append(String(localized: "Zaktualizuję pakiety systemu i aplikacje."))
        case .pakiety:   t.append(String(localized: "Zaktualizuję tylko pakiety systemu."))
        case .aplikacje: t.append(String(localized: "Zaktualizuję tylko aplikacje."))
        }
        t.append(String(localized: "Najpierw snapshot kontenera, a gdy jego dysk tego nie umie — kopia vzdump. Bez niej nic się nie zmieni."))
        if serwerNC[m.klucz] == true && m.nextcloudSerwer && zakres != .pakiety {
            t.append(String(localized: "Serwer Nextclouda będzie kilka minut w trybie konserwacji."))
        }
        return t.joined(separator: " ")
    }

    // MARK: Akcje

    private func obsluz(_ w: AppModel.WynikZlecenia) {
        switch w {
        case .start:        komunikat = nil
        case .zajete:       komunikat = String(localized: "Na serwerze już coś trwa (sprawdzanie albo aktualizacja) — spróbuj za chwilę.")
        case .blad(let e):  komunikat = e
        }
    }

    private func instaluj(_ m: MaszynaAktualizacji) async {
        pracuje = true; defer { pracuje = false }
        uruchomiona = m.id
        let zakres = zakresy[m.klucz] ?? .wszystko
        obsluz(await model.zainstalujAktualizacje(id: m.id, zakres: zakres,
                                                  serwerNextcloud: m.nextcloudSerwer && serwerNC[m.klucz] == true))
    }

    private func cofnij(_ w: PostepAktualizacji.Wynik) async {
        pracuje = true; defer { pracuje = false }
        uruchomiona = w.id
        obsluz(await model.cofnijAktualizacje(id: w.id))
    }

    private func sprzataj(_ w: PostepAktualizacji.Wynik) async {
        pracuje = true; defer { pracuje = false }
        uruchomiona = w.id
        obsluz(await model.wyczyscPoAktualizacji(id: w.id))
    }

    private func restartuj(_ m: MaszynaAktualizacji, caly: Bool) async {
        pracuje = true; defer { pracuje = false }
        uruchomiona = m.id
        obsluz(await model.uruchomPonownie(id: m.id, calyKontener: caly))
    }

    private func restartujHost() async {
        pracuje = true; defer { pracuje = false }
        obsluz(await model.uruchomPonownieHost())
    }

    private func sprawdz() async {
        pracuje = true; defer { pracuje = false }
        obsluz(await model.sprawdzAktualizacjeTeraz())
    }

    private func instalujNarzedzie() async {
        switch await model.zainstalujNarzedzieAktualizacji() {
        case .success: komunikat = nil
        case .failure(let e): komunikat = e.opis
        }
    }
}
