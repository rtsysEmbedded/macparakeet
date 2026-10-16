import AppKit
import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Floating window for the global "make a flashcard from the selection"
/// shortcut. It takes keyboard focus so the card can be edited before saving.
@MainActor
final class QuickFlashcardPanelController {
    private var panel: NSPanel?
    private var autoHideTask: Task<Void, Never>?

    func show(
        selection: String,
        viewModel: FlashcardsViewModel,
        onSaved: @escaping () -> Void,
        onSetUpAI: @escaping () -> Void
    ) {
        present(
            QuickFlashcardView(
                selection: selection,
                viewModel: viewModel,
                onClose: { [weak self] in self?.hide() },
                onSaved: onSaved,
                onSetUpAI: { [weak self] in
                    self?.hide()
                    onSetUpAI()
                }
            ),
            size: NSSize(width: 520, height: 460)
        )
    }

    /// Short notice, e.g. when nothing was selected. Closes by itself.
    func showMessage(_ message: String) {
        present(
            QuickFlashcardMessageView(message: message, onClose: { [weak self] in self?.hide() }),
            size: NSSize(width: 420, height: 90)
        )
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func present<Content: View>(_ view: Content, size: NSSize) {
        hide()
        let panel = QuickFlashcardWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - size.width / 2, y: frame.origin.y + frame.height * 0.62 - size.height / 2))
        }
        self.panel = panel
        // Summoned by a global hotkey while another app is frontmost; the
        // cooperative activate is often declined, so force it.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

/// Takes keyboard focus but never becomes the main window; Escape closes it.
private final class QuickFlashcardWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

private struct QuickFlashcardMessageView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .foregroundStyle(DesignSystem.Colors.accent)
            Text(message)
                .font(DesignSystem.Typography.bodySmall)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("OK", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
    }
}

struct QuickFlashcardView: View {
    let selection: String
    @Bindable var viewModel: FlashcardsViewModel
    let onClose: () -> Void
    let onSaved: () -> Void
    let onSetUpAI: () -> Void

    @AppStorage("flashcards.meaningLanguage") private var languageRaw = TranslationLanguage.english.rawValue
    @AppStorage(FlashcardQuickCapture.deckDefaultsKey) private var deckName = FlashcardQuickCapture.defaultDeckName

    private var language: TranslationLanguage { TranslationLanguage(rawValue: languageRaw) ?? .english }
    private var validCount: Int { viewModel.drafts.filter(\.isValid).count }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Label("New Flashcard", systemImage: "rectangle.on.rectangle.angled")
                    .font(DesignSystem.Typography.sectionTitle)
                Spacer()
                Picker("Meaning in", selection: $languageRaw) {
                    ForEach(TranslationLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .fixedSize()
                .controlSize(.small)
                .disabled(viewModel.isGenerating)
            }

            Text("“\(selection)”")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(3)
                .truncationMode(.tail)

            Divider()
            content

            if let message = viewModel.errorMessage ?? viewModel.statusMessage {
                Label(
                    message,
                    systemImage: viewModel.errorMessage != nil ? "exclamationmark.triangle.fill" : "info.circle.fill"
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(
                    viewModel.errorMessage != nil ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textSecondary)
            }

            footer
        }
        .padding(DesignSystem.Spacing.lg)
        .padding(.top, DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
        .onAppear(perform: generate)
        .onChange(of: languageRaw) { _, _ in
            viewModel.clearDrafts()
            generate()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isGenerating {
            VStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Making the card…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.drafts.isEmpty {
            VStack(spacing: DesignSystem.Spacing.sm) {
                if !viewModel.canGenerate {
                    Text("Making cards automatically needs an AI provider. You can still write the card yourself.")
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Set Up AI…", action: onSetUpAI)
                } else {
                    Button("Try Again", action: generate)
                        .controlSize(.small)
                }
                Button("Write Card Myself") { viewModel.addEmptyDraft(front: selection) }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach($viewModel.drafts) { $draft in
                        draftRow($draft)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Text("Deck")
            TextField("Deck name", text: $deckName)
                .frame(maxWidth: 180)
            if !viewModel.decks.isEmpty {
                Menu {
                    ForEach(viewModel.decks) { summary in
                        Button(summary.deck.name) { deckName = summary.deck.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
            Button("Cancel") {
                viewModel.cancelGeneration()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            Button(validCount > 1 ? "Add \(validCount) Cards" : "Add Card") {
                let name = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
                if viewModel.saveDrafts(
                    toDeckNamed: name.isEmpty ? FlashcardQuickCapture.defaultDeckName : name,
                    sourceTranscriptionId: nil,
                    tag: "macparakeet"
                ) > 0 {
                    onSaved()
                    onClose()
                }
            }
            .parakeetAction(.primaryProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(validCount == 0 || viewModel.isGenerating)
        }
        .controlSize(.small)
    }

    private func draftRow(_ draft: Binding<FlashcardDraft>) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Front", text: draft.front, axis: .vertical)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                TextField("Back", text: draft.back, axis: .vertical)
                    .lineLimit(2...8)
                TextField(
                    "Context (optional)",
                    text: Binding(get: { draft.wrappedValue.context ?? "" }, set: { draft.wrappedValue.context = $0 }),
                    axis: .vertical
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .textFieldStyle(.roundedBorder)
            if viewModel.drafts.count > 1 {
                Button {
                    let id = draft.wrappedValue.id
                    viewModel.drafts.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this card")
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: 8).fill(DesignSystem.Colors.surfaceElevated))
    }

    private func generate() {
        guard viewModel.canGenerate, viewModel.drafts.isEmpty else { return }
        viewModel.generateDrafts(fromSelection: selection, meaningLanguage: language)
    }
}
