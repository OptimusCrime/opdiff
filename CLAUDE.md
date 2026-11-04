# OptimusDiff

Native macOS diff viewer (SwiftUI, Swift Package, macOS 14+). The app target is `OptimusDiff`, built as the `opdiff` binary.

## Commands

- `make format`: format the code with swift-format (style in `.swift-format`). Run before committing.
- `make lint`: check formatting without changing files.
- `make build`: debug build.
- `make test`: run the tests.
- `make check`: lint + build + test. Must pass before committing.
- `make install`: build `OptimusDiff.app` into `/Applications` and the `opdiff` launcher into `~/.local/bin`.
- `swift run opdiff`: run from source in the current repository.

## Layout

- `Sources/DiffCore`: git, diff parsing, search, Claude prompts/output. No UI; put logic here and test it in `Tests/DiffCoreTests`.
- `Sources/OptimusDiff`: the SwiftUI app, one folder per feature. App state is `Model/CompareModel.swift`; each feature adds a `CompareModel+Feature.swift` extension next to its views.

## Conventions

- Never change the user's global git config; pass options per git command (see `Git.swift`).
- Keep files small (aim for under ~400 lines) and in the matching feature folder.
