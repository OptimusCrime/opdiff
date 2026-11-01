import AppKit
import DiffCore
import Highlighter
import SwiftUI

/// Syntax-highlighted lines for one file, keyed by line number on each side.
struct HighlightedFile: Sendable {
    var old: [Int: AttributedString] = [:]
    var new: [Int: AttributedString] = [:]

    func text(for line: DiffLine) -> AttributedString? {
        switch line.kind {
        case .deletion: line.oldNumber.flatMap { old[$0] }
        case .addition, .context: line.newNumber.flatMap { new[$0] }
        case .noNewline: nil
        }
    }
}

/// Wraps HighlighterSwift (highlight.js in JavaScriptCore). An actor, because a
/// JSContext must not be used from several threads at once.
///
/// Each hunk is highlighted per side: the old side (context + deleted lines) and the
/// new side (context + added lines) are each joined into a contiguous snippet, so
/// multi-line constructs inside a hunk are coloured correctly.
actor SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    /// Files larger than this stay plain; highlighting them would take too long.
    static let maxLines = 5000

    private var engines: [Bool: Highlighter] = [:]

    private func engine(dark: Bool) -> Highlighter? {
        if let engine = engines[dark] { return engine }
        guard let engine = Highlighter() else { return nil }
        engine.setTheme(dark ? "github-dark" : "github")
        engine.ignoreIllegals = true
        engines[dark] = engine
        return engine
    }

    /// Loads highlight.js ahead of time so the first files don't render plain.
    func warmUp(dark: Bool) { _ = engine(dark: dark) }

    func highlight(_ file: FileDiff, dark: Bool) -> HighlightedFile? {
        guard let language = Self.language(for: file.path),
              file.lineCount <= Self.maxLines,
              let engine = engine(dark: dark) else { return nil }

        var result = HighlightedFile()
        for hunk in file.hunks {
            if Task.isCancelled { return nil }
            let oldSide = hunk.lines.filter { $0.kind == .context || $0.kind == .deletion }
            let newSide = hunk.lines.filter { $0.kind == .context || $0.kind == .addition }
            for (number, text) in highlightLines(oldSide.map(\.text), engine: engine, language: language)
                .enumerated().compactMap({ i, t in t.map { (oldSide[i].oldNumber, $0) } }) {
                if let number { result.old[number] = text }
            }
            for (number, text) in highlightLines(newSide.map(\.text), engine: engine, language: language)
                .enumerated().compactMap({ i, t in t.map { (newSide[i].newNumber, $0) } }) {
                if let number { result.new[number] = text }
            }
        }
        return result
    }

    /// Highlights the lines as one snippet and splits the result back into lines.
    /// Returns nil for any line whose text didn't survive the round trip unchanged.
    private func highlightLines(_ lines: [String], engine: Highlighter, language: String) -> [AttributedString?] {
        guard !lines.isEmpty else { return [] }
        let source = lines.map(Self.displayText)
        guard let rendered = engine.highlight(source.joined(separator: "\n"), as: language) else {
            return Array(repeating: nil, count: lines.count)
        }

        var output: [AttributedString?] = []
        let ns = rendered.string as NSString
        var start = 0
        while output.count < lines.count {
            let searchRange = NSRange(location: start, length: ns.length - start)
            let newline = ns.range(of: "\n", range: searchRange)
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let lineRange = NSRange(location: start, length: end - start)
            let index = output.count
            output.append(ns.substring(with: lineRange) == source[index]
                          ? Self.convert(rendered, range: lineRange) : nil)
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        // Pad if the renderer returned fewer lines than expected.
        output += Array(repeating: nil, count: lines.count - output.count)
        return output
    }

    /// Keeps only the colours; the font comes from the view, so highlighted and plain
    /// lines line up exactly.
    private static func convert(_ string: NSAttributedString, range: NSRange) -> AttributedString {
        var out = AttributedString()
        string.enumerateAttribute(.foregroundColor, in: range) { value, subrange, _ in
            var piece = AttributedString(string.attributedSubstring(from: subrange).string)
            if let color = value as? NSColor { piece.foregroundColor = Color(nsColor: color) }
            out += piece
        }
        return out
    }

    /// The text as it is shown on screen (tabs expanded). Plain lines use the same.
    static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: "    ")
    }

    /// highlight.js language for a path, or nil to leave the file plain.
    static func language(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "containerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "podfile", "gemfile", "rakefile", "fastfile", "appfile", "brewfile": return "ruby"
        case "cmakelists.txt": return "cmake"
        default: break
        }
        if name.hasPrefix("dockerfile.") { return "dockerfile" }
        return extensions[(name as NSString).pathExtension]
    }

    private static let extensions: [String: String] = [
        "swift": "swift",
        "m": "objectivec", "mm": "objectivec",
        "c": "c", "h": "cpp", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "cs": "csharp", "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala",
        "groovy": "groovy", "gradle": "gradle",
        "go": "go", "rs": "rust", "zig": "zig", "dart": "dart",
        "py": "python", "pyi": "python", "rb": "ruby", "php": "php", "pl": "perl", "pm": "perl",
        "lua": "lua", "r": "r", "jl": "julia",
        "ex": "elixir", "exs": "elixir", "erl": "erlang", "hrl": "erlang",
        "hs": "haskell", "elm": "elm", "clj": "clojure", "cljs": "clojure", "ml": "ocaml", "fs": "fsharp",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescript",
        "html": "xml", "htm": "xml", "xml": "xml", "plist": "xml", "svg": "xml", "vue": "xml",
        "storyboard": "xml", "xib": "xml", "csproj": "xml",
        "css": "css", "scss": "scss", "sass": "scss", "less": "less",
        "json": "json", "jsonc": "json", "json5": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini",
        "properties": "properties",
        "md": "markdown", "markdown": "markdown",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "ps1": "powershell",
        "sql": "sql", "graphql": "graphql", "gql": "graphql", "proto": "protobuf",
        "nix": "nix", "vim": "vim", "tex": "latex",
        "diff": "diff", "patch": "diff", "cmake": "cmake", "mk": "makefile",
    ]
}
