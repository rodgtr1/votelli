# Murmur

A dead-simple, push-to-talk voice-to-text app for macOS. Hold a key, talk, release —
Murmur transcribes locally with Whisper and types the text into whatever app has focus.

Lives in the menu bar (top right), not the Dock. No window, no fuss.

## Features

- **Push-and-hold dictation** — hold a modifier key (default Right Option ⌥), speak, release. Text appears at your cursor.
- **Fully local & fast** — bundled Whisper `base.en` model runs on the GPU via Metal. Nothing leaves your Mac.
- **Menu bar only** — no Dock icon, no window. Icon shows idle / recording / transcribing.
- **Live waveform** — a floating HUD rises and falls with your voice while you hold the key.
- **Pick your own hotkey** — Preferences lets you set the key by pressing it.
- **Start at login** — optional, toggled from Preferences or the menu.
- **Clipboard-safe** — types via synthesized key events, so your clipboard is untouched.

## Requirements

- macOS 13 or later (Apple Silicon)
- **Full Xcode** with the Metal toolchain (Command Line Tools alone is not enough):
  ```
  xcodebuild -downloadComponent MetalToolchain
  ```
- `cmake` (`brew install cmake`)

## Build & run

```bash
git clone --recurse-submodules <repo-url> murmur
cd murmur
make setup     # one time: signing identity, whisper libs, model download
make install   # build, bundle, sign, copy to /Applications, launch
```

`make setup` does three things once:
- creates a stable self-signed "Murmur Dev" code-signing identity so your
  permissions persist across rebuilds (`scripts/setup_signing.sh`),
- builds whisper.cpp as Metal-accelerated shared libraries,
- downloads the `base.en` model into `Resources/`.

Building locally means the app is **not** Gatekeeper-quarantined, so it launches
without an "unidentified developer" warning.

## First-run permissions

macOS can't pre-grant these — you approve each one. On first launch Murmur asks for:

| Permission | Why |
|------------|-----|
| **Microphone** | to hear you while you hold the key |
| **Input Monitoring** | to detect the held push-to-talk key |
| **Accessibility** | to type the transcribed text into other apps |

Preferences has a **Permissions** panel showing the status of each with a button to
open the matching System Settings pane. After granting Accessibility, relaunch once
(`pkill -x Murmur; open /Applications/Murmur.app`).

## Usage

1. Click into any text field.
2. **Hold your hotkey, speak, release.** The waveform HUD shows while you hold; text types a beat after you release.
3. Change the key in **Preferences… → Push-to-talk key** (click the button, press the key you want — must be a modifier: ⌥ ⌘ ⌃ ⇧ or Fn).

## Make targets

| Target | What it does |
|--------|--------------|
| `make setup` | One-time: signing identity, whisper libs, model |
| `make install` | Build, bundle, sign, copy to /Applications, launch |
| `make app` | Build and assemble `Murmur.app` without installing |
| `make run` | Build and launch from the repo directory |
| `make dmg` | Build a drag-to-Applications DMG |
| `make logs` | Stream the running app's logs |
| `make dev-reset` | Reset TCC grants to re-test the first-run flow |
| `make clean` | Remove build output |

## How it works

```
Hold key  →  AVAudioEngine (16kHz mono)  →  whisper.cpp (Metal)  →  CGEvent unicode typing
```

- `HotkeyMonitor` — a `listenOnly` CGEvent tap watches `flagsChanged` for the chosen modifier.
- `AudioRecorder` — captures the mic, resamples to 16kHz mono float, and reports live levels for the waveform.
- `Transcriber` — thin C wrapper (`Sources/CWhisper`) over whisper.cpp, loaded once off the main thread.
- `TextProcessing` (`Sources/MurmurText`) — strips Whisper non-speech annotations like `[BLANK_AUDIO]`; unit-tested via `swift test`.
- `TextInjector` — synthesizes Unicode key events so text lands at the cursor without touching the clipboard.

## Configuration

Settings live in `UserDefaults` and are editable in Preferences. The hotkey can also
be set from the command line (keycodes: Right Option `61`, Left Option `58`,
Right Command `54`, Left Command `55`, Right Control `62`, Right Shift `60`, Fn `63`):

```bash
defaults write media.travis.murmur hotkeyKeyCode -int 54   # 54 = Right Command
```

## Troubleshooting

- **Hotkey does nothing / waveform shows but no text** — Accessibility isn't granted to
  the current build. Open Preferences → Permissions, enable Accessibility, relaunch.
- **Permissions keep resetting** — stale TCC entries from older builds. Reset and re-grant once:
  ```bash
  tccutil reset Accessibility media.travis.murmur
  ```
- **See what's happening** — `make logs`, or read `~/Library/Logs/Murmur.log`. For verbose
  output (per-keystroke events, transcribed text): `MURMUR_DEBUG=1 open /Applications/Murmur.app`.

## Distributing a prebuilt DMG

`make dmg` produces `Murmur-<version>.dmg`. Because the app is self-signed (not
notarized), anyone who **downloads** it must right-click → Open on first launch, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Murmur.app
```

The recommended path for others is to build from source (no warning).

## License

MIT — see [LICENSE](LICENSE).
