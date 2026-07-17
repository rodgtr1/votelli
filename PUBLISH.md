# Publishing a release

How to cut a new Votelli release: build the signed DMG, publish it to GitHub, and
push the Sparkle update feed so existing installs can find it.

The shipped binary is built from the **Pro repo**, which vendors this core repo as
the `Vendor/votelli` submodule and produces the single notarized app. The DMG is
then published as a release asset on this **public core repo**, and the Sparkle
`appcast.xml` is served from this repo's `gh-pages` branch. So a release touches
both repos; the steps below call out which one each command runs in.

The loop: **bump version → commit & push (both repos) → `make dmg` → sign the
appcast → `gh release create` → publish the appcast.**

## 1. Bump the version

Edit `Resources/Info.plist` and bump both keys:

```xml
<key>CFBundleShortVersionString</key>
<string>0.6.0</string>            <!-- public version, used for the DMG filename -->
<key>CFBundleVersion</key>
<string>6</string>                 <!-- internal build number; just increment it -->
```

## 2. Commit and push

The release tags a commit, so the code must be on GitHub first. Commit and push
this core repo, then in the **Pro repo** re-pin the `Vendor/votelli` submodule to
the new core commit and commit that — the DMG is built from the pinned submodule,
so an unpinned submodule ships stale code.

```bash
# core repo
git add -A
git commit -m "Release 0.6.0: <what changed>"
git push origin main

# Pro repo
git -C ../votelli-pro submodule update --remote Vendor/votelli
git -C ../votelli-pro add Vendor/votelli
git -C ../votelli-pro commit -m "Pin Vendor/votelli to 0.6.0"
git -C ../votelli-pro push
```

## 3. Build, notarize, and staple the DMG

Run this in the **Pro repo** — that build produces the single binary that ships.

```bash
make dmg
```

One command does the whole release build. It:

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

Unlike a plain `make app`, the release build sets `REQUIRE_STABLE_IDENTITY=1` and
**refuses to fall back to ad-hoc signing**. That guard exists for one reason: see
"Signing identity" below.

## 4. Sign the appcast

Still in the **Pro repo**:

```bash
bash scripts/make_appcast.sh
```

This regenerates `appcast.xml` and signs the new entry with the Sparkle EdDSA
**private** key (login Keychain, service `https://sparkle-project.org`). The
enclosure `url` points at the GitHub release asset — the DMG you upload in the
next step — and the `sparkle:edSignature` is what the installed app verifies
against the public key baked into `Info.plist` (`SUPublicEDKey`). An appcast entry
that isn't signed by the matching private key is silently ignored by every client,
so this step is not optional.

## 5. Publish the GitHub release

The DMG is a release asset on the **public core repo** (`rodgtr1/votelli`); the
README links to `/releases/latest`, so the download link updates itself.

```bash
gh release create v0.6.0 Votelli-0.6.0.dmg \
  --repo rodgtr1/votelli \
  --title "Votelli 0.6.0" \
  --notes-file <notes.md>
```

That one command creates the `v0.6.0` git tag, the release page, and uploads the
DMG. The enclosure URL in the appcast must match this asset's download URL.

## 6. Publish the appcast to GitHub Pages

The app fetches its feed from `https://rodgtr1.github.io/votelli/appcast.xml` —
served from this repo's **`gh-pages`** branch (the URL is compiled into the app in
`Sources/VotelliCore/Updater.swift`, not the plist). Copy the freshly signed
`appcast.xml` onto `gh-pages` and push:

```bash
git checkout gh-pages
cp <path-to-signed>/appcast.xml appcast.xml
git add appcast.xml
git commit -m "appcast: 0.6.0"
git push origin gh-pages
git checkout main
```

Until this lands, existing installs won't see the update even though the DMG is
live — the release asset and the feed are published separately, and the feed is
what "Check for Updates…" reads.

## Signing identity (read this — it protects your users)

Both dev and release builds sign with the **same** Developer ID certificate:

```
Developer ID Application: TRAVIS KEITH RODGERS (2UWZ923R8C)
leaf SHA-1: 7351c39bc57da9bba73ffc330aaab0e0144adaa7
```

