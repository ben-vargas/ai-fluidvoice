import AppKit
import SwiftUI

/// Keeps the audio of the last failed Grok dictation in memory and offers to send it
/// again. Nothing is written to disk and nothing falls back to a local engine.
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
    private var isRetrying = false
    private let now: () -> Date
    private let panel = GrokSTTFailurePanelController()

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var hasPending: Bool {
        guard let pending else { return false }
        return self.now().timeIntervalSince(pending.createdAt) < Self.ttl
    }

    func retain(samples: [Float], error: GrokSTTError, configuration: GrokSTTDictationController.Configuration) {
        let maxSamples = GrokSTTAudioConverter.sampleRate * Int(Self.maxDuration)
        let kept = samples.count > maxSamples ? Array(samples.prefix(maxSamples)) : samples
        self.pending = Pending(samples: kept, createdAt: self.now(), error: error, configuration: configuration)
        GrokSTTLog.info("retry_retained samples=\(kept.count)")
        self.scheduleExpiry()
        self.panel.show(
            message: error.errorDescription ?? "Grok couldn't transcribe that recording.",
            canRetry: error.isRetryable,
            onRetry: { [weak self] in self?.retry() },
            onDismiss: { [weak self] in self?.clear() }
        )
    }

    func clear() {
        self.pending = nil
        self.expiryTask?.cancel()
        self.expiryTask = nil
        self.panel.hide()
    }

    func retry() {
        guard !self.isRetrying, self.hasPending, let pending = self.pending else {
            self.clear()
            return
        }
        self.isRetrying = true
        self.panel.showRetrying()
        Task { @MainActor in
            defer { self.isRetrying = false }
            do {
                let result = try await GrokSTTRESTClient(resolver: GrokSTTCredentialResolver.shared).transcribePCM(
                    pending.samples,
                    languageCode: pending.configuration.languageCode,
                    keyterms: pending.configuration.keyterms
                )
                self.clear()
                await Self.deliver(result)
            } catch {
                let failure = error as? GrokSTTError ?? GrokSTTTransportErrorMapper.map(error)
                GrokSTTLog.error("retry_failed error=\(String(describing: failure))")
                self.retain(samples: pending.samples, error: failure, configuration: pending.configuration)
            }
        }
    }

    /// Applies the same local cleanup as a normal dictation, then types into the focused field.
    /// AI cleanup styles are not re-run for a retried recording.
    private static func deliver(_ rawText: String) async {
        let cleaned = ASRService.applySpokenPunctuationFormatting(
            ASRService.applyCustomDictionary(ASRService.removeFillerWords(rawText))
        )
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let result = await AppServices.shared.asr.typeTextToActiveField(cleaned)
        if case let .recoverableFailure(failure) = result,
           let kind = DeliveryFailureOverlayController.Kind(failure: failure)
        {
            DeliveryFailureOverlayController.shared.show(kind: kind, transcript: cleaned)
        }
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

    func show(message: String, canRetry: Bool, onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.state.message = message
        self.state.canRetry = canRetry
        self.state.isRetrying = false
        self.state.onRetry = onRetry
        self.state.onDismiss = onDismiss
        self.render()
    }

    func showRetrying() {
        self.state.isRetrying = true
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
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}
}

private struct GrokSTTFailureView: View {
    let state: GrokSTTFailureState
    @State private var isRetryHovered = false
    @State private var isDismissHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "icloud.slash")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.orange.opacity(0.14)))
                Text("Grok couldn't transcribe that")
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 8)
            }

            Text(self.state.message)
                .font(.fluidSystem(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(self.state.canRetry ? "Your recording is kept for 15 minutes." : "Fix this in Voice Engine settings, then dictate again.")
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Dismiss", action: self.state.onDismiss)
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isDismissHovered))
                    .onHover { self.isDismissHovered = $0 }
                if self.state.canRetry {
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
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isRetryHovered))
                    .onHover { self.isRetryHovered = $0 }
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
}
