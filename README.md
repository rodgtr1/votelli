# Votelli

A dead-simple, push-to-talk voice-to-text app for macOS. Hold a key, talk, release —
Votelli transcribes locally with Whisper and types the text into whatever app has focus.

Lives in the menu bar (top right), not the Dock. No window, no fuss.

## Features

- **Push-and-hold dictation** — hold a modifier key (default Right Option ⌥), speak, release. Text appears at your cursor.
- **Fully local & fast** — on macOS 26+ Votelli uses Apple's on-device SpeechAnalyzer
  engine (the most accurate local option, with OS-managed models); everywhere else the
  bundled Whisper `base.en` model runs on the GPU via Metal. Nothing leaves your Mac.
- **Menu bar only** — no Dock icon, no window. Icon shows idle / recording / transcribing.
- **Live waveform** — a floating HUD rises and falls with your voice while you hold the key.
- **Pick your own hotkey** — Preferences lets you set the key by pressing it.
- **Start at login** — optional, toggled from Preferences or the menu.
- **Clipboard-safe** — types via synthesized key events, so your clipboard is untouched.

## Install

Download, drag, approve once — no developer tools needed.

1. Download the latest **`Votelli-<version>.dmg`** from the
   [Releases page](https://github.com/rodgtr1/votelli/releases/latest).
2. Open the DMG and drag **Votelli.app** into your **Applications** folder.
3. Double-click **Votelli**. It's signed with an Apple Developer ID and notarized by
   Apple, so it opens straight away — no "unidentified developer" detour.
4. Votelli launches and walks you through the permissions it needs — it opens its
   own Preferences window showing the live status of each:
   - **Microphone** — click **Allow** on the popup.
   - **Input Monitoring** — when prompted, open System Settings and toggle
     **Votelli** on.
   - **Accessibility** — go to **Privacy & Security → Accessibility** and toggle
     **Votelli** on.
5. Look for the **microphone icon** in the menu bar (top-right). Open **Preferences**
   to pick your microphone input. All set.

Everything (Whisper model, Metal GPU shaders) is bundled. Requires an Apple Silicon
Mac on macOS 13 or later. More on the [permissions](#first-run-permissions) below.

## Build from source

> Most people don't need this — use the DMG above. Build from source only if you
> want to modify Votelli or produce your own signed build.

Requirements:

- macOS 13 or later (Apple Silicon)
- **Full Xcode** with the Metal toolchain (Command Line Tools alone is not enough),
  needed to compile the Metal GPU shaders at build time:
  ```
  xcodebuild -downloadComponent MetalToolchain
  ```
- `cmake` (`brew install cmake`)

```bash
git clone --recurse-submodules <repo-url> votelli
cd votelli
make setup     # one time: signing identity, whisper libs, model download
make install   # build, bundle, sign, copy to /Applications, launch
```

`make setup` does three things once:
- creates a stable self-signed "Votelli Dev" code-signing identity so your
  permissions persist across rebuilds (`scripts/setup_signing.sh`),
- builds whisper.cpp as Metal-accelerated shared libraries,
- downloads the `base.en` model into `Resources/`.

Building locally means the app is **not** Gatekeeper-quarantined, so it launches
without an "unidentified developer" warning.

## First-run permissions

macOS can't pre-grant these — you approve each one. On first launch Votelli asks for:

| Permission | Why |
|------------|-----|
| **Microphone** | to hear you while you hold the key |
| **Input Monitoring** | to detect the held push-to-talk key |
| **Accessibility** | to type the transcribed text into other apps |

On first launch Votelli opens its **Preferences** window, whose **Permissions** panel
shows the live status of each (✅/❌, updating as you grant them) with a button to open
the matching System Settings pane. If typing doesn't work right after granting
Accessibility, relaunch once (`pkill -x Votelli; open /Applications/Votelli.app`).

## Usage

1. Click into any text field.
2. **Hold your hotkey, speak, release.** The waveform HUD shows while you hold; text types a beat after you release.
3. Change the key in **Preferences… → Push-to-talk key** (click the button, press the key you want — must be a modifier: ⌥ ⌘ ⌃ ⇧ or Fn).

## Make targets

| Target | What it does |
|--------|--------------|
| `make setup` | One-time: signing identity, whisper libs, model |
| `make install` | Build, bundle, sign, copy to /Applications, launch |
| `make app` | Build and assemble `Votelli.app` without installing |
| `make run` | Build and launch from the repo directory |
| `make dmg` | Build a drag-to-Applications DMG |
| `make logs` | Stream the running app's logs |
| `make dev-reset` | Reset TCC grants to re-test the first-run flow |
| `make clean` | Remove build output |

## How it works

```
Hold key  →  AVAudioEngine (16kHz mono)  →  speech engine (on-device)  →  CGEvent unicode typing
```

- `HotkeyMonitor` — a `listenOnly` CGEvent tap watches `flagsChanged` for the chosen modifier.
- `AudioRecorder` — captures the mic, resamples to 16kHz mono float, and reports live levels for the waveform.
- `Transcriber` — thin C wrapper (`Sources/CWhisper`) over whisper.cpp, loaded once off the main thread.
- `AppleSpeechEngine` — Apple's SpeechAnalyzer/SpeechTranscriber, used by default on
  macOS 26+ where it's both more accurate and faster than the bundled model. Its model
  assets are downloaded and updated by the OS. Whisper remains the floor on macOS 13–15
  (and the fallback if the assets aren't ready).
- `TextProcessing` (`Sources/VotelliText`) — strips Whisper non-speech annotations like `[BLANK_AUDIO]`; unit-tested via `swift test`.
- `TextInjector` — synthesizes Unicode key events so text lands at the cursor without touching the clipboard.

## Configuration

Settings live in `UserDefaults` and are editable in Preferences. The hotkey can also
be set from the command line (keycodes: Right Option `61`, Left Option `58`,
Right Command `54`, Left Command `55`, Right Control `62`, Right Shift `60`, Fn `63`):

```bash
defaults write media.travis.votelli hotkeyKeyCode -int 54   # 54 = Right Command
```

## Troubleshooting

- **Hotkey does nothing / waveform shows but no text** — Accessibility isn't granted to
  the current build. Open Preferences → Permissions, enable Accessibility, relaunch.
- **Flat waveform / nothing transcribes** — Votelli is recording from a silent input
  device. Open **Preferences → Microphone input** and pick the mic you actually speak
  into. Votelli then sticks to that device even if macOS changes the system default.
- **Permissions keep resetting** — stale TCC entries from older builds. Reset and re-grant once:
  ```bash
  tccutil reset Accessibility media.travis.votelli
  ```
- **See what's happening** — `make logs`, or read `~/Library/Logs/Votelli.log`. For verbose
  output (per-keystroke events, transcribed text): `VOTELLI_DEBUG=1 open /Applications/Votelli.app`.

## Distributing a prebuilt DMG

`make dmg` produces `Votelli-<version>.dmg`: it release-signs the app with the
project's Apple Developer ID certificate and hardened runtime, submits the DMG to
Apple for notarization, and staples the resulting ticket to it. Downloaders open it
like any other Mac app — no Gatekeeper warning and nothing to clear by hand.

That path needs the Developer ID identity and the `votelli-notary` notarization
credentials on the build machine; see [PUBLISH.md](PUBLISH.md). Builds made from
source with `make app` / `make install` are signed with the local development
identity instead and are never quarantined.

## Uninstall

```bash
# Quit and remove the app
pkill -x Votelli
rm -rf /Applications/Votelli.app

# Remove its settings and logs
defaults delete media.travis.votelli 2>/dev/null
rm -f ~/Library/Preferences/media.travis.votelli.plist
rm -f ~/Library/Logs/Votelli.log

# Revoke the Mic / Input Monitoring / Accessibility grants (optional)
tccutil reset All media.travis.votelli
```

If you'd enabled **Start at login**, removing the app unregisters it automatically; if
a stale entry lingers, remove "Votelli" under System Settings → General → Login Items.

## License

MIT — see [LICENSE](LICENSE).
