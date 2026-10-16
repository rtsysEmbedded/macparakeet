import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class FlashcardsViewModelSelectionTests: XCTestCase {
    private var repository: FlashcardRepository!
    private var generator: StubFlashcardGenerator!
    private var viewModel: FlashcardsViewModel!

    override func setUp() async throws {
        repository = FlashcardRepository(dbQueue: try DatabaseManager().dbQueue)
        generator = StubFlashcardGenerator()
        viewModel = FlashcardsViewModel()
        viewModel.configure(repository: repository, generator: generator)
    }

    func testShortSelectionMakesOneCardWithoutSurroundingPunctuation() async throws {
        generator.card = FlashcardDraft(front: "gehen", back: "to go")
        viewModel.generateDrafts(fromSelection: " „ging“, ", meaningLanguage: .english)
        await waitForGeneration()

        XCTAssertEqual(viewModel.drafts.map(\.front), ["gehen"])
        XCTAssertEqual(generator.cardRequests, ["ging"])
        XCTAssertTrue(generator.transcriptRequests.isEmpty)
    }

    func testWordAlreadyInADeckIsReportedInsteadOfDrafted() async throws {
        let deck = try repository.findOrCreateDeck(named: "German")
        try repository.insert([Flashcard(deckId: deck.id, front: "die Bank", back: "bench")])
        generator.card = FlashcardDraft(front: "Bank", back: "bench")

        viewModel.generateDrafts(fromSelection: "Bank", meaningLanguage: .english)
        await waitForGeneration()

        XCTAssertTrue(viewModel.drafts.isEmpty)
        XCTAssertEqual(viewModel.statusMessage, "“Bank” is already in your decks.")
    }

    func testLongSelectionIsScannedForVocabulary() async {
        generator.transcriptResult = [FlashcardDraft(front: "der Zug", back: "train")]
        viewModel.generateDrafts(fromSelection: "Ich bin heute mit dem Zug gefahren.", meaningLanguage: .english)
        await waitForGeneration()

        XCTAssertEqual(viewModel.drafts.map(\.front), ["der Zug"])
        XCTAssertEqual(generator.transcriptRequests, ["Ich bin heute mit dem Zug gefahren."])
        XCTAssertTrue(generator.cardRequests.isEmpty)
    }

    func testEmptySelectionShowsAnError() {
        viewModel.generateDrafts(fromSelection: "  ", meaningLanguage: .english)
        XCTAssertFalse(viewModel.isGenerating)
        XCTAssertEqual(viewModel.errorMessage, FlashcardGenerationError.emptySelection.localizedDescription)
    }

    private func waitForGeneration() async {
        for _ in 0..<200 where viewModel.isGenerating {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(viewModel.isGenerating)
    }
}

private final class StubFlashcardGenerator: FlashcardGenerating, @unchecked Sendable {
    var card = FlashcardDraft(front: "", back: "")
    var transcriptResult: [FlashcardDraft] = []
    var cardRequests: [String] = []
    var transcriptRequests: [String] = []

    func generate(
        from transcript: String,
        style: FlashcardStyle,
        meaningLanguage: TranslationLanguage,
        maxCards: Int,
        focus: FlashcardFocus,
        excluding knownKeys: Set<String>
    ) async throws -> [FlashcardDraft] {
        transcriptRequests.append(transcript)
        return transcriptResult
    }

    func card(for word: String, context: String?, meaningLanguage: TranslationLanguage) async throws -> FlashcardDraft {
        cardRequests.append(word)
        return card
    }
}
