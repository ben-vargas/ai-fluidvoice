import SwiftUI

extension VoiceEngineSettingsView {
    /// A model row in the Voice Engine list. While Grok Speech is previewed, its sign-in options sit
    /// under its row. They belong inside the scrolling list: in the fixed header above it, their height
    /// raised the window's minimum height past the screen.
    @ViewBuilder
    func speechModelRow(for model: SettingsStore.SpeechModel) -> some View {
        if model == .grokSTT {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 6) {
                    self.speechModelCard(for: model)

                    if self.viewModel.previewSpeechModel == model {
                        GrokSTTCredentialsPanel(settings: self.settings, theme: self.theme)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(self.theme.palette.cardBackground.opacity(0.5))
                            )
                            .padding(.leading, 56)
                            .id(GrokSTTCredentialsPanel.scrollID)
                    }
                }
                .onChange(of: self.viewModel.previewSpeechModel) { _, newValue in
                    guard newValue == .grokSTT else { return }
                    // Grok is often the last row, so its options would open below the visible list.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(GrokSTTCredentialsPanel.scrollID, anchor: .bottom)
                        }
                    }
                }
            }
        } else {
            self.speechModelCard(for: model)
        }
    }
}

/// One-line sign-in status for the Voice Engine header. It never wraps, so the header keeps its height.
struct GrokSTTStatusLine: View {
    @ObservedObject var settings: SettingsStore
    let theme: AppTheme

    var body: some View {
        let isReady = GrokSTTCredentialsPanel.canActivate(.grokSTT)
        Label(self.text(isReady: isReady), systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(isReady ? Color.fluidGreen : .orange)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func text(isReady: Bool) -> String {
        switch self.settings.grokSTTAuthMode {
        case .apiKey:
            return isReady ? "Signs in with your xAI API key" : "Needs an xAI API key from AI Providers"
        case .grokCLISession:
            return isReady ? "Signs in with your Grok CLI session" : "No Grok CLI session found"
        }
    }
}

/// Credentials for Grok Speech, shown under the Grok row while it is previewed in Voice Engine settings.
/// The API key itself lives under AI Providers; this only picks how Grok Speech signs in.
struct GrokSTTCredentialsPanel: View {
    @ObservedObject var settings: SettingsStore
    let theme: AppTheme

    static let scrollID = "grok-stt-credentials-panel"

    @State private var cliStatus: GrokCLISessionStatus = .missing
    @State private var cliPathDraft = ""

    /// Cheap check for the Activate button: no network, and no auth.json parse on each render.
    static func canActivate(_ model: SettingsStore.SpeechModel) -> Bool {
        guard model == .grokSTT else { return true }
        switch SettingsStore.shared.grokSTTAuthMode {
        case .apiKey:
            return GrokSTTSharedXAIKeyStore().hasAPIKey
        case .grokCLISession:
            return SettingsStore.hasGrokCLISessionFile
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sign in with", selection: self.authModeBinding) {
                ForEach(GrokSTTAuthMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            switch self.settings.grokSTTAuthMode {
            case .apiKey:
                self.statusRow(
                    isReady: GrokSTTSharedXAIKeyStore().hasAPIKey,
                    readyText: GrokSTTSettingsCopy.apiKeyConfigured,
                    missingText: GrokSTTSettingsCopy.apiKeyMissing
                )
                self.note(GrokSTTSettingsCopy.apiKeyBilling + " " + GrokSTTSettingsCopy.sharedKeyRemoval)
            case .grokCLISession:
                self.statusRow(isReady: self.cliStatusIsReady, readyText: self.cliStatusText, missingText: self.cliStatusText)
                self.note(GrokSTTSettingsCopy.cliSessionExperimental)
                HStack(spacing: 6) {
                    TextField("grok CLI path (optional, for session refresh)", text: self.$cliPathDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(self.theme.typography.bodySmall)
                    Button("Save") {
                        self.settings.grokCLIBinaryPath = self.cliPathDraft
                        self.refreshCLIStatus()
                    }
                    .controlSize(.small)
                    .disabled(self.cliPathDraft.trimmingCharacters(in: .whitespacesAndNewlines) == (self.settings.grokCLIBinaryPath ?? ""))
                }
                .frame(maxWidth: 420)
            }

            self.note(GrokSTTSettingsCopy.clientKeyDeviation)
        }
        .padding(.top, 4)
        .onAppear { self.refreshCLIStatus() }
    }

    private var authModeBinding: Binding<GrokSTTAuthMode> {
        Binding(
            get: { self.settings.grokSTTAuthMode },
            set: { newValue in
                guard newValue != self.settings.grokSTTAuthMode else { return }
                self.settings.grokSTTAuthMode = newValue
                self.refreshCLIStatus()
                // A prepared provider may hold the other mode's readiness.
                if self.settings.selectedSpeechModel == .grokSTT {
                    AppServices.shared.asr.resetTranscriptionProvider()
                }
            }
        )
    }

    private var cliStatusIsReady: Bool {
        if case .available = self.cliStatus { return true }
        return false
    }

    private var cliStatusText: String {
        switch self.cliStatus {
        case .missing:
            return "No Grok CLI session found. Sign in with the grok CLI (or Grok Build) first."
        case .unreadable, .parseFailed:
            return "Couldn't read your Grok CLI session file."
        case .empty:
            return "Your Grok CLI session file has no usable sign-in."
        case let .available(email, expired):
            let account = email.map { " for \($0)" } ?? ""
            return expired
                ? "Session found\(account), but it has expired. FluidVoice will try to refresh it with the grok CLI."
                : "Session found\(account)."
        }
    }

    private func refreshCLIStatus() {
        self.cliPathDraft = self.settings.grokCLIBinaryPath ?? ""
        guard self.settings.grokSTTAuthMode == .grokCLISession else { return }
        Task.detached(priority: .userInitiated) {
            let status = GrokCLIAuthStore().sessionStatus()
            await MainActor.run { self.cliStatus = status }
        }
    }

    private func statusRow(isReady: Bool, readyText: String, missingText: String) -> some View {
        Label(
            isReady ? readyText : missingText,
            systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(self.theme.typography.bodySmall)
        .foregroundStyle(isReady ? Color.fluidGreen : .orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Language menu shown next to the Active badge.
struct GrokSTTLanguageMenu: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Menu {
            Button {
                self.settings.selectedGrokSTTLanguageCode = nil
            } label: {
                self.row(title: "Automatic", isSelected: self.settings.selectedGrokSTTLanguageCode == nil)
            }
            Divider()
            ForEach(self.sortedCodes, id: \.self) { code in
                Button {
                    self.settings.selectedGrokSTTLanguageCode = code
                } label: {
                    self.row(title: GrokSTTLanguage.displayName(for: code), isSelected: self.settings.selectedGrokSTTLanguageCode == code)
                }
            }
        } label: {
            Label(GrokSTTLanguage.displayName(for: self.settings.selectedGrokSTTLanguageCode), systemImage: "globe")
        }
        .fluidDropdownStyle()
    }

    private var sortedCodes: [String] {
        GrokSTTLanguage.codes.sorted {
            GrokSTTLanguage.displayName(for: $0).localizedCaseInsensitiveCompare(GrokSTTLanguage.displayName(for: $1)) == .orderedAscending
        }
    }

    @ViewBuilder
    private func row(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }
}
