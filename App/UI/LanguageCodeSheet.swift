import SwiftUI

/// Asks for a language code (BCP 47) to translate the minutes into.
struct LanguageCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var code = ""
    let choose: (String) -> Void

    private var trimmed: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { Translator.isValidLanguageCode(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terjemahkan ke bahasa lain").font(.headline)
            TextField("Kode bahasa", text: $code, prompt: Text("Contoh: pt-BR, it, th"))
                .onSubmit(submit)
            if trimmed.isEmpty {
                Text("Tulis kode bahasa BCP 47, misalnya en atau zh-Hans.")
                    .foregroundStyle(.secondary)
            } else if !isValid {
                Text("Kode bahasa tidak valid.").foregroundStyle(.secondary)
            } else if let name = Translator.languageName(trimmed) {
                Label(name, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Text("Bahasa ini tidak dikenali, tetapi tetap bisa dicoba.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Batal", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Terjemahkan", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        guard isValid else { return }
        choose(trimmed)
        dismiss()
    }
}
