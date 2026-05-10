import Foundation

struct TranscriptStitcher {
    private struct WordToken {
        let raw: String
        let normalized: String
        let range: Range<String.Index>
    }

    private struct IndexedWordToken {
        let wordIndex: Int
        let token: WordToken
    }

    private struct OverlapMatch {
        let wordsToDrop: Int
        let matchedWords: Int
        let existingEndGap: Int
        let nextStartGap: Int
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?",
        options: []
    )

    private static let weakSingleWordOverlaps: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
        "from", "i", "in", "is", "it", "of", "on", "or", "so", "that",
        "the", "this", "to", "was", "we", "with", "you"
    ]

    private static let ignoredAlignmentWords: Set<String> = weakSingleWordOverlaps.union([
        "he", "she", "they", "them", "then", "there", "here", "if", "into",
        "its", "it's", "just", "not", "now", "than", "their", "these", "those"
    ])

    static func merge(_ transcripts: [String]) -> String {
        var merged = ""

        for transcript in transcripts {
            let next = cleaned(transcript)
            guard !next.isEmpty else { continue }

            guard !merged.isEmpty else {
                merged = next
                continue
            }

            let overlap = wordsToDropForOverlap(existing: merged, next: next)
            let remainder = remainderAfterDropping(overlapWords: overlap, from: next)
            merged = smartJoin(merged, remainder)
        }

        return merged.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[]", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordsToDropForOverlap(existing: String, next: String) -> Int {
        let existingWords = wordTokens(in: existing)
        let nextWords = wordTokens(in: next)
        let exactOverlap = exactPrefixSuffixOverlap(existingWords: existingWords, nextWords: nextWords)
        let fuzzyOverlap = fuzzyEdgeOverlap(existingWords: existingWords, nextWords: nextWords)?.wordsToDrop ?? 0
        return max(exactOverlap, fuzzyOverlap)
    }

    private static func exactPrefixSuffixOverlap(existingWords: [WordToken], nextWords: [WordToken]) -> Int {
        let maxOverlap = min(40, existingWords.count, nextWords.count)
        guard maxOverlap > 0 else { return 0 }

        for count in stride(from: maxOverlap, through: 1, by: -1) {
            let suffix = existingWords.suffix(count)
            let prefix = nextWords.prefix(count)
            guard acceptsOverlap(existing: Array(suffix), next: Array(prefix)) else {
                continue
            }
            return count
        }

        return 0
    }

    private static func fuzzyEdgeOverlap(existingWords: [WordToken], nextWords: [WordToken]) -> OverlapMatch? {
        guard existingWords.count >= 6, nextWords.count >= 4 else { return nil }

        let existingEdgeWordStart = max(0, existingWords.count - 90)
        let nextEdgeWordEnd = min(nextWords.count - 1, 90)
        let existingContent = indexedContentWords(existingWords).filter { $0.wordIndex >= existingEdgeWordStart }
        let nextContent = indexedContentWords(nextWords).filter { $0.wordIndex <= nextEdgeWordEnd }
        guard !existingContent.isEmpty, !nextContent.isEmpty else { return nil }

        var bestMatch: OverlapMatch?

        for existingStart in existingContent.indices {
            for nextStart in nextContent.indices {
                let nextStartGap = nextContent[nextStart].wordIndex
                guard nextStartGap <= 8 else { break }

                var matchedWords = 0
                var existingCursor = existingStart
                var nextCursor = nextStart

                while existingCursor < existingContent.count,
                      nextCursor < nextContent.count,
                      wordsAreSimilar(
                        existingContent[existingCursor].token.normalized,
                        nextContent[nextCursor].token.normalized
                      ) {
                    matchedWords += 1
                    existingCursor += 1
                    nextCursor += 1
                }

                guard matchedWords >= 4 else { continue }

                let existingEndWordIndex = existingContent[existingCursor - 1].wordIndex
                let nextEndWordIndex = nextContent[nextCursor - 1].wordIndex
                let existingEndGap = existingWords.count - 1 - existingEndWordIndex
                guard existingEndGap <= 8 else { continue }

                let candidate = OverlapMatch(
                    wordsToDrop: nextEndWordIndex + 1,
                    matchedWords: matchedWords,
                    existingEndGap: existingEndGap,
                    nextStartGap: nextStartGap
                )

                if isBetterOverlap(candidate, than: bestMatch) {
                    bestMatch = candidate
                }
            }
        }

        return bestMatch
    }

    private static func indexedContentWords(_ words: [WordToken]) -> [IndexedWordToken] {
        words.enumerated().compactMap { index, token in
            guard !ignoredAlignmentWords.contains(token.normalized) else { return nil }
            return IndexedWordToken(wordIndex: index, token: token)
        }
    }

    private static func isBetterOverlap(_ candidate: OverlapMatch, than current: OverlapMatch?) -> Bool {
        guard let current else { return true }

        if candidate.wordsToDrop != current.wordsToDrop {
            return candidate.wordsToDrop > current.wordsToDrop
        }

        if candidate.matchedWords != current.matchedWords {
            return candidate.matchedWords > current.matchedWords
        }

        if candidate.existingEndGap != current.existingEndGap {
            return candidate.existingEndGap < current.existingEndGap
        }

        return candidate.nextStartGap < current.nextStartGap
    }

    private static func acceptsOverlap(existing: [WordToken], next: [WordToken]) -> Bool {
        guard existing.count == next.count, !existing.isEmpty else { return false }

        let matches = zip(existing, next).filter { wordsAreSimilar($0.normalized, $1.normalized) }.count
        let score = Double(matches) / Double(existing.count)

        switch existing.count {
        case 1:
            let word = existing[0].normalized
            return score == 1 && word.count >= 6 && !weakSingleWordOverlaps.contains(word)
        case 2:
            return score == 1
        case 3:
            return score >= 0.95
        default:
            return score >= 0.82 && wordsAreSimilar(existing[0].normalized, next[0].normalized)
        }
    }

    private static func remainderAfterDropping(overlapWords: Int, from text: String) -> String {
        guard overlapWords > 0 else { return text }

        let tokens = wordTokens(in: text)
        guard tokens.count >= overlapWords else { return "" }

        let cutIndex = tokens[overlapWords - 1].range.upperBound
        return String(text[cutIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func smartJoin(_ existing: String, _ next: String) -> String {
        let left = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = next.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        if let first = right.first, CharacterSet(charactersIn: ".,!?;:%)]}").contains(first.unicodeScalars.first!) {
            return left + right
        }

        if let last = left.last, CharacterSet(charactersIn: "([{").contains(last.unicodeScalars.first!) {
            return left + right
        }

        return left + " " + right
    }

    private static func wordTokens(in text: String) -> [WordToken] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordPattern.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let raw = String(text[range])
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { return nil }
            return WordToken(raw: raw, normalized: normalized, range: range)
        }
    }

    private static func normalize(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
        let scalars = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func wordsAreSimilar(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        if min(lhs.count, rhs.count) >= 5 {
            return levenshteinDistance(lhs, rhs, maxDistance: 1) <= 1
        }
        return false
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if abs(left.count - right.count) > maxDistance {
            return maxDistance + 1
        }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            var rowMinimum = current[0]

            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowMinimum = min(rowMinimum, current[j])
            }

            if rowMinimum > maxDistance {
                return maxDistance + 1
            }

            swap(&previous, &current)
        }

        return previous[right.count]
    }
}
