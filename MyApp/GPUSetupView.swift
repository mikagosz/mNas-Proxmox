import SwiftUI
import AppKit

/// Konfiguracja dostępu SSH (klucz mNas → serwer). Po udanym teście mNas czyta
/// GPU (i docelowo temperatury, wentylatory) realnymi komendami roota.
struct GPUSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var publicKey: String = String(localized: "…generowanie klucza…")
    @State private var testing = false
    @State private var resultText: String?
    @State private var resultOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "terminal")
                    .font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dostęp SSH do serwera").font(.title3.bold())
                    Text("\(model.sshUser)@\(model.host)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("mNas odpala realne komendy na węźle (sensors, smartctl, sterowanie wentylatorami, nvidia-smi). REST API Proxmoksa nie udostępnia ani czujników, ani PWM, ani temperatur dysków — ten kanał daje więcej niż API, nie mniej. Trzeba raz wkleić poniższy klucz publiczny do serwera.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Klucz publiczny mNas").font(.subheadline.bold())
                ScrollView(.horizontal) {
                    Text(publicKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(height: 54)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicKey, forType: .string)
                } label: {
                    Label("Kopiuj klucz", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Kroki na serwerze (raz)").font(.subheadline.bold())
                stepRow(1, "Skopiuj klucz przyciskiem wyżej.")
                stepRow(2, "Dopisz go na serwerze do **/root/.ssh/authorized_keys** — z Maca jednym poleceniem: `ssh-copy-id -i <klucz> root@\(model.host)`, albo z konsoli węzła: `mkdir -p /root/.ssh && echo \"KLUCZ\" >> /root/.ssh/authorized_keys`.")
                stepRow(3, "Sprawdź, że nic nie zniknęło: `ssh-keygen -lf /root/.ssh/authorized_keys` ma wypisać klucze **wszystkich** maszyn, nie tylko tej ostatniej.")
                stepRow(4, "Czujniki i wentylatory: `apt install lm-sensors && sensors-detect --auto`. Bez tego kafle temperatur i obrotów zostaną puste.")
                stepRow(5, "Wróć tu i kliknij **Testuj SSH**.")
            }

            if let resultText {
                Label(resultText, systemImage: resultOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(resultOK ? .green : .orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Zamknij") { dismiss() }
                Spacer()
                Button {
                    Task {
                        testing = true
                        resultText = nil
                        let r = await model.testSSH()
                        resultOK = r.ok
                        resultText = r.message
                        testing = false
                    }
                } label: {
                    if testing { ProgressView().controlSize(.small) }
                    else { Text("Testuj SSH").frame(minWidth: 90) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(testing)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            publicKey = await model.sshPublicKey() ?? String(localized: "Nie udało się wygenerować klucza.")
        }
    }

    private func stepRow(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").font(.callout.monospacedDigit().bold()).foregroundStyle(.tint)
            Text(text).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
