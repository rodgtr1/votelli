# Publishing a release

How to cut a new Votelli release: build the signed DMG and publish it to GitHub.
Run everything from the repo root.

The loop: **bump version → commit & push → `make dmg` → `gh release create`.**

## 1. Bump the version

Edit `Resources/Info.plist` and bump both keys:

```xml
<key>CFBundleShortVersionString</key>
<string>0.5.0</string>            <!-- public version, used for the DMG filename -->
<key>CFBundleVersion</key>
<string>5</string>                 <!-- internal build number; just increment it -->
```

## 2. Commit and push

The release tags a commit, so the code must be on GitHub first.

```bash
git add -A
git commit -m "Release 0.5.0: <what changed>"
git push origin main
```

## 3. Build, notarize, and staple the DMG

```bash
make dmg
```

One command does the whole release. It:

1. builds the app and signs it with the **Developer ID** identity — hardened
   runtime (`--options runtime`) on the bundle, a secure Apple timestamp on every
   Mach-O, and the `Resources/Votelli.entitlements` (mic access only),
2. verifies the signature (`codesign --verify --deep --strict`) and checks the
   certificate leaf hash against `RELEASE_LEAF_HASH` in the Makefile,
3. packages `Votelli-<version>.dmg` (version taken from `Info.plist`),
4. submits it to Apple with `xcrun notarytool submit --keychain-profile
   "votelli-notary" --wait` and blocks until Apple returns a verdict — usually a
   few minutes,
5. staples the notarization ticket into the DMG and runs a final Gatekeeper
   assessment (`stapler validate` + `spctl -a -t open`).

Anything less than an `Accepted` verdict stops the release and prints the
`notarytool log` for the submission — there's no path that silently ships an
unstapled DMG.

Unlike `make app`, the release build **refuses to fall back to ad-hoc or
development signing**. That guard exists for one reason: see "Signing identity"
below.

## 4. Publish the GitHub release

```bash
gh release create v0.5.0 Votelli-0.5.0.dmg \
  --repo rodgtr1/votelli \
  --title "Votelli 0.5.0" \
  --notes "What changed in this version…"
```

That one command creates the `v0.5.0` git tag, the release page, and uploads the
DMG. The README links to `/releases/latest`, so the download link updates itself.

## Signing identity (read this — it protects your users)

Releases are signed with:

```
Developer ID Application: TRAVIS KEITH RODGERS (2UWZ923R8C)
leaf SHA-1: 7351c39bc57da9bba73ffc330aaab0e0144adaa7
```

`scripts/bundle.sh` selects this identity **by leaf hash, not by name**, so a
different certificate with the same subject can't quietly take its place.

The hash matters beyond notarization: macOS keys each user's permission grants
(Microphone, Accessibility, Input Monitoring) to the **certificate leaf hash** of
whatever signed the app. As long as every release is signed by this same
certificate, users keep their permissions across updates. If the leaf hash
changes, every existing user has to re-grant all three permissions after
updating — a bad experience for a "just works" app.

- **Back up the identity.** Export it from Keychain Access (login keychain → My
  Certificates → the Developer ID Application cert → Export) as a `.p12` and store
  it somewhere safe. Export *outside* the repo so it can't be committed. Losing the
  private key means a new certificate, a new leaf hash, and a one-time permission
  reset for every user.
- **If you ever deliberately rotate the cert**, update `RELEASE_LEAF_HASH` in the
  Makefile to the new leaf hash (`security find-identity -v -p codesigning`) and
  warn users that this one update will reset their permissions.
- **`scripts/setup_signing.sh` is for development only.** It creates the
  self-signed "Votelli Dev" identity that `make app` / `make run` / `make install`
  use. Release builds never touch it.

## Notarization credentials

`make dmg` uses the `votelli-notary` keychain profile, already stored on the build
machine. To recreate it (new machine, or after rotating the app-specific password):

```bash
xcrun notarytool store-credentials "votelli-notary" \
    --apple-id <your-apple-id> \
    --team-id 2UWZ923R8C \
    --password <app-specific-password>
```

Generate the app-specific password at [appleid.apple.com](https://appleid.apple.com)
→ Sign-In and Security → App-Specific Passwords. It is not your Apple ID password.

## Gotchas

- **A keychain dialog appears on the first signing** — macOS asks whether
  `codesign` may use the Developer ID private key. Click **Always Allow** (not just
  "Allow") so later releases don't stop and wait for you. If you miss the dialog,
  `make dmg` blocks until it's answered.
- **Notarization needs the network.** `--wait` uploads the whole DMG (~130 MB) and
  polls Apple; on a bad connection it's slow, not broken. `NOTARIZE=0 make dmg`
  builds an unnotarized DMG for local testing — never ship that one.
- **Never `git add` the DMG.** It's ~130 MB and GitHub rejects files over 100 MB.
  `*.dmg` is in `.gitignore`, so `git add -A` is safe — the DMG only travels via
  `gh release create`, never through git.
- **`gh` not logged in** — run `gh auth login` once.

## Notes

- The DMG is Developer ID-signed, notarized, and stapled, so downloaders open it
  with no Gatekeeper warning and no `xattr` incantation — and the stapled ticket
  means it validates even if their Mac is offline.
- Building from source on your own machine (`make install`) is never quarantined.
