import Foundation

/// Values passed on the command line, e.g. by `opdiff`:
///   opdiff --repo <path> [--base <ref>] [--head <ref>] [--committed-only]
struct LaunchOptions {
    var repo: URL?
    var base: String?
    var head: String?
    var uncommitted = true
    var explicitRepo = false

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            let value: String? = i + 1 < args.count ? args[i + 1] : nil
            switch args[i] {
            case "--repo":
                if let v = value {
                    o.repo = URL(fileURLWithPath: v)
                    o.explicitRepo = true
                    i += 1
                }
            case "--base":
                if let v = value {
                    o.base = v
                    i += 1
                }
            case "--head", "--compare":
                if let v = value {
                    o.head = v
                    i += 1
                }
            case "--uncommitted", "-u": o.uncommitted = true
            case "--committed-only", "-c": o.uncommitted = false
            default: break
            }
            i += 1
        }
        // `swift run` from inside a repo: use the working directory.
        let cwd = FileManager.default.currentDirectoryPath
        if o.repo == nil, cwd != "/" { o.repo = URL(fileURLWithPath: cwd) }
        return o
    }
}
