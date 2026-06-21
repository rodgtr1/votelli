import Foundation

/// Cleans raw Whisper output before it's typed: removes non-speech annotations
/// Whisper emits on silence/noise, and normalizes whitespace.
public enum TextProcessing {
    private static let nonSpeechWords: Set<String> = [
        "silence", "blank", "blank_audio", "music", "applause", "laughter",
        "noise", "wind", "typing", "clicking", "beep", "static", "inaudible",
        "coughing", "breathing", "sighs", "chuckles"
    ]

    /// Returns cleaned text, or "" if nothing of substance remains.
    public static func clean(_ raw: String) -> String {
        var text = raw
        // Square-bracket annotations are always Whisper non-speech, e.g. [BLANK_AUDIO].
        text = replacingRegex(text, pattern: "\\[[^\\]]*\\]", with: " ")
        // Parenthetical groups only when they read as non-speech, e.g. (wind blowing).
        text = removeNonSpeechParentheticals(text)
        // Collapse runs of whitespace.
        text = replacingRegex(text, pattern: "\\s+", with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeNonSpeechParentheticals(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\([^\\)]*\\)") else { return text }
        let ns = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let inner = ns.substring(with: match.range).lowercased()
            if nonSpeechWords.contains(where: { inner.contains($0) }) {
                let mutable = result as NSString
                result = mutable.replacingCharacters(in: match.range, with: " ")
            }
        }
        return result
    }

    private static func replacingRegex(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
