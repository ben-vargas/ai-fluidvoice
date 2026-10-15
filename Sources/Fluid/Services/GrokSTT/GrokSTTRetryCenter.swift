import AppKit
import SwiftUI

/// Keeps the audio of the last failed Grok dictation in memory and offers to send it
/// again. Nothing is written to disk and nothing falls back to a local engine.
///
/// A recovered transcript is shown for the user to copy, never typed automatically:
/// the failed recording may have been an Edit, Command or prompt-test capture, and
/// only ContentView knows how to route those.
@MainActor
final class GrokSTTRetryCenter {
    static let shared = GrokSTTRetryCenter()

    static let maxDuration: TimeInterval = 10 * 60
    static let ttl: TimeInterval = 15 * 60

    struct Pending {
        let samples: [Float]
        let createdAt: Date
        let error: GrokSTTError
        let configuration: GrokSTTDictationController.Configuration
    }

    private(set) var pending: Pending?
    private var expiryTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// Changes whenever the panel's content is replaced or dismissed, so a retry that
    /// finishes afterwards can tell its result is no longer wanted.
    private var attemptID = UUID()
    private let now: () -> Date
    private let panel = GrokSTTFailurePanelController()

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var hasPending: Bool {
        guard let pending else { return false }
        return self.now().timeIntervalSince(pending.createdAt) < Self.ttl
    }

    var isRetrying: Bool {
        self.retryTask != nil
    }

    func retain(samples: [Float], error: GrokSTTError, configuration: GrokSTTDictationController.Configuration) {
        self.invalidateAttempt()
        let maxSamples = GrokSTTAudioConverter.sampleRate * Int(Self.maxDuration)
        let kept = samples.count > maxSamples ? Array(samples.prefix(maxSamples)) : samples
        self.pending = Pending(samples: kept, createdAt: self.now(), error: error, configuration: configuration)
        GrokSTTLog.info("retry_retained samples=\(kept.count)")
        self.scheduleExpiry()
        self.panel.showFailure(
            message: error.errorDescription ?? "Grok couldn't transcribe that recording.",
            canRetry: error.isRetryable,
            onRetry: { [weak self] in self?.retry() },
            onDismiss: { [weak self] in self?.clear() }
        )
    }

    /// Drops the kept audio, cancels any retry in flight, and hides the panel.
    func clear() {
        self.invalidateAttempt()
        self.pending = nil
        self.expiryTask?.cancel()
        self.expiryTask = nil
        self.panel.hide()
    }

    func retry() {
        guard self.retryTask == nil, self.hasPending, let pending = self.pending else {
            if self.retryTask == nil { self.clear() }
            return
        }
        let attempt = UUID()
        self.attemptID = attempt
        self.panel.showRetrying()
        self.retryTask = Task { @MainActor [weak self] in
            let outcome: Result<String, GrokSTTError>
            do {
                let text = try await GrokSTTRESTClient(resolver: GrokSTTCredentialResolver.shared).transcribePCM(
                    pending.samples,
                    languageCode: pending.configuration.languageCode,
                    keyterms: pending.configuration.keyterms
                )
                outcome = .success(text)
            } catch {
                outcome = .failure(error as? GrokSTTError ?? GrokSTTTransportErrorMapper.map(error))
            }
            guard let self, !Task.isCancelled, self.attemptID == attempt else { return }
            self.retryTask = nil
            switch outcome {
            case let .success(text):
                self.showRecovered(text)
            case .failure(.emptyTranscript), .failure(.invalidAudio):
                self.clear()
            case let .failure(failure):
                GrokSTTLog.error("retry_failed error=\(String(describing: failure))")
                self.retain(samples: pending.samples, error: failure, configuration: pending.configuration)
            }
        }
    }

    /// Applies the same local cleanup as a normal dictation and shows the text with a Copy
    /// button. The audio is no longer needed once the text exists.
    private func showRecovered(_ rawText: String) {
        let cleaned = ASRService.applySpokenPunctuationFormatting(
            ASRService.applyCustomDictionary(ASRService.removeFillerWords(rawText))
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            self.clear()
            return
        }
        self.pending = nil
        self.scheduleExpiry()
        self.panel.showRecovered(
            text: cleaned,
            onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cleaned, forType: .string)
                self?.clear()
            },
            onDismiss: { [weak self] in self?.clear() }
        )
    }

    private func invalidateAttempt() {
        self.retryTask?.cancel()
        self.retryTask = nil
        self.attemptID = UUID()
    }

    private func scheduleExpiry() {
        self.expiryTask?.cancel()
        self.expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.ttl * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }
}

