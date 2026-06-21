#!/usr/bin/env bash
# Create a stable self-signed "Murmur Dev" code-signing identity in a dedicated
# keychain, so rebuilds keep the same code identity and macOS doesn't reset the
# app's TCC permissions (Mic / Accessibility / Input Monitoring) on every build.
#
# Idempotent: re-running is a no-op if the identity already exists.
set -euo pipefail

IDENTITY="Murmur Dev"
KC_NAME="murmur-dev.keychain-db"
KC="$HOME/Library/Keychains/$KC_NAME"
KC_PASS="murmur-dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "signing identity '$IDENTITY' already present"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:murmur -name "$IDENTITY" >/dev/null 2>&1

# Dedicated keychain with a known password keeps this fully non-interactive.
[[ -f "$KC" ]] || security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P murmur -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null 2>&1

# Add to the user keychain search list so codesign can find the identity.
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
if ! echo "$EXISTING" | grep -q "$KC_NAME"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KC" $EXISTING
fi

echo "created signing identity '$IDENTITY'"
security find-identity -v -p codesigning | grep "$IDENTITY" || true
