import Foundation

// MARK: - Placing annotations on diff lines

/// Where a file's annotations go in the diff view.
public struct AnnotationLayout: Sendable {
    /// Strongest annotation kind covering each visible line.
    public private(set) var markers: [AnnotationSide: [Int: AnnotationKind]] = [:]
    /// Cards shown under a line (the last visible line of each annotation's range).
    public private(set) var cards: [AnnotationSide: [Int: [Annotation]]] = [:]
    /// Annotations whose lines aren't in the diff; shown at the top of the file.
    public private(set) var unplaced: [Annotation] = []
    /// The line each placed annotation's card sits under, by annotation id.
    public private(set) var anchors: [String: Anchor] = [:]

    public struct Anchor: Sendable, Hashable {
        public let side: AnnotationSide
        public let line: Int
    }

    public var isEmpty: Bool { cards.isEmpty && unplaced.isEmpty }

    public init(file: FileDiff, annotations: [Annotation]) {
        guard !annotations.isEmpty else { return }
        var visible: [AnnotationSide: Set<Int>] = [.new: [], .old: []]
        for line in file.hunks.flatMap(\.lines) {
            if line.kind != .deletion, let n = line.newNumber { visible[.new]!.insert(n) }
            if line.kind != .addition, let n = line.oldNumber { visible[.old]!.insert(n) }
        }
        for annotation in annotations {
            let shown = (annotation.startLine...annotation.endLine).filter { visible[annotation.side]!.contains($0) }
            guard let anchor = shown.last else {
                unplaced.append(annotation)
                continue
            }
            cards[annotation.side, default: [:]][anchor, default: []].append(annotation)
            anchors[annotation.id] = Anchor(side: annotation.side, line: anchor)
            for n in shown {
                let current = markers[annotation.side]?[n]
                if current == nil || current! < annotation.kind {
                    markers[annotation.side, default: [:]][n] = annotation.kind
                }
            }
        }
    }

    /// Marker for a diff line: deletions use the old side, everything else the new side
    /// (context lines also pick up old-side annotations).
    public func marker(for line: DiffLine) -> AnnotationKind? {
        var kinds: [AnnotationKind] = []
        if line.kind != .deletion, let n = line.newNumber, let k = markers[.new]?[n] { kinds.append(k) }
        if line.kind != .addition, let n = line.oldNumber, let k = markers[.old]?[n] { kinds.append(k) }
        return kinds.max()
    }

    /// Index of the row (in `rows`) that shows the annotation's card, for scrolling to it.
    public func rowIndex(of annotation: Annotation, in rows: [DiffRow]) -> Int? {
        guard let anchor = anchors[annotation.id] else { return nil }
        func matches(_ line: DiffLine?) -> Bool {
            guard let line else { return false }
            switch anchor.side {
            case .new: return line.kind != .deletion && line.newNumber == anchor.line
            case .old: return line.kind != .addition && line.oldNumber == anchor.line
            }
        }
        return rows.firstIndex { row in
            switch row {
            case .hunk: false
            case .line(let line): matches(line)
            case .pair(let old, let new): matches(old) || matches(new)
            }
        }
    }

    public func cards(after line: DiffLine) -> [Annotation] {
        var result: [Annotation] = []
        if line.kind != .addition, let n = line.oldNumber { result += cards[.old]?[n] ?? [] }
        if line.kind != .deletion, let n = line.newNumber { result += cards[.new]?[n] ?? [] }
        return result
    }
}

// MARK: - Matching annotation paths to files

public enum AnnotationFileResolver {
    /// The file an annotation refers to. Tries the exact path, the old path of renamed
    /// files, a normalised path ("./x", "a/x", "/abs/repo/x"), then a unique suffix match.
    public static func resolve(_ path: String, in files: [FileDiff]) -> FileDiff? {
        if let file = files.first(where: { $0.path == path || $0.oldPath == path }) { return file }
        let normalized = normalize(path)
        if let file = files.first(where: { $0.path == normalized || $0.oldPath == normalized }) { return file }
        let suffix = files.filter {
            $0.path.hasSuffix("/" + normalized) || normalized.hasSuffix("/" + $0.path)
        }
        return suffix.count == 1 ? suffix[0] : nil
    }

    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.count >= 2, p.hasPrefix("`"), p.hasSuffix("`") { p = String(p.dropFirst().dropLast()) }
        while p.hasPrefix("./") { p.removeFirst(2) }
        if p.hasPrefix("a/") || p.hasPrefix("b/") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
