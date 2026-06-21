# Murmur

A dead-simple, push-to-talk voice-to-text app for macOS. Hold a key, talk, release —
Murmur transcribes locally with Whisper and types the text into whatever app has focus.

Lives in the menu bar (top right), not the Dock. No window, no fuss.

## Features

- **Push-and-hold dictation** — hold Right Option (⌥), speak, release. Text appears at your cursor.
- **Fully local & fast** — bundled Whisper `base.en` model runs on the GPU via Metal. Nothing leaves your Mac.
- **Menu bar only** — no Dock icon, no window. Icon shows idle / recording / transcribing.
- **Start at login** — optional, toggled from the menu.
- **Clipboard-safe** — types via synthesized key events, so your clipboard is untouched.

## Requirements

- macOS 13+ (Apple Silicon)
- Xcode (full, with the Metal toolchain) to build
- `cmake` (`brew install cmake`)

## Build & run

```bash
make run
```

That builds whisper.cpp (Metal), downloads the `base.en` model, assembles and
signs `Murmur.app`, and launches it. First launch asks for two permissions:

1. **Microphone** — to hear you.
2. **Accessibility** — to detect the held key and type text into other apps.

Grant both (System Settings opens automatically for Accessibility), then hold
**Right Option** and start talking.

## Make targets

| Target | What it does |
|--------|--------------|
| `make run` | Build everything and launch the app |
| `make app` | Build and assemble `Murmur.app` without launching |
| `make whisper` | Build whisper.cpp shared libraries |
| `make model` | Download the `base.en` model into `Resources/` |
| `make logs` | Stream the running app's logs |
| `make dev-reset` | Reset TCC grants to re-test the first-run permission flow |
| `make clean` | Remove build output |

## How it works

```
Hold Right ⌥  →  AVAudioEngine (16kHz mono)  →  whisper.cpp (Metal)  →  CGEvent unicode typing
```

- `HotkeyMonitor` — a `listenOnly` CGEvent tap watches `flagsChanged` for the configured modifier.
- `AudioRecorder` — captures the mic and resamples to 16kHz mono float for Whisper.
- `Transcriber` — thin C wrapper (`Sources/CWhisper`) over whisper.cpp, loaded once off the main thread.
- `TextInjector` — synthesizes Unicode key events so text lands at the cursor without touching the clipboard.

## Configuration

The push-to-talk key is stored in `UserDefaults` (`hotkeyKeyCode`, default `61` =
Right Option). A picker in the menu is planned; for now you can change it with:

```bash
defaults write media.travis.murmur hotkeyKeyCode -int 54   # 54 = Right Command
```

Common modifier keycodes: Right Option `61`, Left Option `58`, Right Command `54`,
Left Command `55`, Right Control `62`, Right Shift `60`, fn `63`.

## Project layout

```
Sources/Murmur/      Swift app (menu bar, hotkey, audio, injection, login item)
Sources/CWhisper/    Minimal C bridge to whisper.cpp
Resources/           Info.plist, entitlements, bundled model
scripts/             build_whisper.sh, bundle.sh, fetch_model.sh
third_party/whisper.cpp   git submodule
```
