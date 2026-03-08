import Foundation

/// Fuzzy string matching with scoring — subsequence match with bonuses.
struct FuzzyMatch {

    struct Result {
        let score: Int
        let matchedIndices: [Int]
    }

    /// Returns nil if no match, otherwise a Result with score and matched character positions.
    static func match(pattern: String, candidate: String) -> Result? {
        guard !pattern.isEmpty else {
            return Result(score: 0, matchedIndices: [])
        }

        let patternLower = pattern.lowercased()
        let candidateLower = candidate.lowercased()

        let patternChars = Array(patternLower)
        let candidateChars = Array(candidateLower)
        let originalChars = Array(candidate)

        var patternIdx = 0
        var matchedIndices: [Int] = []
        var score = 0

        // Bonus scoring
        var prevMatchIdx = -2 // for consecutive bonus
        var prevWasSeparator = true // start of string counts as separator

        for (candidateIdx, candidateChar) in candidateChars.enumerated() {
            if patternIdx < patternChars.count && candidateChar == patternChars[patternIdx] {
                matchedIndices.append(candidateIdx)
                score += 1

                // Consecutive match bonus
                if candidateIdx == prevMatchIdx + 1 {
                    score += 4
                }

                // Start of word bonus (after separator)
                if prevWasSeparator {
                    score += 8
                }

                // Exact case match bonus
                if originalChars[candidateIdx] == Array(pattern)[patternIdx] {
                    score += 1
                }

                // Capital letter bonus (camelCase boundary)
                if candidateIdx > 0 && originalChars[candidateIdx].isUppercase && !originalChars[candidateIdx - 1].isUppercase {
                    score += 6
                }

                prevMatchIdx = candidateIdx
                patternIdx += 1
            }

            let ch = originalChars[candidateIdx]
            prevWasSeparator = ch == "/" || ch == "." || ch == "-" || ch == "_" || ch == " "
        }

        // Did we match all pattern characters?
        guard patternIdx == patternChars.count else { return nil }

        // Bonus for shorter candidates (prefer concise names)
        let lengthPenalty = candidate.count
        score = score * 100 - lengthPenalty

        // Bonus for matching at start of filename (not path)
        if let lastSlash = candidate.lastIndex(of: "/") {
            let fileName = String(candidate[candidate.index(after: lastSlash)...])
            if fileName.lowercased().hasPrefix(patternLower) {
                score += 50
            }
        } else if candidateLower.hasPrefix(patternLower) {
            score += 50
        }

        return Result(score: score, matchedIndices: matchedIndices)
    }
}
