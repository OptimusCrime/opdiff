import Foundation

/// Word-level changes between a deleted line and the added line that replaced it,
/// so the view can emphasise exactly what changed (like GitHub's darker highlights).
public enum WordDiff {
    /// Largest token grid compared with LCS; longer lines fall back to prefix/suffix matching.
    static let maxCells = 40_000

    /// Pairs the i-th deleted line with the i-th added line of each change block
    /// (the same pairing the split view uses) and diffs each pair.
    public static func emphasis(for hunks: [Hunk]) -> (old: [Int: [Range<Int>]], new: [Int: [Range<Int>]]) {
        var old: [Int: [Range<Int>]] = [:]
        var new: [Int: [Range<Int>]] = [:]
        for hunk in hunks {
            var dels: [DiffLine] = []
            var adds: [DiffLine] = []
            func flush() {
                for i in 0..<min(dels.count, adds.count) {
                    guard let o = dels[i].oldNumber, let n = adds[i].newNumber,
                        let r = ranges(old: dels[i].displayText, new: adds[i].displayText)
                    else { continue }
                    if !r.old.isEmpty { old[o] = r.old }
                    if !r.new.isEmpty { new[n] = r.new }
                }
                dels.removeAll()
                adds.removeAll()
            }
            for line in hunk.lines {
                switch line.kind {
                case .deletion:
                    if !adds.isEmpty { flush() }
                    dels.append(line)
                case .addition:
                    adds.append(line)
                default:
                    flush()
                }
            }
            flush()
        }
        return (old, new)
    }

    /// Character ranges that differ in each line, or nil when the lines are so different
    /// that emphasising words wouldn't help (the whole line is the change).
    public static func ranges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        let a = tokenize(old)
        let b = tokenize(new)
        guard !a.isEmpty, !b.isEmpty, old != new else { return nil }
        var keepA = [Bool](repeating: false, count: a.count)
        var keepB = [Bool](repeating: false, count: b.count)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix].text == b[prefix].text {
            keepA[prefix] = true
            keepB[prefix] = true
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
            a[a.count - 1 - suffix].text == b[b.count - 1 - suffix].text
        {
            keepA[a.count - 1 - suffix] = true
            keepB[b.count - 1 - suffix] = true
            suffix += 1
        }

        // LCS over the middle tokens.
        let midA = Array(prefix..<(a.count - suffix))
        let midB = Array(prefix..<(b.count - suffix))
        if !midA.isEmpty, !midB.isEmpty, midA.count * midB.count <= maxCells {
            let n = midA.count
            let m = midB.count
            var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * (m + 1) + j] =
                        a[midA[i]].text == b[midB[j]].text
                        ? table[(i + 1) * (m + 1) + j + 1] + 1
                        : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
                }
            }
            var i = 0
            var j = 0
            while i < n, j < m {
                if a[midA[i]].text == b[midB[j]].text {
                    keepA[midA[i]] = true
                    keepB[midB[j]] = true
                    i += 1
                    j += 1
                } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }

        // Too little in common: skip emphasis.
        func solid(_ tokens: [Token], _ keep: [Bool]) -> (kept: Int, total: Int) {
            var kept = 0
            var total = 0
            for (t, k) in zip(tokens, keep) where !t.isSpace {
                total += t.length
                if k { kept += t.length }
            }
            return (kept, total)
        }
        let sa = solid(a, keepA)
        let sb = solid(b, keepB)
        let total = sa.total + sb.total
        guard total > 0, Double(sa.kept + sb.kept) / Double(total) >= 0.4 else { return nil }

        return (merge(a, keepA), merge(b, keepB))
    }

    /// Changed tokens as character ranges; a whitespace token between two changes is absorbed.
    private static func merge(_ tokens: [Token], _ keep: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (i, token) in tokens.enumerated() where !keep[i] {
            let range = token.start..<(token.start + token.length)
            if let last = out.last {
                let gap = tokens[..<i].reversed().prefix { $0.start >= last.upperBound }
                if last.upperBound == range.lowerBound || gap.allSatisfy(\.isSpace) {
                    out[out.count - 1] = last.lowerBound..<range.upperBound
                    continue
                }
            }
            out.append(range)
        }
        return out
    }

    struct Token {
        let text: Substring
        let start: Int
        let length: Int
        let isSpace: Bool
    }

    /// Words (letters, digits, _), runs of whitespace, and single other characters.
    static func tokenize(_ s: String) -> [Token] {
        enum Class { case word, space, other }
        func classify(_ c: Character) -> Class {
            if c.isLetter || c.isNumber || c == "_" { return .word }
            if c.isWhitespace { return .space }
            return .other
        }
        var tokens: [Token] = []
        var index = s.startIndex
        var offset = 0
        while index < s.endIndex {
            let cls = classify(s[index])
            var end = s.index(after: index)
            var length = 1
            if cls != .other {
                while end < s.endIndex, classify(s[end]) == cls {
                    end = s.index(after: end)
                    length += 1
                }
            }
            tokens.append(Token(text: s[index..<end], start: offset, length: length, isSpace: cls == .space))
            index = end
            offset += length
        }
        return tokens
    }
}
