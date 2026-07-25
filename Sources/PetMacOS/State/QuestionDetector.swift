import Foundation

/// Decides whether Claude's final reply ended by *asking the user something*
/// rather than reporting that it finished.
///
/// Claude Code sends no event for "I asked a question and I'm waiting" — the
/// turn simply ends, so the `Stop` hook fires exactly as it does for a finished
/// job. Without this the pet cheerfully shows "Hoàn thành" while the terminal
/// sits there waiting for an answer, which is precisely when the user most
/// needs to be told. (Ported from AgentPet's `QuestionDetector`, with the
/// markdown pass and the Vietnamese patterns added — see below.)
///
/// Pure string logic: no I/O, no state, so it stays cheap and testable.
enum QuestionDetector {
    /// Openers that make a sentence a direct request for the user's decision
    /// even without a question mark ("Should I go ahead and run it").
    private static let questionStarters = [
        "which ", "what ", "how ", "should i", "do you", "want me to",
        "shall i", "would you", "can you", "could you", "are you",
        // Vietnamese equivalents. The pet is used in Vietnamese as much as in
        // English, and a Vietnamese question is regularly written without the
        // mark ("Muốn mình commit luôn").
        "muốn mình", "bạn muốn", "có muốn", "mình có nên", "nên dùng",
        "chọn cái nào", "cái nào", "bạn chọn", "cần mình",
    ]

    /// Polite tails appended *after* a finished summary. These are offers, not
    /// blocking questions — a card that says "waiting for you" every time
    /// Claude signs off with "let me know if you need anything" would cry wolf
    /// on nearly every turn.
    private static let optionalFollowUpPatterns = [
        "let me know if", "let me know when", "feel free to",
        "if you'd like any", "if you want any", "if you want to",
        "if you'd like to", "if you need any", "say which one",
        "say the word", "if anything else", "happy to help",
        "happy to make", "don't hesitate", "just let me know",
        // Vietnamese
        "cứ nói nếu", "cứ bảo", "báo mình nếu", "nếu cần thêm",
        "nếu muốn thêm", "có gì cứ", "cần gì cứ",
    ]

    /// True when the reply's last sentence is a direct question.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let plain = plainTail(of: text)
        guard !plain.isEmpty else { return false }
        let last = lastSentence(of: plain).lowercased()
        guard !last.isEmpty else { return false }
        if optionalFollowUpPatterns.contains(where: last.contains) { return false }
        if last.hasSuffix("?") { return true }
        return questionStarters.contains(where: last.hasPrefix)
    }

    // MARK: - Private

    /// Strips the markup Claude's replies are full of before any sentence
    /// splitting happens.
    ///
    /// This is the part AgentPet's version doesn't do, and without it the
    /// detector misses the most common shape of all: a reply that ends with a
    /// question and then a fenced command block. Taking the "last sentence" of
    /// the raw text would land on `scripts/build-release.sh` instead of the
    /// question above it. Trailing code fences, bare list items and headings
    /// are dropped; the last line that reads like prose is what gets judged.
    private static func plainTail(of text: String) -> String {
        var inFence = false
        var prose: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            // Headings and table rows are structure, never the closing question.
            if line.hasPrefix("#") || line.hasPrefix("|") { continue }
            prose.append(PlainText.firstLine(of: line))
        }
        // The closing question is the last prose line; earlier lines can't be
        // "the last sentence" no matter what they contain.
        return prose.last ?? ""
    }

    private static func lastSentence(of text: String) -> String {
        var segments: [String] = []
        var current = ""
        for character in text.replacingOccurrences(of: "\n", with: " ") {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { segments.append(sentence) }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespaces)
        if !remainder.isEmpty { segments.append(remainder) }
        return segments.last ?? text
    }
}
