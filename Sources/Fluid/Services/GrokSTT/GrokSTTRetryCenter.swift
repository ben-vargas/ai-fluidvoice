import AppKit
import SwiftUI

/// Keeps the audio of the last failed Grok dictation in memory and offers to send it
/// again. Nothing is written to disk and nothing falls back to a local engine.
///
/// A recovered transcript of an ordinary dictation goes back through ContentView's reprocess
/// path (AI cleanup, history, typing). ContentView says which recordings those are. It is typed
/// only into the field that had focus when the user clicked Retry, and only if nothing
/// superseded it meanwhile; otherwise it is kept in history and offered for copying. Anything
/// else, such as an Edit, Command or prompt-test capture, is only ever offered for copying.
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
        /// Set by ContentView once it knows the failed recording was an ordinary dictation.
        var isPlainDictation = false
    }

    /// Finishes a recovered dictation through ContentView's reprocess path. ContentView installs it.
    var deliverRecoveredDictation: (@MainActor (String, GrokSTTRecoveredDelivery) async -> Void)?

    /// Text currently offered with a Copy button.
    private(set) var recoveredTextForCopy: String?
    /// The delivery in progress. Only a new recording takes it away.
    private var activeDeliveryID: UUID?

    private(set) var pending: Pending?
    private var expiryTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// Changes whenever the panel's content is replaced or dismissed, so a retry that
    /// finishes afterwards can tell its result is no longer wanted.
    private var attemptID = UUID()
    private let now: () -> Date
    private let transcribe: Transcriber
    private let captureFocus: @MainActor () -> TypingService.CapturedFocusTarget?
    private let isFocusActive: @MainActor (TypingService.CapturedFocusTarget) -> Bool
    /// `nil` in tests, which have no screen to put a panel on.
    private let panel: GrokSTTFailurePanelController?

    typealias Transcriber = @MainActor ([Float], GrokSTTDictationController.Configuration) async throws -> String

    init(
        now: @escaping () -> Date = Date.init,
        transcribe: Transcriber? = nil,
        showsPanel: Bool = true,
        captureFocus: @escaping @MainActor () -> TypingService.CapturedFocusTarget? = TypingService.captureSystemFocusTarget,
        isFocusActive: @escaping @MainActor (TypingService.CapturedFocusTarget) -> Bool = TypingService.isExactFocusTargetActive
    ) {
        self.now = now
        self.captureFocus = captureFocus
        self.isFocusActive = isFocusActive
        self.transcribe = transcribe ?? { samples, configuration in
            try await GrokSTTRESTClient(resolver: GrokSTTCredentialResolver.shared).transcribePCM(
                samples,
                languageCode: configuration.languageCode,
                keyterms: configuration.keyterms
            )
        }
        self.panel = showsPanel ? GrokSTTFailurePanelController() : nil
    }

    /// The retry in flight, so tests can wait for it.
    var retryInFlight: Task<Void, Never>? {
        self.retryTask
    }

    var hasPending: Bool {
        guard let pending else { return false }
        return self.now().timeIntervalSince(pending.createdAt) < Self.ttl
    }

    var isRetrying: Bool {
        self.retryTask != nil
    }

    func retain(
        samples: [Float],
        error: GrokSTTError,
        configuration: GrokSTTDictationController.Configuration,
        isPlainDictation: Bool = false
    ) {
        self.invalidateAttempt()
        let maxSamples = GrokSTTAudioConverter.sampleRate * Int(Self.maxDuration)
        let kept = samples.count > maxSamples ? Array(samples.prefix(maxSamples)) : samples
        self.pending = Pending(
            samples: kept,
            createdAt: self.now(),
            error: error,
            configuration: configuration,
            isPlainDictation: isPlainDictation
        )
        GrokSTTLog.info("retry_retained samples=\(kept.count)")
        self.scheduleExpiry()
        self.panel?.showFailure(
            message: error.errorDescription ?? "Grok couldn't transcribe that recording.",
            canRetry: error.isRetryable,
            onRetry: { [weak self] in self?.retry() },
            onDismiss: { [weak self] in self?.clear() }
        )
    }

    /// ContentView reports what the recording that just came back empty was. Only an ordinary
    /// dictation may be typed after a retry: the normal route, not an Edit or Command capture,
    /// not a prompt test (even one whose editor has since closed), and not cancelled with Escape.
    func noteEmptyResult(isNormalRoute: Bool, wasEdit: Bool, wasCommand: Bool, wasPromptTest: Bool, wasCancelled: Bool) {
        guard isNormalRoute, !wasEdit, !wasCommand, !wasPromptTest, !wasCancelled else { return }
        self.pending?.isPlainDictation = true
    }

    /// Every recording, on any engine, takes over from an older failure: its audio, a retry in
    /// flight, and a delivery that has not finished typing. ASRService calls this as capture starts.
    func recordingWillStart() {
        self.activeDeliveryID = nil
        self.clear()
    }

    /// Drops the kept audio, cancels any retry in flight, and hides the panel.
    func clear() {
        self.invalidateAttempt()
        self.recoveredTextForCopy = nil
        self.pending = nil
        self.expiryTask?.cancel()
        self.expiryTask = nil
        self.panel?.hide()
    }

    func retry() {
        guard self.retryTask == nil, self.hasPending, let pending = self.pending else {
            if self.retryTask == nil { self.clear() }
            return
        }
        let attempt = UUID()
        self.attemptID = attempt
        // The panel does not take focus, so this is the field the user means the text for.
        let focus = pending.isPlainDictation ? self.captureFocus() : nil
        self.panel?.showRetrying()
        self.retryTask = Task { @MainActor [weak self] in
            let outcome: Result<String, GrokSTTError>
            do {
                guard let transcribe = self?.transcribe else { return }
                outcome = .success(try await transcribe(pending.samples, pending.configuration))
            } catch {
                outcome = .failure(error as? GrokSTTError ?? GrokSTTTransportErrorMapper.map(error))
            }
            guard let self, !Task.isCancelled, self.attemptID == attempt else { return }
            self.retryTask = nil
            switch outcome {
            case let .success(text):
                self.finishRecovered(text, isPlainDictation: pending.isPlainDictation, focus: focus)
            case .failure(.emptyTranscript), .failure(.invalidAudio):
                self.clear()
            case let .failure(failure):
                GrokSTTLog.error("retry_failed error=\(String(describing: failure))")
                self.retain(
                    samples: pending.samples,
                    error: failure,
                    configuration: pending.configuration,
                    isPlainDictation: pending.isPlainDictation
                )
            }
        }
    }

    /// Applies the same local cleanup ASRService gives a normal dictation. An ordinary dictation
    /// then finishes through ContentView; anything else is shown with a Copy button. The audio
    /// is no longer needed once the text exists.
    private func finishRecovered(_ rawText: String, isPlainDictation: Bool, focus: TypingService.CapturedFocusTarget?) {
        let cleaned = ASRService.applySpokenPunctuationFormatting(
            ASRService.applyCustomDictionary(ASRService.removeFillerWords(rawText))
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            self.clear()
            return
        }
        guard isPlainDictation, let deliver = self.deliverRecoveredDictation else {
            self.offerForCopy(cleaned)
            return
        }
        GrokSTTLog.info("retry_recovered delivering as dictation")
        self.clear()
        let id = UUID()
        self.activeDeliveryID = id
        let delivery = GrokSTTRecoveredDelivery(
            isCurrent: { [weak self] in self?.activeDeliveryID == id },
            isFieldFocused: { [isFocusActive] in focus.map(isFocusActive) ?? false },
            onLostFocus: { [weak self] finalText in
                GrokSTTLog.info("retry_recovered not typed: the field from the Retry click lost focus")
                self?.offerForCopy(finalText)
            }
        )
        Task { @MainActor [weak self] in
            // A recording may have started since the upload finished.
            guard self?.activeDeliveryID == id else { return }
            await deliver(cleaned, delivery)
            if self?.activeDeliveryID == id { self?.activeDeliveryID = nil }
        }
    }

    /// Shows recovered text with a Copy button. Also used when a delivery cannot start.
    func offerForCopy(_ text: String) {
        self.pending = nil
        self.recoveredTextForCopy = text
        self.scheduleExpiry()
        self.panel?.showRecovered(
            text: text,
            onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
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

// MARK: - Delivery

/// What a recovered dictation is still allowed to do while ContentView's reprocess path finishes
/// it. Reprocess asks before typing, hands `allowsOutput` to every step of upstream's paste
/// pipeline, and asks `isSuperseded` before it tears its overlay down.
///
/// Before the paste command goes out, output is allowed only while nothing has taken over and the
/// field from the Retry click still has focus. After it has gone out, output stays allowed: upstream
/// settles the clipboard and verifies the paste later, and those steps must see it as valid.
@MainActor
final class GrokSTTRecoveredDelivery {
    enum Decision: Equatable {
        /// Type it: the field from the Retry click still has focus.
        case type
        /// Keep it in history without typing, because the destination is gone or Escape was pressed.
        case keepWithoutTyping
        /// A newer recording owns the app now. Do nothing more, not even UI cleanup.
        case abandon
    }

    private let isCurrent: () -> Bool
    private let isFieldFocused: () -> Bool
    private let onLostFocus: (String) -> Void
    private var appSuperseded: () -> Bool = { false }
    private var appCancelled: () -> Bool = { false }
    private var lostFocus = false
    private(set) var hasTyped = false

    init(isCurrent: @escaping () -> Bool, isFieldFocused: @escaping () -> Bool, onLostFocus: @escaping (String) -> Void) {
        self.isCurrent = isCurrent
        self.isFieldFocused = isFieldFocused
        self.onLostFocus = onLostFocus
    }

    /// For reprocess's own callers, which have nothing to check: always type.
    static var unrestricted: GrokSTTRecoveredDelivery {
        GrokSTTRecoveredDelivery(isCurrent: { true }, isFieldFocused: { true }, onLostFocus: { _ in })
    }

    /// ContentView adds what only it can see: a newer recording's overlay, and Escape.
    func restricted(supersededWhen superseded: @escaping () -> Bool, cancelledWhen cancelled: @escaping () -> Bool) -> GrokSTTRecoveredDelivery {
        self.appSuperseded = superseded
        self.appCancelled = cancelled
        return self
    }

    /// A newer recording took over. Reprocess then leaves the overlay and mode to that recording.
    var isSuperseded: Bool {
        !self.isCurrent() || self.appSuperseded()
    }

    /// Safe to ask repeatedly. Once the field has lost focus the text is offered for copying and
    /// the answer stays `.keepWithoutTyping`, even if focus comes back.
    func decision(for finalText: String) -> Decision {
        if self.isSuperseded { return .abandon }
        if self.lostFocus || self.appCancelled() { return .keepWithoutTyping }
        if self.isFieldFocused() { return .type }
        self.lostFocus = true
        self.onLostFocus(finalText)
        return .keepWithoutTyping
    }

    /// The `isOutputValid` of upstream's focus-restore and paste steps.
    func allowsOutput(_ finalText: String) -> Bool {
        self.hasTyped || self.decision(for: finalText) == .type
    }

    /// Reprocess reports that the paste command went out.
    func didType() {
        self.hasTyped = true
    }
}
