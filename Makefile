.PHONY: all whisper model build app run clean dev-reset

APP := Murmur.app
BIN := $(APP)/Contents/MacOS/Murmur

all: app

# One-command setup for a fresh clone: signing identity, whisper libs, model.
setup:
	bash scripts/setup_signing.sh
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

# Assemble and sign Murmur.app (builds whisper + model if missing).
app: $(if $(wildcard third_party/whisper.cpp/build/bin/libwhisper.dylib),,whisper) model
	bash scripts/bundle.sh

# Build and launch via LaunchServices (required for mic/Accessibility TCC prompts).
run: app
	open $(APP)

# Stream the running app's logs (NSLog + whisper stderr go to the unified log).
logs:
	log stream --level debug --predicate 'process == "Murmur"'

# Build a drag-to-Applications DMG (self-signed; see scripts/make_dmg.sh notes).
dmg: app
	bash scripts/make_dmg.sh

# Install to /Applications and (re)launch from there. The signed bundle is
# relocatable, so copying preserves the signature and TCC grants.
install: app
	-pkill -x Murmur
	rm -rf /Applications/Murmur.app
	cp -R Murmur.app /Applications/Murmur.app
	open /Applications/Murmur.app
	@echo "installed and launched /Applications/Murmur.app"

# Remove TCC grants so permission prompts reappear (for testing first-run UX).
dev-reset:
	-tccutil reset Microphone media.travis.murmur
	-tccutil reset Accessibility media.travis.murmur

clean:
	rm -rf .build $(APP)
