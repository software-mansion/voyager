if [ -n "$P12_BASE64" ]; then
    CERTIFICATE_PATH=$RUNNER_TEMP/apple_certificate.p12
    KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db

    echo -n "$P12_BASE64" | base64 --decode -o $CERTIFICATE_PATH

    security create-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
    security set-keychain-settings -lut 21600 $KEYCHAIN_PATH
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH

    security import $CERTIFICATE_PATH -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k $KEYCHAIN_PATH
    security list-keychain -d user -s $KEYCHAIN_PATH
fi
