.PHONY: all whisper model build app run clean dev-reset

APP := Votelli.app
BIN := $(APP)/Contents/MacOS/Votelli

all: app

# One-command setup for a fresh clone: whisper libs + model. No signing step —
# dev and release builds both sign with the Developer ID (see the `app` target),
# falling back to ad-hoc automatically when that cert isn't installed, so there's
# no identity to create up front.
setup:
	bash scripts/build_whisper.sh
	bash scripts/fetch_model.sh

# Build whisper.cpp shared libraries (Metal-accelerated).
whisper:
	bash scripts/build_whisper.sh

# Download the base.en model if missing.
model:
	bash scripts/fetch_model.sh

# Compile the Swift app only.
build:
	swift build -c release

# Assemble and sign Votelli.app (builds whisper + model if missing).
# Pass the Developer ID leaf hash so dev builds sign with the SAME cert as release
# (Apple-anchored → TCC grants survive rebuilds); bundle.sh falls back to ad-hoc if
# it isn't installed. Release builds (make dmg) additionally set REQUIRE_STABLE_IDENTITY.
app: $(if $(wildcard third_party/whisper.cpp/build/bin/libwhisper.dylib),,whisper) model
	EXPECTED_LEAF_HASH=$(RELEASE_LEAF_HASH) bash scripts/bundle.sh

# Build and launch via LaunchServices (required for mic/Accessibility TCC prompts).
run: app
	open $(APP)

# Stream the running app's logs (NSLog + whisper stderr go to the unified log).
logs:
	log stream --level debug --predicate 'process == "Votelli"'

# The leaf hash of the "Developer ID Application: TRAVIS KEITH RODGERS (2UWZ923R8C)"
# certificate that signs every public release. TCC keys users' permission grants to
# this; it MUST NOT change between releases. If you ever deliberately rotate the
# signing identity, update this value (and accept that existing users will have to
# re-grant permissions once).
RELEASE_LEAF_HASH := 7351c39bc57da9bba73ffc330aaab0e0144adaa7

# Build a drag-to-Applications DMG for public release. Forces the Developer ID
# signing identity (no silent ad-hoc fallback), verifies the leaf
# hash is unchanged so updates don't reset users' permissions, then notarizes and
# staples the DMG. See scripts/make_dmg.sh notes.
dmg:
	REQUIRE_STABLE_IDENTITY=1 EXPECTED_LEAF_HASH=$(RELEASE_LEAF_HASH) $(MAKE) app
	REQUIRE_STABLE_IDENTITY=1 EXPECTED_LEAF_HASH=$(RELEASE_LEAF_HASH) bash scripts/make_dmg.sh

# Install to /Applications and (re)launch from there. The signed bundle is
# relocatable, so copying preserves the signature and TCC grants.
install: app
	-pkill -x Votelli
	rm -rf /Applications/Votelli.app
	cp -R Votelli.app /Applications/Votelli.app
	open /Applications/Votelli.app
	@echo "installed and launched /Applications/Votelli.app"

# Remove TCC grants so permission prompts reappear (for testing first-run UX).
# All three the app uses — including Input Monitoring, which the app checks via
# IOHIDCheckAccess and which the earlier version of this target missed.
dev-reset:
	-tccutil reset Microphone media.travis.votelli
	-tccutil reset Accessibility media.travis.votelli
	-tccutil reset ListenEvent media.travis.votelli

clean:
	rm -rf .build $(APP)
