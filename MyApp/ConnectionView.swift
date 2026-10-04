import SwiftUI

/// Ekran łączenia — adres węzła, identyfikator tokenu API i jego sekret.
///
/// Proxmox uwierzytelnia **tokenem**, nie parą konto+klucz: pełna tożsamość siedzi
/// w jednym ciągu `użytkownik@realm!nazwa`, a osobno leci sekret. Dlatego pole
/// „Użytkownik" z wersji pod TrueNAS-a zmieniło znaczenie, nie tylko etykietę.
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey: String = ""
    @State private var saveKey = true
    @State private var confirmTrust = false

    /// Pola są **zablokowane**, dopóki user nie kliknie „Edytuj".
    ///
    /// Bez tego wystarczyło, że okno miało zaznaczony adres i przypadkowy znak
    /// z klawiatury podmieniał cały adres węzła — zdarzyło się 2026-08-16 i skończyło
    /// się komunikatem „Nie można połączyć się z z". Ustawienia połączenia zmienia się
    /// raz na kilka miesięcy, więc domyślnie mają być tylko do odczytu.
    @State private var editing = false

    private var isConnecting: Bool { model.status == .connecting }

    /// Sekret trzeba wpisać tylko wtedy, gdy nie ma zapisanego — wtedy pole otwiera się samo.
    private var needsSecret: Bool { !model.hasSavedKey }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 24) {
            VStack(spacing: 8) {
                // Ikona aplikacji brana z samej paczki, nie kopia w katalogu assetów.
                // Dzięki temu okno i Dock nie mogą się rozjechać — jest jeden plik źródłowy.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 154, height: 154)
                Text("mNas")
                    .font(.largeTitle.bold())
                Text("Połącz z węzłem Proxmox VE")
                    .foregroundStyle(.secondary)
            }

            Form {
                Section {
                    if editing {
                        TextField("Adres węzła", text: $model.host)
                            .textContentType(.URL)
                            .disableAutocorrection(true)
                    } else {
                        LabeledContent("Adres węzła") {
                            Text(model.host.isEmpty ? "—" : model.host)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Port 8006 dopisuje klient — wpisanie go tutaj tylko myliłoby.
                    Text("Port 8006 i konto SSH (część przed znakiem @) mNas ustala sam.")
                        .font(.caption2).foregroundStyle(.secondary)
                    PrzyciskInstrukcji(tytul: "Jak przygotować serwer i token?")
                        .buttonStyle(.link).font(.caption)
                    // Podpowiedź pokazuje KSZTAŁT identyfikatora, nie prawdziwy token —
                    // konkretna nazwa mówiłaby, jakim kontem loguje się właściciel programu.
                    if editing {
                        TextField("Token API (konto@realm!nazwa)", text: $model.username)
                            .disableAutocorrection(true)
                    } else {
                        LabeledContent("Token API") {
                            Text(model.username.isEmpty ? "—" : model.username)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if editing || needsSecret {
                        SecureField("Sekret tokenu", text: $apiKey)
                        // Etykieta mówi to, co kod faktycznie robi: Keychain jest magazynem
                        // podstawowym, plik powstaje tylko wtedy, gdy Keychain odmówi.
                        Toggle("Zapamiętaj sekret (Keychain, awaryjnie plik lokalny)", isOn: $saveKey)
                    } else {
                        LabeledContent("Sekret tokenu") {
                            Label("zapisany", systemImage: "key.fill")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Label(editing ? "Edycja ustawień" : "Ustawienia połączenia",
                              systemImage: editing ? "pencil" : "lock.fill")
                        Spacer()
                        Button(editing ? "Gotowe" : "Edytuj") {
                            editing.toggle()
                        }
                        .controlSize(.small)
                        .disabled(isConnecting)
                        .help(editing
                              ? "Zablokuj pola, żeby przypadkowy znak ich nie zmienił"
                              : "Odblokuj adres i token do zmiany")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 460)
            .frame(height: 270)
            .disabled(isConnecting)
            // Pierwsze uruchomienie: nie ma czego chronić i trzeba gdzieś wpisać sekret.
            .onAppear { editing = needsSecret && model.host.isEmpty }

            if let change = model.certificateChange {
                certificateWarning(change)
            } else if case .failed(let message) = model.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                if model.hasSavedKey {
                    Button("Użyj zapisanego sekretu") {
                        Task { await model.connectUsingSavedKey() }
                    }
                    .disabled(isConnecting)
                }

                Button {
                    Task { await model.connect(apiKey: apiKey, saveKey: saveKey) }
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Połącz").frame(minWidth: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty || isConnecting)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                IkonaInstrukcji()
                PrzyciskUstawien()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(12)
        }
    }

    // MARK: - Zmiana certyfikatu serwera

    /// Jawna ścieżka „zaufaj nowemu certyfikatowi". Bez niej przypięcie certyfikatu
    /// zamieniłoby lukę w blokadę: po reinstalacji Proxmoksa, `pvecm updatecerts`
    /// albo wymianie certyfikatu apka przestałaby się łączyć i nic by z tym nie dało
    /// się zrobić z poziomu UI.
    @ViewBuilder
    private func certificateWarning(_ change: AppModel.CertificateChange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Certyfikat serwera się zmienił", systemImage: "lock.trianglebadge.exclamationmark.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text("Węzeł \(change.host) przedstawił inny klucz publiczny niż przy pierwszym połączeniu. Jeśli certyfikat nie był wymieniany celowo (reinstalacja Proxmoksa, `pvecm updatecerts`, zmiana hosta), ktoś może podszywać się pod serwer — a tym kanałem leci sekret tokenu API.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            fingerprintRow("Zapamiętany", change.expected, .green)
            fingerprintRow("Przedstawiony teraz", change.received, .red)

            HStack {
                Button("Zaufaj nowemu certyfikatowi", role: .destructive) { confirmTrust = true }
                Button("Anuluj") { model.certificateChange = nil }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.4), lineWidth: 1))
        .alert("Zaufać nowemu certyfikatowi?", isPresented: $confirmTrust) {
            Button("Zaufaj i połącz", role: .destructive) { Task { await model.trustNewCertificate() } }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Rób to tylko wtedy, gdy certyfikat na serwerze został wymieniony celowo. Od tej chwili mNas będzie ufać nowemu kluczowi i wysyłać na niego sekret tokenu API.")
        }
    }

    private func fingerprintRow(_ label: LocalizedStringKey, _ fingerprint: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(CertificatePin.display(fingerprint))
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }
}
