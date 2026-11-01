PREFIX  ?= $(HOME)/.local/bin
APP_DIR ?= $(HOME)/Applications

.PHONY: app install uninstall test run

app:
	./scripts/build-app.sh

install: app
	mkdir -p "$(APP_DIR)" "$(PREFIX)"
	rm -rf "$(APP_DIR)/opdiff.app"
	cp -R build/opdiff.app "$(APP_DIR)/"
	install -m 755 scripts/opdiff "$(PREFIX)/opdiff"
	ln -sf opdiff "$(PREFIX)/git-opdiff"
	@echo "Installed $(APP_DIR)/opdiff.app and $(PREFIX)/opdiff"
	@case ":$$PATH:" in *":$(PREFIX):"*) ;; *) echo "NOTE: $(PREFIX) is not on your PATH. Add it, or run: make install PREFIX=/usr/local/bin";; esac

uninstall:
	rm -rf "$(APP_DIR)/opdiff.app" "$(PREFIX)/opdiff" "$(PREFIX)/git-opdiff"

test:
	swift test

run:
	swift run opdiff