extension GrokSTTError {
    /// Failures where sending the same audio again can succeed without changing settings.
    var isRetryable: Bool {
        switch self {
        case .offline, .timeout, .rateLimited, .server, .socketClosed, .refreshInProgress, .grokSessionExpired, .unauthorized:
            return true
        case .noCredentialConfigured, .grokCLINotFound, .grokStoreUnreadable, .grokStoreParseFailed, .forbidden,
             .emptyTranscript, .cancelled, .invalidAudio, .fileTooLarge, .unsupportedFile,
             .dictionaryTrainingUnsupported, .videoUploadForbidden:
            return false
        }
    }
}

// MARK: - Panel

@MainActor
private final class GrokSTTFailurePanelController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<GrokSTTFailureView>?
    private var state = GrokSTTFailureState()

    func showFailure(message: String, canRetry: Bool, onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.state = GrokSTTFailureState(
            message: message,
            canRetry: canRetry,
            onRetry: onRetry,
            onDismiss: onDismiss
        )
        self.render()
    }

    func showRetrying() {
        self.state.isRetrying = true
        self.render()
    }

    func showRecovered(text: String, onCopy: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.state = GrokSTTFailureState(
            recoveredText: text,
            onDismiss: onDismiss,
            onCopy: onCopy
        )
        self.render()
    }

    func hide() {
        self.panel?.orderOut(nil)
    }

    private func render() {
        let view = GrokSTTFailureView(state: self.state)
        if let hostingView = self.hostingView {
            hostingView.rootView = view
        } else {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            let hostingView = NSHostingView(rootView: view)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear
            panel.contentView = hostingView
            self.panel = panel
            self.hostingView = hostingView
        }
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - ceil(size.width) / 2,
                y: screen.visibleFrame.minY + 10,
                width: ceil(size.width),
                height: ceil(size.height)
            ),
            display: true
        )
        panel.orderFrontRegardless()
    }
}

private struct GrokSTTFailureState {
    var message = ""
    var canRetry = true
    var isRetrying = false
    /// Set once a retry succeeds; the panel then offers the text for copying.
    var recoveredText: String?
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onCopy: () -> Void = {}
}

private struct GrokSTTFailureView: View {
    let state: GrokSTTFailureState
    @State private var isPrimaryHovered = false
    @State private var isDismissHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: self.isRecovered ? "checkmark.icloud" : "icloud.slash")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(self.accent.opacity(0.95))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(self.accent.opacity(0.14)))
                Text(self.isRecovered ? "Grok recovered that recording" : "Grok couldn't transcribe that")
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 8)
            }

            Text(self.state.recoveredText ?? self.state.message)
                .font(.fluidSystem(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(self.isRecovered ? 6 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(self.footnote)
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Dismiss", action: self.state.onDismiss)
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isDismissHovered))
                    .onHover { self.isDismissHovered = $0 }
                if self.isRecovered {
                    Button(action: self.state.onCopy) {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.doc")
                                .font(.fluidSystem(size: 10, weight: .semibold))
                            Text("Copy")
                        }
                    }
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isPrimaryHovered))
                    .onHover { self.isPrimaryHovered = $0 }
                } else if self.state.canRetry {
                    Button(action: self.state.onRetry) {
                        HStack(spacing: 5) {
                            if self.state.isRetrying {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.fluidSystem(size: 10, weight: .semibold))
                            }
                            Text(self.state.isRetrying ? "Retrying…" : "Retry")
                        }
                    }
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isPrimaryHovered))
                    .onHover { self.isPrimaryHovered = $0 }
                    .disabled(self.state.isRetrying)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 440)
        .background(TransientOverlayBackground())
        .preferredColorScheme(.dark)
    }

    private var isRecovered: Bool {
        self.state.recoveredText != nil
    }

    private var accent: Color {
        self.isRecovered ? Color.fluidGreen : Color.orange
    }

    private var footnote: String {
        if self.isRecovered { return "Copy it, then paste where you need it." }
        return self.state.canRetry ? "Your recording is kept for 15 minutes." : "Fix this in Voice Engine settings, then dictate again."
    }
}
