#!/bin/zsh

set -euo pipefail
umask 077

project_root="${0:A:h:h}"
app_path="$project_root/dist/TodoBar.app"
sign_only=false
if (( $# > 1 )); then
  print -u2 "Usage: $0 [--sign-only]"
  exit 2
fi
case "${1:-}" in
  "") ;;
  --sign-only)
    sign_only=true
    codesign --verify --deep --strict "$app_path"
    ;;
  *)
    print -u2 "Usage: $0 [--sign-only]"
    exit 2
    ;;
esac

manifest="$project_root/release-manifest.json"
restore_directory="$(mktemp -d /tmp/todobar-signing.XXXXXX)"
keychain_path="$restore_directory/signing.keychain-db"
keychain_password="$(openssl rand -base64 32 | tr -d '\n')"
original_keychains=()
while IFS= read -r keychain; do
  keychain="${keychain#*\"}"
  keychain="${keychain%\"*}"
  [[ -n "$keychain" ]] && original_keychains+=("$keychain")
done < <(security list-keychains -d user)

cleanup() {
  if (( ${#original_keychains[@]} )); then
    security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  find "$restore_directory" -depth -delete
}
trap cleanup EXIT

"$project_root/scripts/restore-release-signing.sh" "$restore_directory"
password_file="$restore_directory/p12-password"
pem_path="$restore_directory/developer-id.pem"
op item get "$(jq -r '.signing.p12PasswordItem' "$manifest")" \
  --vault "Mobile App Releases" \
  --fields label=password \
  --reveal > "$password_file"
chmod 600 "$password_file"
openssl pkcs12 -legacy \
  -in "$restore_directory/developer-id.p12" \
  -passin "file:$password_file" \
  -nodes \
  -out "$pem_path"
chmod 600 "$pem_path"

security create-keychain -p "$keychain_password" "$keychain_path" >/dev/null
security set-keychain-settings -lut 900 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$pem_path" \
  -k "$keychain_path" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path" "${original_keychains[@]}"

identity="$(jq -r '.signing.identity' "$manifest")"
if ! security find-identity -v -p codesigning "$keychain_path" | grep -F "$identity" >/dev/null; then
  print -u2 "Restored keychain does not contain the expected Developer ID identity"
  exit 1
fi

cd "$project_root"
if $sign_only; then
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$app_path"
else
  SIGN_IDENTITY="$identity" ./scripts/build-app.sh
fi

codesign --verify --deep --strict "$app_path"
print "Verified signed TodoBar.app"
