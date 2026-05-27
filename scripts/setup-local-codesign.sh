#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/signing-config.sh"

identity_name="$SWITCHBLADE_CODESIGN_IDENTITY_NAME"
support_dir="$SWITCHBLADE_CODESIGN_SUPPORT_DIR"
keychain_password_file="$SWITCHBLADE_CODESIGN_PASSWORD_FILE"
openssl_config="$support_dir/openssl-codesign.cnf"
private_key_path="$SWITCHBLADE_CODESIGN_PRIVATE_KEY"
certificate_path="$SWITCHBLADE_CODESIGN_CERTIFICATE"
archive_path="$SWITCHBLADE_CODESIGN_ARCHIVE"

mkdir -p "$support_dir"

if [[ -f "$keychain_password_file" ]]; then
    keychain_password="$(<"$keychain_password_file")"
else
    keychain_password="$(openssl rand -hex 16)"
    printf '%s' "$keychain_password" > "$keychain_password_file"
    chmod 600 "$keychain_password_file"
fi

if [[ -f "$archive_path" && -f "$certificate_path" && -f "$private_key_path" ]]; then
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

echo "$identity_name"
