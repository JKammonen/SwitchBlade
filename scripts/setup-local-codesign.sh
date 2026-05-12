#!/bin/zsh

set -euo pipefail

identity_name="${CODESIGN_IDENTITY_NAME:-SwitchBlade Local Codesign}"
support_dir="$HOME/Library/Application Support/SwitchBlade/codesign"
keychain_path="$support_dir/SwitchBladeCodesign.keychain-db"
keychain_password_file="$support_dir/keychain-password.txt"
openssl_config="$support_dir/openssl-codesign.cnf"
private_key_path="$support_dir/private-key.pem"
certificate_path="$support_dir/certificate.pem"
archive_path="$support_dir/identity.p12"

mkdir -p "$support_dir"

if [[ -f "$keychain_password_file" ]]; then
    keychain_password="$(<"$keychain_password_file")"
else
    keychain_password="$(openssl rand -hex 16)"
    printf '%s' "$keychain_password" > "$keychain_password_file"
    chmod 600 "$keychain_password_file"
fi

if security find-identity -v -p codesigning "$keychain_path" 2>/dev/null | grep -Fq "$identity_name"; then
    security unlock-keychain -p "$keychain_password" "$keychain_path" >/dev/null 2>&1 || true
    echo "$identity_name"
    exit 0
fi

cat > "$openssl_config" <<EOF
[ req ]
default_bits = 2048
distinguished_name = dn
x509_extensions = extensions
prompt = no

[ dn ]
CN = $identity_name
O = SwitchBlade

[ extensions ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl req -new -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes \
    -config "$openssl_config" \
    -keyout "$private_key_path" \
    -out "$certificate_path" >/dev/null 2>&1

openssl pkcs12 -export \
    -inkey "$private_key_path" \
    -in "$certificate_path" \
    -out "$archive_path" \
    -passout pass:"$keychain_password" >/dev/null 2>&1

if [[ ! -f "$keychain_path" ]]; then
    security create-keychain -p "$keychain_password" "$keychain_path" >/dev/null
fi

security unlock-keychain -p "$keychain_password" "$keychain_path" >/dev/null
security set-keychain-settings -lut 21600 "$keychain_path" >/dev/null
security add-trusted-cert -d -r trustRoot -k "$keychain_path" "$certificate_path" >/dev/null 2>&1 || true
security import "$archive_path" \
    -k "$keychain_path" \
    -P "$keychain_password" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain_path" >/dev/null

echo "$identity_name"