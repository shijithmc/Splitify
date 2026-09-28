# Google, Apple and phone authentication

The source implements provider sign-in, server verification, rotating Hisaab sessions, credential linking and account deletion. Live readiness requires completed provider registrations, a reachable API, signing and the device checks below. Demo mode, mock tests and unsigned simulator builds do not verify those dependencies.

## Configure phone OTP

Phone sign-in uses Twilio Verify from the backend. The app accepts an international phone number with its country code, requests an SMS and submits the six-digit code. The server binds proof to the phone number, challenge purpose and, for linking or reauthentication, the current account. A typed number is never proof of ownership and does not claim invitations. Separate existing accounts are not merged.

1. In the environment's Twilio account, create a Verify service, enable SMS and set the code length to **six digits**. Create an API key authorized to create and check verifications in that service. Keep the key secret entirely in backend configuration. The app needs only its existing `API_BASE_URL`. [Twilio Verify services](https://www.twilio.com/docs/verify/api/service)
2. Allow only supported destinations in **Verify Geo Permissions** and confirm delivery in each intended country. Leave Fraud Guard enabled and set provider usage alerts and operational spending limits. Application admission limits below complement these settings. [Verify deliverability](https://www.twilio.com/docs/verify/verify-countries-and-regions-deliverability), [Verify fraud prevention](https://www.twilio.com/docs/verify/preventing-toll-fraud)
3. For India, confirm with Twilio which Verify delivery route and sender/template setup apply to the account. Twilio documents different international and domestic routes; domestic routing includes DLT company and sender registration. Do not assume a generic Verify service has completed the environment's required setup. [Twilio India SMS guidelines](https://www.twilio.com/en-us/guidelines/in/sms)
4. Populate `Hisaab:Auth:Phone:ServiceSid`, `ApiKeySid` and `ApiKeySecret` in the existing backend secret, then set `Hisaab:Auth:Phone:Enabled` to `true` and restart the API. The service defaults to disabled and returns a sanitized unavailable response when missing configuration. No SMS credentials belong in Dart defines, assets or source control.

`Hisaab:Auth:Phone:MaxSmsPerDay` defaults to `100`; `MaxSmsPerMinute` defaults to `10`. These bound application SMS attempts across the environment, including failed sends. Keep configuration identical across API instances. Additional per-number/IP limits and verification ceilings are listed in [API abuse protection](api-rate-limits.md#phone-otp). A provider-accepted send does not prove delivery. Recheck Twilio trial restrictions before using a trial account for acceptance; trial recipients and countries can be restricted. [Twilio trial account setup](https://www.twilio.com/docs/usage/tutorials/how-to-use-your-free-trial-account)

Phone OTP also requires the existing `Hisaab:EncryptionKey` and `Hisaab:ContactHashKey`. Challenges keep the phone encrypted, expire after ten minutes and allow at most five code checks; the backend never stores the OTP. The persistent phone identity is a keyed hash. Preserve `ContactHashKey` across deployments: changing it changes phone identity lookup and requires a separately planned migration. Keep phone numbers, codes, nonces, provider payloads and credentials out of request logs and acceptance reports.

Use an explicitly linked Google or Apple method to retain another way into a phone account. This implementation does not add phone-number change/recovery or account merging. A phone number can be reassigned by its carrier; the account identity follows possession of the linked number until a separately designed recovery flow exists.

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
| Phone SMS verification | Backend only | `Hisaab:Auth:Phone:Enabled`, `ServiceSid`, `ApiKeySid`, `ApiKeySecret`; configure a six-digit Twilio Verify service. |
| SMS attempt ceilings | Backend only | `Hisaab:Auth:Phone:MaxSmsPerDay` (default `100`), `MaxSmsPerMinute` (default `10`). |
| Token encryption key | Backend only | `Hisaab:EncryptionKey`: base64 encoding of 32 random bytes. Preserve it to decrypt existing Apple refresh tokens and phone challenges. |
| Contact lookup / phone identity secret | Backend only | `Hisaab:ContactHashKey`: independent high-entropy secret; preserve it for stable phone identity lookup. |

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
  "Hisaab:Auth:Phone:Enabled": "false",
  "Hisaab:Auth:Phone:ServiceSid": "<verify-service-sid>",
  "Hisaab:Auth:Phone:ApiKeySid": "<api-key-sid>",
  "Hisaab:Auth:Phone:ApiKeySecret": "<api-key-secret>",
  "Hisaab:Auth:Phone:MaxSmsPerDay": "100",
  "Hisaab:Auth:Phone:MaxSmsPerMinute": "10",
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
- [ ] Phone: new and returning account on signed iOS and Android installations using an authorized SMS recipient; record delivery and sign-in result for each intended country/carrier.
- [ ] Phone: malformed number, incorrect/expired code, repeated submit, resend cooldown, send/verify limits, provider outage and disabled configuration produce safe errors without a session.
- [ ] Phone: link after reauthentication, sign out and return through either linked method; a number owned by another account fails without merging. Confirm phone reauthentication for linking and disposable-account deletion preserves the current account.
- [ ] Relaunch and session refresh preserve the same account; sign-out followed by another account exposes no previous account's cached data.
- [ ] Link the second provider after reauthentication, then sign in through either method and reach the same Hisaab account. A provider linked to a different account must fail without silently merging.
- [ ] Cancel, network failure and expired/reused challenge leave the user signed out or preserve their existing authenticated account as appropriate.
- [ ] Delete a disposable Apple-linked account after reauthentication; confirm backend deletion and Apple revocation complete, then verify the old Hisaab session no longer works.

Until these checks pass against configured services, report authentication as implemented but **live acceptance pending**.
