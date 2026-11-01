PREFIX  ?= $(HOME)/.local/bin
APP_DIR ?= $(HOME)/Applications

.PHONY: app build install uninstall test run icon format lint check

# Swift sources checked by `make format` / `make lint` (style in .swift-format).
SWIFT_SOURCES = Package.swift Sources Tests scripts/make-icon.swift

app:
	./scripts/build-app.sh

install: app
	mkdir -p "$(APP_DIR)" "$(PREFIX)"
	rm -rf "$(APP_DIR)/OptimusDiff.app" "$(APP_DIR)/opdiff.app"
	cp -R build/OptimusDiff.app "$(APP_DIR)/"
	install -m 755 scripts/opdiff "$(PREFIX)/opdiff"
	ln -sf opdiff "$(PREFIX)/git-opdiff"
	@echo "Installed $(APP_DIR)/OptimusDiff.app and $(PREFIX)/opdiff"
	@case ":$$PATH:" in *":$(PREFIX):"*) ;; *) echo "NOTE: $(PREFIX) is not on your PATH. Add it, or run: make install PREFIX=/usr/local/bin";; esac

uninstall:
	rm -rf "$(APP_DIR)/OptimusDiff.app" "$(PREFIX)/opdiff" "$(PREFIX)/git-opdiff"

build:
	swift build

test:
	swift test

format:
	swift format --in-place --recursive --parallel $(SWIFT_SOURCES)

lint:
	swift format lint --strict --recursive --parallel $(SWIFT_SOURCES)

# What CI should run: formatting, build and tests.
check: lint build test

icon:
	swift scripts/make-icon.swift

run:
	swift run opdiff
