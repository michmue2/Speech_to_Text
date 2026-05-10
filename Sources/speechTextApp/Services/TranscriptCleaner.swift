import Foundation

struct TranscriptCleaner {
    private struct WordToken {
        let normalized: String
        let range: Range<String.Index>
    }

    private struct SentenceSpan {
        let raw: String
        let normalized: String
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?",
        options: []
    )

    private static let repeatedWordAroundPausePattern = try! NSRegularExpression(
        pattern: #"(?i)\b([\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?)\s*(?:\.\.\.|…)\s+\1\b"#,
        options: []
    )

    private static let weakWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
        "from", "i", "in", "is", "it", "of", "on", "or", "so", "that",
        "the", "this", "to", "was", "we", "with", "you"
    ]

    static func clean(_ text: String) -> String {
        var cleaned = normalizedWhitespace(text)
        cleaned = collapseRepeatedWordsAroundPauses(cleaned)
        cleaned = collapseAdjacentRepeatedSentences(cleaned)
        cleaned = collapseAdjacentRepeatedPhrases(cleaned)
        return normalizedWhitespace(cleaned)
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseRepeatedWordsAroundPauses(_ text: String) -> String {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return repeatedWordAroundPausePattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: nsRange,
            withTemplate: "$1"
        )
    }

    private static func collapseAdjacentRepeatedSentences(_ text: String) -> String {
        let spans = sentenceSpans(in: text)
        guard spans.count > 1 else { return text }

        var result: [String] = []
        var previousNormalized = ""

        for span in spans {
            guard !span.normalized.isEmpty else { continue }
            if span.normalized == previousNormalized, contentWordCount(inNormalizedText: span.normalized) >= 4 {
                continue
            }

            result.append(span.raw)
            previousNormalized = span.normalized
        }

        return result.joined(separator: " ")
    }

    private static func sentenceSpans(in text: String) -> [SentenceSpan] {
        var spans: [SentenceSpan] = []
        var start = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                var end = text.index(after: index)
                while end < text.endIndex, ".!?".contains(text[end]) {
                    end = text.index(after: end)
                }
                appendSentence(text[start..<end], to: &spans)
                start = end
            }
            index = text.index(after: index)
        }

        if start < text.endIndex {
            appendSentence(text[start..<text.endIndex], to: &spans)
        }

        return spans
    }

    private static func appendSentence(_ substring: Substring, to spans: inout [SentenceSpan]) {
        let raw = substring.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        spans.append(SentenceSpan(raw: raw, normalized: normalizedWords(in: String(raw)).joined(separator: " ")))
    }

    private static func collapseAdjacentRepeatedPhrases(_ text: String) -> String {
        var current = text
        var changed = true

        while changed {
            changed = false
            let tokens = wordTokens(in: current)
            guard tokens.count >= 8 else { break }

            for length in stride(from: min(24, tokens.count / 2), through: 4, by: -1) {
                var index = 0
                var didRemove = false

                while index + (length * 2) <= tokens.count {
                    let first = tokens[index..<(index + length)].map(\.normalized)
                    let second = tokens[(index + length)..<(index + length * 2)].map(\.normalized)

                    if first == second, contentWordCount(inNormalizedWords: first) >= 4 {
                        let removalStart = tokens[index + length].range.lowerBound
                        let removalEnd = tokens[index + length * 2 - 1].range.upperBound
                        current.removeSubrange(removalStart..<removalEnd)
                        current = normalizedWhitespace(current)
                        changed = true
                        didRemove = true
                        break
                    }

                    index += 1
                }

                if didRemove {
                    break
                }
            }
        }

        return current
    }

    private static func wordTokens(in text: String) -> [WordToken] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordPattern.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let normalized = normalize(String(text[range]))
            guard !normalized.isEmpty else { return nil }
            return WordToken(normalized: normalized, range: range)
        }
    }

    private static func normalizedWords(in text: String) -> [String] {
        wordTokens(in: text).map(\.normalized)
    }

    private static func normalize(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
        let scalars = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func contentWordCount(inNormalizedText text: String) -> Int {
        contentWordCount(inNormalizedWords: text.split(separator: " ").map(String.init))
    }

    private static func contentWordCount(inNormalizedWords words: [String]) -> Int {
        words.filter { word in
            word.count > 2 && !weakWords.contains(word)
        }.count
    }
}
