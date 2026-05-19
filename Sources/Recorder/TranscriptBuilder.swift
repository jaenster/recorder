import Foundation

enum TranscriptBuilder {
    /// Merge ME + THEM words by start time, group into speaker turns
    /// (break on speaker change or > 500 ms gap from same speaker),
    /// emit `[mm:ss] ME/THEM: ...` lines.
    ///
    /// `themLabel` overrides the literal "THEM" — used when calendar
    /// metadata identifies a 1:1 counterparty by name.
    static func format(me: [Word], them: [Word], themLabel: String? = nil) -> String {
        let themDisplay = (themLabel?.isEmpty == false) ? themLabel! : SpeakerLabel.them.rawValue
        let all = (me + them).sorted { $0.start < $1.start }
        if all.isEmpty { return "" }

        struct Turn {
            let speaker: SpeakerLabel
            let startSeconds: Double
            var words: [String]
            var lastWordStart: Double
        }

        var turns: [Turn] = []

        // Break only on speaker change. Within a channel = one speaker by
        // construction (channel-as-speaker), so any time gap is just a pause
        // in the same person's speech and should stay in the same block.
        for word in all {
            if let last = turns.last, last.speaker == word.speaker {
                turns[turns.count - 1].words.append(word.text)
                turns[turns.count - 1].lastWordStart = word.start
            } else {
                turns.append(Turn(
                    speaker: word.speaker,
                    startSeconds: word.start,
                    words: [word.text],
                    lastWordStart: word.start
                ))
            }
        }

        return turns.map { turn in
            let label = turn.speaker == .them ? themDisplay : turn.speaker.rawValue
            return "[\(formatTime(turn.startSeconds))] \(label.uppercased()): \(joinWords(turn.words))"
        }.joined(separator: "\n") + "\n"
    }

    private static func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static func joinWords(_ words: [String]) -> String {
        var out = ""
        for w in words {
            let trimmed = w.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if out.isEmpty {
                out = trimmed
            } else if let first = trimmed.first, ",.?!:;)]}".contains(first) {
                out += trimmed
            } else if let lastChar = out.last, "([{".contains(lastChar) {
                out += trimmed
            } else {
                out += " " + trimmed
            }
        }
        return out
    }
}
