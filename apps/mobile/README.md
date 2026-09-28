# Hisaab mobile

Flutter app for iOS and Android. Includes onboarding, native Google/Apple identity and phone OTP, groups and direct friends, placeholder invitations, all four split modes, expense revisions, 90-day external-member review, invitation revocation, balance views, recorded payments/disputes, activity, preferences, account deletion, RevenueCat purchase/restore, and consent-gated AdMob banners.

## Illustrated interface

The approved illustrated design is implemented across the app's supported flows: welcome/sign-in, Home and group lists, expense entry and split review, group activity, payment recording, receipt capture/review/assignment/viewing, settings and the annual plan. Home has shortcuts for expense entry, group-specific receipt attachment and payment recording. All amounts, member details and store prices come from the current controller/repository.

`lib/core/design.dart` defines the evergreen, lime and warm ivory palette, Material 3 controls and bundled Outfit/Work Sans fonts. Editorial illustrations accompany welcome, group and receipt screens. `PageBody` constrains reading width on tablets, while forms and camera controls remain scrollable at larger text sizes. Asset provenance and font licences are in `assets/`.

Expense entry includes a calculator with exact decimal arithmetic, standard operator precedence and final rounding to the nearest paise. Confirming returns the amount to the existing split preview; Back leaves the expense unchanged. The save action remains visible below the scrollable form. The annual plan includes a clear return to the free account experience.

The mockup gallery also contains proposed expanded-v1 flows. This UI change does not implement their backend contracts: multiple payers, expense-level settlement/netting, live UPI handoff, recurrence, comments/search/export and lifetime purchases remain governed by `V1_REVISION_IMPLEMENTATION_PLAN.md`. The existing payment flow records an already-made payment; it does not move money. The annual plan uses the store's localized price and existing purchase safeguards.

## Run locally

Use Flutter **3.44.6 / Dart 3.12.2**, Android SDK 36, Java 17; iOS 15+ with Xcode and CocoaPods. Android minimum SDK is 23. Commit `pubspec.lock` and `ios/Podfile.lock` for reproducible dependencies.

```sh
cd apps/mobile
flutter pub get
flutter run
```

Tap **Explore the local demo** on the welcome screen. A visible **DEMO** label identifies the local playground. It has persistent sample groups and editable expenses, and runs without provider credentials or a backend. Settings → Reset demo data removes its local data. Demo data is isolated from real accounts; it cannot buy premium, issue live invitations, or grant an entitlement. Release builds hide demo entry unless explicitly built with `--dart-define=ENABLE_DEMO=true` for internal review.

```sh
flutter analyze
flutter test
flutter test test/ad_lifecycle_test.dart --dart-define=ADS_ENABLED=true --dart-define=ADS_POLICY_REVIEWED=true --dart-define=ADMOB_ANDROID_BANNER_ID=test-banner
flutter build apk --debug
flutter build ios --simulator --no-codesign
```

Tests cover exact decimal parsing, deterministic rounding/property checks up to 50 participants, account-scoped offline cache, token rotation and idempotent retries, demo ledger inverses/disputes, account-bound store identity failures and late responses, provisional purchase recovery, protected ad routes, and usable onboarding/home/settings widgets. Native provider and store sandbox acceptance still requires configured accounts and real devices.

## Connect a real API

Copy `config/example.json` to an ignored `config/production.json`, set the public configuration, then:

```sh
flutter run --dart-define-from-file=config/production.json
```

`API_BASE_URL` is the origin without `/v1` or a trailing slash, for example `https://api.example.com`. The client appends the versioned route. HTTPS is required in release; debug builds may use HTTP for local development when native transport policy permits it. Android emulators access the host through `10.0.2.2`; iOS simulators can use `127.0.0.1`. Production sign-in never falls back to the backend developer auth endpoint. Provider setup is required for authenticated local API integration.

Sessions and authorized read snapshots use `flutter_secure_storage`, keyed per Hisaab account. A connection failure makes cached data visibly read-only and disables mutations. Pull to refresh reconnects. Sign-out removes personal cache and tokens; demo storage is separate. Active group screens poll once per second while visible and foreground; home polls every two seconds. Background polling stops. These are fallback refresh intervals, not measured two-device convergence claims.

## Provider configuration

Follow the [authentication runbook](../../docs/runbooks/authentication.md) for provider registration, the complete client/server mapping and live-device acceptance. Source integration and passing tests do not establish live sign-in readiness.

| Setting | Purpose |
|---|---|
| `GOOGLE_CLIENT_ID` | iOS Google OAuth client ID; Android uses package/signing configuration. |
| `GOOGLE_SERVER_CLIENT_ID` | Web OAuth client ID used as the server audience; allow it in backend `Hisaab:Auth:google:ClientIds`. |
| `APPLE_SERVICE_ID` | Android web-flow Services ID; match backend `Hisaab:Auth:apple:ServiceId` and include it in `ClientIds` alongside the native bundle ID. |
| `APPLE_REDIRECT_URI` | Registered HTTPS callback ending in `/v1/auth/apple/callback`; exactly match backend `Hisaab:Auth:apple:RedirectUri`. |
| `REVENUECAT_IOS_KEY`, `REVENUECAT_ANDROID_KEY` | Platform public SDK keys; never backend secret keys. |
| `PRIVACY_URL`, `TERMS_URL` | Public HTTPS legal documents; both required before enabling purchase buttons. |
| `PUSH_ENABLED` | Enable only after Firebase/APNs native configuration and device testing. |
| `ADS_ENABLED`, `ADS_POLICY_REVIEWED` | Both default **false** and must be deliberately enabled after policy review. |
| `ADMOB_IOS_BANNER_ID`, `ADMOB_ANDROID_BANNER_ID` | Configured banner units; use Google test units during development. |
| `ENABLE_DEMO` | Internal release preview only; false for store distribution. |