`scripts/bundle.sh` selects this identity **by leaf hash, not by name**, so a
different certificate with the same subject can't quietly take its place. Release
builds add hardened runtime + a secure timestamp (both required for notarization);
dev builds skip those so they stay fast and offline. When the Developer ID isn't
installed at all (an outside contributor building the open-source app), the dev
path falls back to **ad-hoc** signing — fine for local use, it just re-prompts for
permissions on each rebuild. There is no separate self-signed development identity
to create anymore.

The hash matters beyond notarization: macOS keys each user's permission grants
(Microphone, Accessibility, Input Monitoring) to the **certificate leaf hash** of
whatever signed the app — and for the two high-privilege ones (Accessibility,
Input Monitoring) it only *persists* the grant across a rebuild when that cert is
Apple-anchored (`anchor apple generic`), which a self-signed cert can never be.
As long as every build — dev and release alike — is signed by this one Developer
ID, permissions survive rebuilds *and* survive switching between a local build and
the notarized release. If the leaf hash changes, every existing user has to
re-grant all three permissions after updating — a bad experience for a "just
works" app.

- **Back up the identity.** Export it from Keychain Access (login keychain → My
  Certificates → the Developer ID Application cert → Export) as a `.p12` and store
  it somewhere safe. Export *outside* the repo so it can't be committed. Losing the
  private key means a new certificate, a new leaf hash, and a one-time permission
  reset for every user.
- **If you ever deliberately rotate the cert**, update `RELEASE_LEAF_HASH` in the
  Makefile to the new leaf hash (`security find-identity -v -p codesigning`) and
  warn users that this one update will reset their permissions.

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

## Master secrets — back these up (all unrecoverable if lost)

Three private keys are single points of failure. None can be regenerated; losing
any one is a one-way door for that capability.

1. **Developer ID `.p12`** (login Keychain) — signs every build. Losing it forces
   a new certificate, a new leaf hash, and a one-time permission reset for every
   user. Backup and rotation are covered under "Signing identity" above.
2. **Sparkle update key** (login Keychain, service `https://sparkle-project.org`).
   Its public half is `SUPublicEDKey` in `Info.plist`; the private half signs each
   appcast entry. Sparkle refuses any entry not signed by the key that pairs with
   the public key the *installed* app shipped — there is no revocation and no
   server, so losing this private key means you can never ship a trusted update to
   existing installs again. Back it up with Sparkle's
   `generate_keys -x <file>` and store it outside the repo.
3. **License signing key** (`~/.votelli/license-signing.key`, Ed25519) — used by
   the Pro licensing tooling, not by this core release flow, but it's the third
   unrecoverable master secret; back it up alongside the other two.

## Gotchas

- **A keychain dialog appears on the first signing** — macOS asks whether
  `codesign` may use the Developer ID private key. Click **Always Allow** (not just
  "Allow") so later releases don't stop and wait for you. If you miss the dialog,
  `make dmg` blocks until it's answered. Signing the appcast prompts the same way
  for the Sparkle key the first time.
- **Notarization needs the network.** `--wait` uploads the whole DMG (~130 MB) and
  polls Apple; on a bad connection it's slow, not broken. `NOTARIZE=0 make dmg`
  builds an unnotarized DMG for local testing — never ship that one.
- **Never `git add` the DMG.** It's ~130 MB and GitHub rejects files over 100 MB.
  `*.dmg` is in `.gitignore`, so `git add -A` is safe — the DMG only travels via
  `gh release create`, never through git.
- **The appcast URL must match the release asset.** If the enclosure `url` in
  `appcast.xml` doesn't resolve to the uploaded DMG, updates fail to download even
  though the feed parses.
- **`gh` not logged in** — run `gh auth login` once.

## Notes

- The DMG is Developer ID-signed, notarized, and stapled, so downloaders open it
  with no Gatekeeper warning and no `xattr` incantation — and the stapled ticket
  means it validates even if their Mac is offline.
- Building from source on your own machine (`make install`) is never quarantined.
- Updates are pull-only: the app never checks in the background. A user gets the
  new version when they click **Check for Updates…**, at which point Sparkle reads
  the appcast, verifies the signature, and installs the signed DMG in place.
