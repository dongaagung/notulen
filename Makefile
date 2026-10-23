# Builds with Command Line Tools + SwiftPM only (no Xcode).
# macOS ships GNU Make 3.81 (no .SHELLFLAGS), so pipefail is set per recipe.
SHELL := /bin/bash
.DEFAULT_GOAL := build

NAME    := Notulen
SUPPORT := App/Support
APP     := .build/$(NAME).app
RELEASE := .build/release-bundle/$(NAME).app
# The installed app name matches $(NAME).
INSTALLED := /Applications/Notulen.app
BUNDLE_ID := rakyat.notulen

# The default Swift Build backend can't initialize without Xcode.
SWIFTPM := --build-system native
# Drop that flag's deprecation notice so `make build` stays errors-only.
PRETTY  := sed '/build-system native. has been deprecated/d' | xcbeautify --quiet --disable-logging

# Command Line Tools ship Swift Testing outside the default search paths.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
TESTING := -Xswiftc -F$(CLT_DEV)/Frameworks -Xlinker -F$(CLT_DEV)/Frameworks \
           -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
           -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

# Pinned diarization models, bundled so the app never downloads at runtime.
MODELS := Models/speaker-diarization/.fluidaudio-revision

# $(call bundle,<executable>,<app>): assemble and ad-hoc sign an .app.
define bundle
	rm -rf "$(2)"
	mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources"
	cp "$(1)" "$(2)/Contents/MacOS/$(NAME)"
	cp $(SUPPORT)/Info.plist "$(2)/Contents/"
	cp $(SUPPORT)/AppIcon.icns "$(2)/Contents/Resources/"
	cp -R prompts "$(2)/Contents/Resources/"
	cp -R Models "$(2)/Contents/Resources/FluidAudioModels"
	set -o pipefail; codesign --force --options runtime \
		--entitlements $(SUPPORT)/$(NAME).entitlements --sign - "$(2)" 2>&1 \
		| sed '/replacing existing signature/d'
endef

.PHONY: build run test install uninstall icon models

$(MODELS): scripts/fetch-models.sh
	scripts/fetch-models.sh

# Forces a fresh download.
models:
	scripts/fetch-models.sh


build: $(MODELS)
	set -o pipefail; swift build $(SWIFTPM) 2>&1 | $(PRETTY)
	$(call bundle,.build/debug/$(NAME),$(APP))

run: build
	open $(APP)

test:
	set -o pipefail; swift test $(SWIFTPM) $(TESTING) $(if $(FILTER),--filter $(FILTER)) 2>&1 | $(PRETTY) --is-ci

# Optimized build, installed in /Applications to open from Launchpad,
# Spotlight or the Dock. Quits a running copy first. Re-run after changes.
install: $(MODELS)
	set -o pipefail; swift build -c release $(SWIFTPM) 2>&1 | $(PRETTY)
	$(call bundle,.build/release/$(NAME),$(RELEASE))
	osascript -e 'quit app id "$(BUNDLE_ID)"' 2>/dev/null || true
	sleep 1
	rm -rf "$(INSTALLED)"
	ditto "$(RELEASE)" "$(INSTALLED)"
	@echo "Installed $(INSTALLED)"

uninstall:
	osascript -e 'quit app id "$(BUNDLE_ID)"' 2>/dev/null || true
	rm -rf "$(INSTALLED)"
	@echo "Removed $(INSTALLED). Your meetings stay in ~/Library/Application Support/$(BUNDLE_ID)."

# Redraws App/Support/AppIcon.icns.
icon:
	swift scripts/make-icon.swift $(SUPPORT)/AppIcon.icns