Google/Apple identity tokens are sent to `/auth/sign-in`; only the server issues the Hisaab session. Apple uses a per-attempt SHA-256 nonce. Google Sign-In v7 supports nonce only during its mandatory once-per-process initialization, so this implementation uses Google issuer/audience/lifetime verification plus a fresh one-use server challenge, without asserting Google token nonce binding. Account linking first reauthenticates a currently linked method and checks the same Hisaab account, then verifies the newly linked provider. Existing conflicting accounts are not silently merged. Account deletion reauthenticates a linked provider and verifies the same Hisaab account immediately before submitting deletion.

Phone sign-in requests an SMS code from `/auth/phone/challenge`, then submits the code and returned nonce to `/auth/sign-in` using provider `phone`. The phone flow also supports linking and reauthentication before account deletion. Twilio Verify secrets and delivery configuration stay on the server; no additional mobile provider key or SMS-reading permission is needed. Backend configuration and signed-device SMS acceptance remain pending; see the [phone setup](../../docs/runbooks/authentication.md#configure-phone-otp) and [API contract](../../docs/api/implementation-contract.md).

For iOS, configure `GOOGLE_REVERSED_CLIENT_ID` and `ADMOB_APP_ID` through ignored `ios/Flutter/Local.xcconfig` or CI build settings. The committed AdMob application ID is Google's **test application ID**, not a live account. Configure the registered bundle ID and Apple Sign In capability in Xcode; select your signing team. No developer team is committed. Add Google URL scheme and OAuth audiences that match the backend configuration. The Android Apple callback activity and backend `/v1/auth/apple/callback` handler are included; register that HTTPS URL with Apple and set the backend's `AndroidPackage` to the installed package. The handler validates state and returns the SDK's `signinwithapple` intent URL. Backend token verification and code exchange still apply; code exchange sends `redirect_uri` for the configured Services ID only, leaving native iOS exchange without it.

Android's AdMob app ID can be supplied as Gradle property `ADMOB_APP_ID`; the default is Google's test app ID. Configure signing fingerprints/OAuth clients for your registered package `app.hisaab.hisaab`. Release artifacts are intentionally **not signed with a debug key**; supply proper store signing before distribution. Android backups are disabled to avoid restoring account tokens onto another installation.

For push, add the Firebase configuration using FlutterFire for the registered apps, enable the Google Services Gradle plugin for the generated Android resources, and add `GoogleService-Info.plist` to the Runner target. Enable Push Notifications capability/APNs environment and upload the APNs key to Firebase. Set `PUSH_ENABLED=true` only after that setup. Settings → Enable push requests OS permission and registers the token. Authorized devices reconnect on account restore. Server preferences remain independent of OS delivery permission. Actual APNs/FCM delivery is an external integration test.

## Purchases and ads

RevenueCat identifies users by the server's Hisaab account ID and reads the current **annual** offering. Every SDK operation verifies that native identity before and after execution. Identity transitions disable purchases immediately; failures and stale results cannot grant another account provisional access. The UI displays `storeProduct.priceString`, never a hardcoded ₹299 price. Configure the planned India price in the store product. Purchase and restore always call `/billing/refresh` for server verification. A successful SDK entitlement can suppress ads provisionally for at most 24 hours while verification catches up; the deadline is stored securely for that account and is never extended by failed verification. Foreground, online retries use bounded exponential backoff and recheck the store entitlement; it cannot create server premium. Store account mismatch/absent purchases produce a visible recovery message. Store management and deletion warnings remain available.

Banners are allowed only on Home, Groups and Activity. Navigation into details, editing, settlement, identity, subscription or settings suppresses/disposes the root ad. No-fill collapses the slot. All requests use `nonPersonalizedAds: true`, no user/ledger targeting, conservative child age treatment and general-audience content rating because v1 does not collect age. UMP is marked conservatively under-age and `canRequestAds()` must still permit requests. These controls **do not establish an approved minors policy**, and non-personalized ads do not resolve every consent or ATT obligation. Ads stay disabled until the release owner reviews age/audience, privacy, consent and platform requirements. No ATT request or personalized advertising is implemented. Interstitials are absent/disabled in this initial build.

## Release verification remaining

Real Apple/Google/phone sign-in and linking, Twilio SMS delivery, Android Apple callback, sandbox purchase/refund/grace/restore across stores/accounts, notifications, permission/consent behavior, signing, accessibility on physical devices and store approval require external configuration. No cloud resources, store products or production ads are enabled by this app's default build.


Invitation links use `hisaab://invite/{token}` by default. Initial and foreground links are allowlisted and the pending bearer token is kept in secure storage until sign-in; joining always requires explicit acceptance. It is cleared on acceptance, decline or sign-out. HTTPS invites require the same host in Dart `INVITE_HOST` and Android Gradle `INVITE_HOST`, an `assetlinks.json` association on the host, and iOS Associated Domains (`applinks:your-host`) plus its Apple App Site Association document. Configure the server `Hisaab:InviteBaseUrl` to that host’s `/invite` path. Unrecognized schemes/hosts are ignored. Apple Android web authentication sends and validates the server challenge as `state` as well as the hashed identity-token nonce.
