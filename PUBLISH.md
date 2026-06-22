# Publishing a release

How to cut a new Votelli release: build the signed DMG and publish it to GitHub.
Run everything from the repo root.

The loop: **bump version → commit & push → `make dmg` → `gh release create`.**

## 1. Bump the version

Edit `Resources/Info.plist` and bump both keys:

```xml
<key>CFBundleShortVersionString</key>
<string>0.3.0</string>            <!-- public version, used for the DMG filename -->
<key>CFBundleVersion</key>
<string>3</string>                 <!-- internal build number; just increment it -->
```

## 2. Commit and push

The release tags a commit, so the code must be on GitHub first.

```bash
git add -A
git commit -m "Release 0.3.0: <what changed>"
git push origin main
```

## 3. Build the DMG

```bash
make dmg
```

This builds the app, signs it as the local "Votelli Dev" identity, and produces
`Votelli-<version>.dmg` (version taken from `Info.plist`).

## 4. Publish the GitHub release

```bash
gh release create v0.3.0 Votelli-0.3.0.dmg \
  --repo rodgtr1/votelli \
  --title "Votelli 0.3.0" \
  --notes "What changed in this version…"
```

That one command creates the `v0.3.0` git tag, the release page, and uploads the
DMG. The README links to `/releases/latest`, so the download link updates itself.

## Gotchas

- **`make dmg` prompts for a keychain password** — the signing keychain locked.
  Unlock it first (password is `votelli-dev`, same as in `scripts/setup_signing.sh`):
  ```bash
  security unlock-keychain -p votelli-dev ~/Library/Keychains/votelli-dev.keychain-db
  ```
- **Never `git add` the DMG.** It's ~130 MB and GitHub rejects files over 100 MB.
  `*.dmg` is in `.gitignore`, so `git add -A` is safe — the DMG only travels via
  `gh release create`, never through git.
- **`gh` not logged in** — run `gh auth login` once.

## Notes

- The DMG is **self-signed, not notarized**, so first-time downloaders see an
  "unidentified developer" warning and must right-click → Open (or run
  `xattr -dr com.apple.quarantine /Applications/Votelli.app`). To remove that
  warning entirely you'd need a paid Apple Developer ID certificate + notarization.
- Building from source on your own machine (`make install`) is never quarantined.
