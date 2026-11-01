# opdiff

*opdiff* — short for Optimus diff.

A small native macOS app for reviewing the diff between two branches before opening a pull request — like GitHub's "Comparing changes" page, but local.

- Pick **base** and **compare** branches (searchable; you can also type any ref: tag, SHA, `HEAD~3`)
- Or switch to **Commits** mode to compare two commits on one branch: pick the base commit first, then the compare picker lists only the commits after it
- GitHub semantics: shows what `compare` adds since it diverged from `base` (`base...compare`)
- All changed files in one scroll with sticky headers, plus a collapsible folder tree
- Unified or split view, "Viewed" checkboxes, commit list, renames/binary/new/deleted files
- Syntax highlighting for ~190 languages (GitHub light/dark themes), done lazily as files scroll into view
- **Include uncommitted** (on by default): adds staged, unstaged and untracked work (when `compare` is the checked-out branch) — useful for reviewing what an AI agent just did before committing

Requires macOS 14+ and Xcode / Command Line Tools.

## Install

```sh
make install            # builds opdiff.app → ~/Applications, the opdiff command → ~/.local/bin
make install PREFIX=/usr/local/bin   # if ~/.local/bin isn't on your PATH
```

## Usage

From inside any repository:

```sh
opdiff                 # current branch vs. default base (origin/HEAD, else main/master)
opdiff main            # current branch vs. main
opdiff main feature/x  # feature/x vs. main
opdiff -c              # committed changes only
opdiff <sha1> <sha2>   # changes between two commits (opens in Commits mode)
```

`git opdiff …` works too (installed as a `git-opdiff` link; git runs any `git-<name>` on your PATH as `git <name>`).

Claude Code (or any agent) can open it the same way — e.g. ask *"open the diff against main in opdiff"* and it will run `opdiff main`.

You can also launch the app directly and use **File → Open Repository… (⌘O)**, drop a folder on the window, or pick a recent repo. **⌘R** refreshes, **⇧⌘S** swaps base/compare.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Open repository |
| ⌘R | Refresh |
| ⇧⌘S | Swap base and compare |

## Development

```sh
swift run opdiff         # run from source (uses the current directory if it's a repo)
make test                  # parser + git integration tests
```

- `Sources/DiffCore` — git invocation and unified-diff parsing (no UI, tested)
- `Sources/opdiff` — SwiftUI app
- `scripts/` — `.app` bundling script and the `opdiff` command-line launcher

Syntax highlighting is provided by [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) (MIT), which bundles [highlight.js](https://highlightjs.org) (BSD-3-Clause).
