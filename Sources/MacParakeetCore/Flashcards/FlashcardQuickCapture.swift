import Foundation

/// Settings for making a card from text selected anywhere on the Mac with a
/// global shortcut.
public enum FlashcardQuickCapture {
    public static let hotkeyDefaultsKey = "flashcardHotkeyTrigger"
    /// ⌃⌥K ("Karte").
    public static let defaultHotkey: HotkeyTrigger = .chord(modifiers: ["control", "option"], keyCode: 40)
    public static let deckDefaultsKey = "flashcards.quickDeck"
    public static let defaultDeckName = "My Words"

    /// Selections up to this many words become one card; longer selections
    /// are scanned for vocabulary like a transcript.
    public static let maxWordsForSingleCard = 4
    /// Longer selections are clipped before they reach the AI provider.
    public static let maxSelectionCharacters = 4_000

    public static func hotkey(defaults: UserDefaults = .standard) -> HotkeyTrigger {
        HotkeyTrigger.current(defaults: defaults, defaultsKey: hotkeyDefaultsKey, fallback: defaultHotkey)
    }

    public static func setHotkey(_ trigger: HotkeyTrigger, defaults: UserDefaults = .standard) {
        trigger.save(to: defaults, defaultsKey: hotkeyDefaultsKey)
        NotificationCenter.default.post(name: .flashcardHotkeyTriggerDidChange, object: nil)
    }

    public static func isSingleCardSelection(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.count <= maxWordsForSingleCard
    }
}

extension Notification.Name {
    public static let flashcardHotkeyTriggerDidChange = Notification.Name("macparakeet.flashcardHotkeyTriggerDidChange")
}
