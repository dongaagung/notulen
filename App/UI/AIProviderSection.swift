import SwiftUI

/// Pengaturan's AI section: pick exactly one provider, then its key,
/// server address and models.
struct AIProviderSection: View {
    @Environment(AppStore.self) private var store
    @ViewState private var keyDraft = ""
    @ViewState private var availableModels: [String] = []
    @ViewState private var isLoadingModels = false
    @ViewState private var modelsError: String?

    private var provider: AIProvider { store.settings.aiProvider }

    var body: some View {
        @Bindable var store = store
        Section {
            Picker("Penyedia", selection: $store.settings.aiProvider) {
                ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: store.settings.aiProvider) {
                keyDraft = ""
                availableModels = []
                modelsError = nil
            }

            if provider.acceptsAPIKey {
                let hasKey = store.providersWithKeys.contains(provider)
                HStack {
                    SecureField(
                        "Kunci API \(provider.shortName)", text: $keyDraft,
                        prompt: Text(hasKey ? "Tersimpan. Tempel kunci baru untuk menggantinya" : provider.keyPlaceholder))
                        .onSubmit(saveKey)
                    Button("Simpan", action: saveKey)
                        .disabled(keyDraft.isEmpty)
                    if hasKey {
                        Button("Hapus", role: .destructive) { store.setAPIKey("", for: provider) }
                    }
                }
            }

            if provider == .anthropic {
                LabeledContent("Model") {
                    Text("Haiku 5.5 untuk catatan sementara · Sonnet 5.5 untuk notulen dan terjemahan")
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField(
                    "Alamat server", text: models(\.baseURL),
                    prompt: Text(provider.defaultBaseURL.isEmpty ? "https://…/v1" : provider.defaultBaseURL))
                ModelField(
                    title: "Model cepat (catatan sementara)",
                    hint: "Memperbarui catatan selama meeting. Pilih model cepat yang langsung menjawab tanpa bernalar dulu.",
                    value: models(\.fastModel), options: availableModels)
                ModelField(
                    title: "Model pintar (notulen, terjemahan)",
                    hint: "Menulis notulen dan menerjemahkannya.",
                    value: models(\.smartModel), options: availableModels)
                HStack {
                    Button("Muat daftar model") { Task { await loadModels() } }
                        .disabled(isLoadingModels)
                    if isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else if let modelsError {
                        Text(modelsError).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if !availableModels.isEmpty {
                        Text("\(availableModels.count) model. Pilih dari menu di atas.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Label(
                store.aiProblem ?? "Siap: \(provider.shortName)",
                systemImage: store.isAIReady ? "checkmark.seal" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(store.isAIReady ? .green : .orange)
        } header: {
            Text("Penyedia AI")
        } footer: {
            Text("""
                Hanya penyedia yang dipilih yang dipakai. Transkrip meeting dikirim ke penyedia itu; \
                kunci disimpan di Keychain. Prompt disetel untuk Claude, jadi model lain bisa menjawab berbeda.
                """)
        }
    }

    /// The active provider's address or model, defaulting the address.
    private func models(_ field: WritableKeyPath<ProviderModels, String>) -> Binding<String> {
        Binding(
            get: { store.settings.models(for: provider)[keyPath: field] },
            set: { value in
                var models = store.settings.models(for: provider)
                models[keyPath: field] = value
                store.settings.providerModels[provider] = models
            })
    }

    private func saveKey() {
        guard !keyDraft.isEmpty else { return }
        store.setAPIKey(keyDraft, for: provider)
        keyDraft = ""
    }

    private func loadModels() async {
        let address = store.settings.models(for: provider).baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address), url.host() != nil else {
            modelsError = "Isi alamat server dulu."
            return
        }
        isLoadingModels = true
        modelsError = nil
        do {
            availableModels = try await OpenAICompatibleClient.listModels(
                baseURL: url, apiKey: provider.acceptsAPIKey ? store.apiKey(for: provider) : nil)
            if availableModels.isEmpty { modelsError = "Server tidak menampilkan model." }
        } catch {
            availableModels = []
            modelsError = error.localizedDescription
        }
        isLoadingModels = false
    }
}

/// A model name: typed, or chosen from the models the server listed.
private struct ModelField: View {
    let title: String
    let hint: String
    @Binding var value: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(title, text: $value, prompt: Text("Nama model"))
                if !options.isEmpty {
                    Menu("Pilih") {
                        ForEach(options, id: \.self) { option in
                            Button(option) { value = option }
                        }
                    }
                    .fixedSize()
                }
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}
