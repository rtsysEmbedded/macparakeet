import AppKit
import Foundation
import MacParakeetCore
import MacParakeetViewModels
import OSLog

/// Global "make a flashcard from the selection" shortcut. On trigger it reads
/// the text selected in the frontmost app (AX first, Cmd+C fallback, the
/// clipboard is restored afterwards) and opens the quick-card panel, which
/// asks the AI provider for the card.
@MainActor
final class FlashcardHotkeyCoordinator {
    private let repository: FlashcardRepositoryProtocol
    private let llmServiceProvider: () -> LLMServiceProtocol?
    private let onCardsSaved: () -> Void
    private let onLLMProviderRequired: () -> Void
    private let captureService = SelectionCaptureService()
    private let panelController = QuickFlashcardPanelController()
    private let logger = Logger(subsystem: "com.macparakeet", category: "FlashcardHotkeyCoordinator")

    private var manager: GlobalShortcutManager?
    private var isSuspended = false
    private var isCapturing = false
    private var triggerObserver: NSObjectProtocol?

    init(
        repository: FlashcardRepositoryProtocol,
        llmServiceProvider: @escaping () -> LLMServiceProtocol?,
        onCardsSaved: @escaping () -> Void,
        onLLMProviderRequired: @escaping () -> Void
    ) {
        self.repository = repository
        self.llmServiceProvider = llmServiceProvider
        self.onCardsSaved = onCardsSaved
        self.onLLMProviderRequired = onLLMProviderRequired
    }

    func start() {
        if triggerObserver == nil {
            triggerObserver = NotificationCenter.default.addObserver(
                forName: .flashcardHotkeyTriggerDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.installHotkey() }
            }
        }
        installHotkey()
    }

    func stop() {
        manager?.stop()
        manager = nil
        if let triggerObserver {
            NotificationCenter.default.removeObserver(triggerObserver)
            self.triggerObserver = nil
        }
        panelController.hide()
    }

    /// Paused while a shortcut recorder is listening for keys.
    func suspend() {
        isSuspended = true
        manager?.stop()
        manager = nil
    }

    func resume() {
        isSuspended = false
        installHotkey()
    }

    private func installHotkey() {
        manager?.stop()
        manager = nil
        let trigger = FlashcardQuickCapture.hotkey()
        guard !isSuspended, !trigger.isDisabled else { return }
        let manager = GlobalShortcutManager(trigger: trigger)
        manager.onTrigger = { [weak self] in
            Task { @MainActor in await self?.handleTrigger() }
        }
        if manager.start() {
            self.manager = manager
        } else {
            logger.notice("flashcard_hotkey_unavailable")
        }
    }

    private func handleTrigger() async {
        guard !isCapturing else { return }
        guard let lease = GUIMutationArbiter.shared.acquire(.transform) else {
            panelController.showMessage("Finish the current voice task, then try again.")
            return
        }
        isCapturing = true
        let capture = await captureService.captureSelection()
        await captureService.restoreClipboardCaptureIfCurrent(capture)
        GUIMutationArbiter.shared.release(lease)
        isCapturing = false

        switch capture {
        case .failed(let error):
            panelController.showMessage(error.localizedDescription)
            return
        case .empty:
            panelController.showMessage(FlashcardGenerationError.emptySelection.localizedDescription)
            return
        case .ax, .clipboard:
            break
        }
        guard let text = capture.capturedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            panelController.showMessage(FlashcardGenerationError.emptySelection.localizedDescription)
            return
        }

        let viewModel = FlashcardsViewModel()
        viewModel.configure(
            repository: repository,
            generator: llmServiceProvider().map { FlashcardGenerationService(llmService: $0) }
        )
        panelController.show(
            selection: text,
            viewModel: viewModel,
            onSaved: onCardsSaved,
            onSetUpAI: onLLMProviderRequired
        )
    }
}
