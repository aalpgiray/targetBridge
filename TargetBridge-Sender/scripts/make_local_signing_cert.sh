#!/bin/bash
# Create a self-signed code-signing identity for local TargetBridge builds.
#
# WHY THIS EXISTS
#
# macOS keys TCC and Local Network grants to the code's designated requirement.
# For ad-hoc signed code (`codesign --sign -`) there is no certificate, so that
# requirement falls back to the cdhash — the exact bytes of the binary. Every
# rebuild is therefore a different app as far as macOS is concerned, and the
# Local Network grant does not carry over. Worse, the app NAME is unchanged, so
# System Settings shows a row that looks enabled while access is actually denied,
# and the list accumulates one dead `TargetBridge` row per rebuild.
#
# The sender then reports `NWError 50 - Network is down` and retries forever
# while `nc` reaches the receiver perfectly, and Bonjour discovery keeps working
# (it is brokered by mDNSResponder, which has its own access) — so the receiver
# still appears in the selector. Every one of those signals points away from the
# real cause. Days were lost to it.
#
# Signing with a real certificate makes the requirement identifier + certificate
# chain, which is stable across rebuilds. Grant Local Network once and it sticks.
# Self-signed is sufficient: nothing here needs notarization, because the app is
# not distributed to other machines. Swap in a Developer ID via TB_SIGN_IDENTITY
# if that changes.
#
# Idempotent: re-running when a valid identity already exists does nothing.

set -euo pipefail

NAME="${TB_SIGN_IDENTITY:-TargetBridge Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
    echo "\"$NAME\" already exists and is valid for code signing. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cs.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
O  = TargetBridge
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> generating a 10-year self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout tb.key -out tb.crt -config cs.cnf >/dev/null 2>&1

# The legacy PBE/MAC algorithms are REQUIRED. OpenSSL 3 defaults to a newer
# PKCS#12 MAC that Apple's Security framework rejects with
# "MAC verification failed during PKCS12 import (wrong password?)" — which reads
# like a bad passphrase and is not.
echo "==> packaging as PKCS#12 (legacy algorithms, for Apple's importer)"
openssl pkcs12 -export -inkey tb.key -in tb.crt -name "$NAME" \
    -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -passout pass:tbsign -out tb.p12 >/dev/null 2>&1

echo "==> importing into the login keychain"
security import tb.p12 -k "$KEYCHAIN" -P tbsign \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Importing alone leaves the identity CSSMERR_TP_NOT_TRUSTED, and codesign will
# not use it: `find-identity -v` reports "0 valid identities". Trusting it for the
# codeSign policy in the USER domain is what makes it usable, and needs no sudo.
echo "==> trusting it for code signing (user domain, no sudo needed)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" tb.crt

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
    echo
    echo "Done. \"$NAME\" is ready."
    echo
    echo "Next: rebuild and install the sender, then grant it Local Network ONCE"
    echo "in System Settings > Privacy & Security > Local Network. From then on"
    echo "every rebuild keeps that grant."
    echo
    echo "The old ad-hoc rows in that list belong to builds that no longer exist"
    echo "and can be left alone or removed; toggling them does nothing."
else
    echo "FAILED: identity was created but is still not valid for code signing." >&2
    exit 1
fi
