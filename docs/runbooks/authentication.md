# Google and Apple authentication

The source implements provider sign-in, server verification, rotating Hisaab sessions, credential linking and account deletion. Live readiness requires completed provider registrations, a reachable API, signing and the device checks below. Demo mode, mock tests and unsigned simulator builds do not verify those dependencies.

## Register Google clients

1. Use the product's Google Cloud project. Complete Google Auth Platform branding/audience configuration and add the intended testers while the app is in testing.
2. Create an **iOS** OAuth client for bundle ID `app.hisaab.hisaab`. Its client ID becomes `GOOGLE_CLIENT_ID`; its reversed client ID becomes the iOS URL scheme. Create a **Web application** OAuth client for `GOOGLE_SERVER_CLIENT_ID`. The app requests an ID token for this server audience; this integration does not need the Web client's secret in Flutter. [Google iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating)
3. Create **Android** OAuth clients for package `app.hisaab.hisaab` and each signing certificate used to install the app. Register the debug certificate for local testing and the Play app-signing certificate for Play builds; an upload certificate alone does not identify the Play-installed app. Obtain local SHA-1 fingerprints with `./gradlew signingReport` from `apps/mobile/android`, or `keytool -list -v -keystore "$HOME/.android/debug.keystore" -alias androiddebugkey` for the default debug key. [Google credential registration](https://developers.google.com/workspace/guides/create-credentials), [Android signing certificates](https://developer.android.com/studio/publish/app-signing#api-providers)
4. Keep the Web client ID identical in `GOOGLE_SERVER_CLIENT_ID` and the backend audience allowlist. This app supplies it directly, so Google sign-in does not require Firebase files. Missing fingerprints, package mismatches or the wrong server client can appear as a cancellation after account selection. [Flutter Google Android setup](https://pub.dev/packages/google_sign_in_android)

## Register Apple identifiers and signing

1. In Apple Developer, enable **Sign in with Apple** on the primary App ID for `app.hisaab.hisaab`. In `apps/mobile/ios/Runner.xcworkspace`, select the authorized team, confirm that capability and refresh the provisioning profile. The entitlement is already present in source; a profile must authorize it. [Apple capability setup](https://developer.apple.com/documentation/xcode/configuring-sign-in-with-apple)
2. Create a **Services ID** for Android web authentication and associate it with that primary App ID. Register the API domain and the exact return URL, for example `https://api.example.com/v1/auth/apple/callback`. Use a publicly reachable HTTPS domain, without an IP address, localhost or fragment. [Apple Services ID setup](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web), [Apple authorization request](https://developer.apple.com/documentation/signinwithapplerestapi/request-an-authorization-to-the-sign-in-with-apple-server.)
3. Create a Sign in with Apple private key associated with the primary App ID. Store the downloaded `.p8` key, key ID and team ID in backend secret configuration. Never add the private key or a generated client secret to Dart defines, app assets or source control. [Apple private-key setup](https://developer.apple.com/help/account/capabilities/create-a-sign-in-with-apple-private-key)
4. Configure the mapping below. The API accepts Apple's form POST, validates its server challenge and redirects into the registered Android package. It then verifies the ID token and exchanges the authorization code. The exchange includes the exact `redirect_uri` only when the verified audience equals the configured Services ID; native iOS uses its bundle-ID audience without a redirect URI. [Apple token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)

## Match configuration across surfaces

Copy `apps/mobile/config/example.json` to ignored `apps/mobile/config/production.json`. These mobile values are public configuration, not a secret store. Backend environment variables use `__`; a Secrets Manager JSON secret uses `:`.

| Value | Mobile / native setting | Backend configuration key |
|---|---|---|
| API origin, without `/v1` or trailing slash | `API_BASE_URL` | Deploy a reachable API at that origin. |
| Google iOS OAuth client | `GOOGLE_CLIENT_ID` | Usually not the requested server audience. |
| Reversed Google iOS client ID | `GOOGLE_REVERSED_CLIENT_ID` in ignored `ios/Flutter/Local.xcconfig` | None. |
| Google Web OAuth client ID | `GOOGLE_SERVER_CLIENT_ID` | `Hisaab:Auth:google:ClientIds` (comma-separated accepted audiences). |
| Apple native bundle ID | Xcode `PRODUCT_BUNDLE_IDENTIFIER` | Include in `Hisaab:Auth:apple:ClientIds`, without the team-ID prefix. |
| Apple Services ID | `APPLE_SERVICE_ID` | `Hisaab:Auth:apple:ServiceId`; also include in Apple `ClientIds`. |
| Apple registered return URL | `APPLE_REDIRECT_URI` | `Hisaab:Auth:apple:RedirectUri`, exactly identical. |
| Installed Android package | Gradle `applicationId` | `Hisaab:Auth:apple:AndroidPackage`. |
| Apple credentials | Backend only | `Hisaab:Auth:apple:TeamId`, `KeyId`, `PrivateKey`. |
| Token encryption key | Backend only | `Hisaab:EncryptionKey`: base64 encoding of 32 random bytes. Preserve it to decrypt existing Apple refresh tokens. |
| Contact lookup secret | Backend only | `Hisaab:ContactHashKey`: independent high-entropy secret. |

For hosted operation, use the existing [infrastructure configuration](../../infra/Hisaab.Cdk/README.md). Supply an existing secret ARN through `ConfigurationSecretArn` (or `Hisaab__SecretsArn` outside CDK). The loader requires a **flat JSON object with string values**, for example:

```json
{
  "Hisaab:Auth:google:ClientIds": "<google-web-client-id>",
  "Hisaab:Auth:apple:ClientIds": "app.hisaab.hisaab,<apple-services-id>",
  "Hisaab:Auth:apple:ServiceId": "<apple-services-id>",
  "Hisaab:Auth:apple:RedirectUri": "https://api.example.com/v1/auth/apple/callback",
  "Hisaab:Auth:apple:AndroidPackage": "app.hisaab.hisaab",
  "Hisaab:Auth:apple:TeamId": "<team-id>",
  "Hisaab:Auth:apple:KeyId": "<key-id>",
  "Hisaab:Auth:apple:PrivateKey": "<PEM private key with JSON-escaped newlines>",
  "Hisaab:EncryptionKey": "<base64-32-random-bytes>",
  "Hisaab:ContactHashKey": "<independent-random-secret>"
}
```

These are placeholders. Merge the auth fields into the secret's existing configuration; replacing the whole secret could remove other services' settings. Use Secrets Manager or a protected local file, not command-line secret literals. The function needs read access to that exact secret and, for a customer-managed encryption key, its required KMS decrypt permission. Restart the API after updating configuration: the loader reads it at startup. `.env.example` is a key reference; `scripts/run-api.sh` does not automatically load an `.env` file.

Run the configured app from `apps/mobile` with `flutter run --dart-define-from-file=config/production.json`. Keep demo disabled for release acceptance. Android release signing remains a release-owner configuration; debug builds do not prove Play signing. No provider credentials or infrastructure are created by this runbook.

## Live acceptance checklist

Use dedicated test accounts and record build, OS, platform, API environment and result without tokens or private credentials. Leave an item pending until observed on a signed installation.

- [ ] Google: new and returning account on iOS and Android, including the actual Play-installed signing configuration before release.
- [ ] Apple: new and returning account on iOS; repeat with Hide My Email and confirm repeat sign-in tolerates missing name information.
- [ ] Apple on Android: browser consent returns to the app through the registered callback; code exchange succeeds; cancel/back returns safely without a Hisaab session.
- [ ] Relaunch and session refresh preserve the same account; sign-out followed by another account exposes no previous account's cached data.
- [ ] Link the second provider after reauthentication, then sign in through either method and reach the same Hisaab account. A provider linked to a different account must fail without silently merging.
- [ ] Cancel, network failure and expired/reused challenge leave the user signed out or preserve their existing authenticated account as appropriate.
- [ ] Delete a disposable Apple-linked account after reauthentication; confirm backend deletion and Apple revocation complete, then verify the old Hisaab session no longer works.

Until these checks pass against configured services, report authentication as implemented but **live acceptance pending**.
