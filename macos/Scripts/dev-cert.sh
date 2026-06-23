#!/bin/bash
# Create a stable local code-signing identity ("LCT Dev") for development.
#
# Why: ad-hoc signatures (codesign --sign -) change on every build, and macOS
# ties TCC permissions (screen recording, microphone, speech) to the signing
# identity. So each rebuild looks like a brand-new app and forces you to
# re-grant permissions. A stable self-signed identity fixes that — grant once,
# then permissions persist across rebuilds.
#
# Run once: ./scripts/dev-cert.sh   (then rebuild with ./package-app.sh)
# The certificate is local-only, needs no Apple account, and never leaves your Mac.
set -euo pipefail

IDENTITY="LCT Dev"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = LCT Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes -config "$WORK/cert.conf" 2>/dev/null

# macOS `security` can't read modern OpenSSL PKCS#12: force legacy algorithms
# and a non-empty password (empty-password p12 import is buggy on macOS).
openssl pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/cert.p12" \
    -name "$IDENTITY" -passout pass:lctdev 2>/dev/null

# -A lets codesign use the private key without a keychain prompt on every build.
security import "$WORK/cert.p12" -k ~/Library/Keychains/login.keychain-db -P lctdev -A

echo "Created code-signing identity '$IDENTITY'."
echo "Rebuild with ./package-app.sh. You'll re-grant permissions ONCE more"
echo "(new identity), after which they persist across all future rebuilds."
