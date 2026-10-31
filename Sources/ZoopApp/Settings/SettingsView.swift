import SwiftUI
import ZoopAgents

/// The Settings page inside the island, opened with the slider button in the header.
struct SettingsView: View {
    @Bindable var store: CompanionStore
    @Bindable var providers: ProviderSettingsStore
    @Binding var glassIntensity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { store.destination = .chat } label: { Label("Back to chat", systemImage: "arrow.left") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(ZoopTheme.secondary)
                Spacer()
                Text("SETTINGS").font(.system(size: 8, design: .monospaced)).tracking(1.2).foregroundStyle(ZoopTheme.secondary)
            }.padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Appearance") { appearance }
                    section("AI providers") {
                        VStack(spacing: 8) {
                            ForEach(providers.rows) { row in ProviderRowView(row: row, providers: providers) }
                        }
                        Text(providers.active == nil
                             ? "No provider is on. Add a key and turn one on to chat."
                             : "Chat, planning and tasks all use the provider that is on. Keys are stored in your Mac’s Keychain.")
                            .font(.system(size: 9)).foregroundStyle(providers.active == nil ? Color.orange.opacity(0.9) : ZoopTheme.secondary)
                        if let notice = providers.notice {
                            Text(notice).font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary)
                        }
                    }
                }.padding(.bottom, 16)
            }.scrollIndicators(.hidden)
        }
        .task { providers.reload(); await providers.loadModels() }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Glass intensity").font(.system(size: 11, weight: .medium)).foregroundStyle(ZoopTheme.text)
                Spacer()
                Text("\(Int((glassIntensity * 100).rounded()))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(ZoopTheme.lime)
            }
            Slider(value: $glassIntensity, in: 0...1).tint(ZoopTheme.lime).controlSize(.small).accessibilityLabel("Glass intensity")
            HStack {
                Text("Solid"); Spacer()
                Button("Reset") { glassIntensity = GlassSettings.defaultIntensity }.buttonStyle(.plain)
                Spacer(); Text("Clear")
            }.font(.system(size: 8, design: .monospaced)).foregroundStyle(ZoopTheme.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).settingsCard()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 8, design: .monospaced)).tracking(1).foregroundStyle(ZoopTheme.secondary)
            content()
        }
    }
}

private struct ProviderRowView: View {
    let row: ProviderSettingsStore.Row
    let providers: ProviderSettingsStore
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isOn: Binding<Bool> {
        Binding(get: { providers.active == row.provider }, set: { providers.setActive(row.provider, on: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(providers.active == row.provider ? ZoopTheme.lime : Color.white.opacity(0.15)).frame(width: 6, height: 6)
                Text(row.provider.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(ZoopTheme.text)
                Spacer()
                if let suffix = row.keySuffix, !row.isEditing {
                    Text("•••• \(suffix)").font(.system(size: 9, design: .monospaced)).foregroundStyle(ZoopTheme.secondary)
                        .accessibilityLabel("Key ending in \(suffix)")
                }
                if !row.isEditing {
                    Button { draft = ""; providers.beginEditing(row.provider); focused = true } label: {
                        if row.hasKey { Image(systemName: "pencil").font(.system(size: 11)) }
                        else { Text("Add key").font(.system(size: 10)) }
                    }
                    .buttonStyle(.plain).foregroundStyle(row.hasKey ? ZoopTheme.secondary : ZoopTheme.lime)
                    .accessibilityLabel(row.hasKey ? "Change \(row.provider.displayName) key" : "Add \(row.provider.displayName) key")
                }
                Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).tint(ZoopTheme.lime).labelsHidden()
                    .disabled(!row.hasKey || row.model == nil)
                    .accessibilityLabel("Use \(row.provider.displayName)")
            }
            if row.isEditing { editor }
            else if row.hasKey { modelPicker }
            if let error = row.error {
                Text(error).font(.system(size: 9)).foregroundStyle(Color.orange.opacity(0.9))
            }
        }
        .padding(12).settingsCard(highlighted: providers.active == row.provider)
    }

    private var editor: some View {
        HStack(spacing: 8) {
            SecureField(row.hasKey ? "Paste a new API key" : "Paste your API key", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(ZoopTheme.text)
                .focused($focused)
                .onSubmit(save)
                .padding(.horizontal, 10).frame(height: 28)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            if row.isChecking { ProgressView().controlSize(.small) }
            Button("Cancel") { draft = ""; providers.cancelEditing(row.provider) }.buttonStyle(GlassButtonStyle())
                .disabled(row.isChecking)
            Button("Save", action: save).buttonStyle(GlassButtonStyle(accent: true))
                .disabled(row.isChecking || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var modelPicker: some View {
        HStack(spacing: 8) {
            Text("Model").font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary)
            Menu {
                ForEach(row.models, id: \.self) { model in
                    Button(model) { providers.setModel(model, for: row.provider) }
                }
            } label: {
                Text(row.model ?? (row.models.isEmpty ? "Loading models…" : "Choose a model"))
                    .font(.system(size: 10, design: .monospaced))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(row.models.isEmpty)
            Spacer()
        }
    }

    private func save() {
        let key = draft
        Task {
            await providers.saveKey(key, for: row.provider)
            // A rejected key stays in the field so it can be fixed.
            if providers.rows.first(where: { $0.provider == row.provider })?.isEditing == false { draft = "" }
        }
    }
}

private extension View {
    func settingsCard(highlighted: Bool = false) -> some View {
        background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? ZoopTheme.lime.opacity(0.25) : .white.opacity(0.08), lineWidth: 1))
    }
}
