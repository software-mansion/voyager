set -euo pipefail
umask 077

CERTIFICATE_PEM="$RUNNER_TEMP/certificate.pem"
CERTIFICATE_DER="$RUNNER_TEMP/certificate.der"
CERTIFICATE_P12="$RUNNER_TEMP/certificate.p12"
PRIVATE_KEY_P12="$RUNNER_TEMP/private_key.p12"
KEY_PEM="$RUNNER_TEMP/key.pem"

echo -n "$CERTIFICATE_BASE64" | base64 --decode > "$RUNNER_TEMP/certificate.der"
openssl x509 -inform DER -in "$CERTIFICATE_DER" -outform PEM -out "$CERTIFICATE_PEM"

echo -n "$PRIVATE_KEY_BASE64" | base64 --decode > "$PRIVATE_KEY_P12"

CERTIFICATE_PASSWORD="$(openssl rand -base64 24)"
echo "::add-mask::$CERTIFICATE_PASSWORD"
export CERTIFICATE_PASSWORD

openssl pkcs12 -in "$PRIVATE_KEY_P12" -nodes -nocerts -passin env:PRIVATE_KEY_PASSWORD -out "$KEY_PEM"
openssl pkcs12 -export -inkey "$KEY_PEM" -in "$CERTIFICATE_PEM" -out "$CERTIFICATE_P12" -passout env:CERTIFICATE_PASSWORD
rm -f "$KEY_PEM"

CERTIFICATE_P12_BASE64="$(base64 -i "$CERTIFICATE_P12" | tr -d '\n')"
echo "::add-mask::$CERTIFICATE_P12_BASE64"
{
echo "APPLE_CERTIFICATE_P12_BASE64=$CERTIFICATE_P12_BASE64"
echo "APPLE_CERTIFICATE_P12_PASSWORD=$CERTIFICATE_PASSWORD"
} >> "$GITHUB_ENV"
