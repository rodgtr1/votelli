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

This builds the app, signs it as the "Votelli Dev" identity, and produces
`Votelli-<version>.dmg` (version taken from `Info.plist`).

Unlike `make app`, the release build **refuses to fall back to ad-hoc signing**
and **verifies the certificate leaf hash matches** `RELEASE_LEAF_HASH` in the
Makefile. Both guards exist for one reason: see "Signing identity" below.

## 4. Publish the GitHub release

```bash
gh release create v0.3.0 Votelli-0.3.0.dmg \
  --repo rodgtr1/votelli \
  --title "Votelli 0.3.0" \
  --notes "What changed in this version…"
```

That one command creates the `v0.3.0` git tag, the release page, and uploads the
DMG. The README links to `/releases/latest`, so the download link updates itself.

## Signing identity (read this — it protects your users)

Votelli isn't notarized, so macOS keys each user's permission grants (Microphone,
Accessibility, Input Monitoring) to the **certificate leaf hash** of whatever
signed the app, via its designated requirement:

```
identifier "media.travis.votelli" and certificate leaf = H"ed332f703e45f439c303671ca8766627fcd7bc7a"
```

As long as **every release is signed by the same "Votelli Dev" certificate**,
users keep their permissions across updates. If the leaf hash ever changes, every
existing user has to re-grant all three permissions after updating — a bad
experience for a "just works" app.

The cert lives only in `~/Library/Keychains/votelli-dev.keychain-db` on the build
machine, and `scripts/setup_signing.sh` generates a **brand-new random cert** on
any machine that doesn't already have it. So:

- **Back up the identity now.** Export it and store the `.p12` somewhere safe
  (password manager / encrypted backup), so you can sign releases from any machine
  and never lose continuity. Export *outside* the repo so it can't be committed —
  the exported `.p12` is your private signing key, the one secret that actually
  matters here (the `votelli` export password is weak; keep the file protected):
  ```bash
  security unlock-keychain -p votelli-dev ~/Library/Keychains/votelli-dev.keychain-db
  security export -k ~/Library/Keychains/votelli-dev.keychain-db \
      -t identities -f pkcs12 -P votelli -o ~/votelli-signing-identity.p12
  ```
- **Restore on a new machine** (instead of re-running `setup_signing.sh`, which
  would make a different cert):
  ```bash
  security create-keychain -p votelli-dev ~/Library/Keychains/votelli-dev.keychain-db
  security unlock-keychain -p votelli-dev ~/Library/Keychains/votelli-dev.keychain-db
  security import ~/votelli-signing-identity.p12 -k ~/Library/Keychains/votelli-dev.keychain-db \
      -P votelli -T /usr/bin/codesign
  security list-keychains -d user -s ~/Library/Keychains/votelli-dev.keychain-db \
      $(security list-keychains -d user | sed -e 's/^ *//' -e 's/"//g')
  ```
- **If you ever deliberately rotate the cert**, update `RELEASE_LEAF_HASH` in the
  Makefile to the new leaf hash (find it with `codesign -d -r- Votelli.app`) and
  warn users that this one update will reset their permissions.

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
