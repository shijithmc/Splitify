# Live authentication setup status

Updated 27 September 2026. The physical iPhone build uses source commit `f0cb18e`; application code is unchanged from the deployed backend and simulator source `765ba5d`. This records environment setup separately from observed sign-in results. **Real-account authentication acceptance is pending.** Installation, provider registration and API health checks do not establish a successful native login.

## Environment and registrations

| Surface | Public identifier | Status |
|---|---|---|
| AWS development environment | Account `515504445517`, region `ap-south-1`, stack `Hisaab-dev` | Deployed; public API checks below passed. |
| API origin | `https://x82tsr0e99.execute-api.ap-south-1.amazonaws.com` | Reachable over HTTPS. |
| Backend configuration | Secrets Manager secret `hisaab/dev/configuration` | Stores backend configuration; secret values must remain outside source control. |
| Google Cloud | Project `hisaab-app-2026` | Web, iOS and local-debug Android OAuth clients registered; owner added as a tester. Audience remains Testing; production publication and native validation pending. |
| Apple Developer | Team `733WGQVMLJ` | Existing authorized team. |
| Apple native app | App ID / bundle ID `app.hisaab.hisaab` | Registered with Sign in with Apple enabled. |
| iPhone development profile | `Hisaab iPhone Development` | Active; includes the connected iPhone, existing development certificate and Sign in with Apple capability. Installed locally; profile files remain outside source control. |
| Apple Android web flow | Services ID `app.hisaab.hisaab.web` | Associated with the primary Hisaab App ID; API hostname and return URL saved in Apple Developer. |
| Apple signing key | Key ID `RU8TZK9587` | Registered; private key retained outside the repository. |

The registered Apple return URL is the API origin above plus `/v1/auth/apple/callback`. The Android package also uses the native bundle identifier above. The Google iOS, Web and Android OAuth clients must belong to the project above. Keep client configuration in the environment's mobile configuration; do not add provider tokens, private keys or client secrets to this document. Use the [authentication runbook](authentication.md#match-configuration-across-surfaces) for the exact mobile/backend mapping.

The live API origin, Google iOS/Web clients, Apple Services ID and callback are set in ignored mobile configuration. The ignored iOS configuration supplies the matching reversed Google URL scheme, Apple team and development signing profile. Simulator and physical iPhone builds using these settings compiled, installed and launched; their bundle identifiers and Google callback URL schemes were verified. Successful provider sign-in remains unverified. Public privacy/terms pages and completed branding are still required before production publication.

The existing local Android **debug-only** certificate has SHA-1 `C9:3B:3E:37:85:CF:9A:D5:48:E7:E4:02:3A:AC:65:F9:3D:E8:8E:C5`. Registering it covers installations signed with that certificate. CI debug keys and Play app-signing certificates need their own matching Android OAuth registrations. This fingerprint does not demonstrate release-signing readiness.

## Observed API checks

All three deployed Lambda functions reloaded the backend configuration. The API returned health `200`, disabled development authentication `404`, unauthenticated `/v1/me` `401`, and a durable authentication challenge `200`. Invalid Google and Apple identity tokens returned `401`; the Google sign-in path returned `identity_invalid` rather than `provider_unconfigured`.

An invalid Apple callback returned `400`; a valid challenge with an Apple cancellation returned `302` to the registered Android package with `Cache-Control: no-store` and `Referrer-Policy: no-referrer`. Apple token-endpoint preflights using an ES256 client secret and a deliberately invalid authorization code returned `400 invalid_grant` for both native and web audiences. These checks establish configuration and rejection/callback handling, not a successful provider login or code exchange.

## Native verification readiness

On the configured iOS simulator, Google sign-in opened the system permission prompt for `google.com`, then the `accounts.google.com` account chooser identifying Hisaab. Selecting the owner test account reached Google's consent screen for name, profile photo and email. Consent approval awaits the user; no completed Google login or backend session has been observed. Native Apple sign-in has not yet been tested.

- The configured debug build is installed and running on the iPhone 16 Pro simulator with iOS 18.6 for live sign-in validation. Compile-time `ENABLE_DEMO` is false; the backend uses production provider verification.
- Hisaab **1.0.0 (build 1)** is installed on the connected physical iPhone 17 running iOS 26.6.2. This is an ARM64 release-mode build with development signing, using the live AWS API and `ENABLE_DEMO=false`. `devicectl` confirmed installation, foreground launch and a running process after launch.
- The developer disk image mounted successfully after unlocking the iPhone. The prior mount failure was caused by the locked device, not an incompatible Xcode image.
- Deep signature verification passed. The signed app and embedded profile authorize the expected team, application identifier, Sign in with Apple entitlement and app-specific keychain group. Signing configuration is retained in ignored `ios/Flutter/Local.xcconfig`; no new signing certificate or private key was needed.
- No Android device or emulator was connected during inspection. Android release signing is not configured in the repository.
- The host initially had approximately **1.2 GiB free**. Removing only verified Hisaab build caches allowed compilation. Flutter's subsequent temporary-file sync exhausted disk space; removing this task's generated Xcode intermediates preserved the compiled app and allowed direct installation/launch, leaving approximately **1.8 GiB free**. A remote Android build must use a registered signing certificate before it can validate Google login.

## Acceptance still pending

No new or returning real Google/Apple account login has been observed against this environment on iOS or Android. Apple Android callback completion, Hide My Email, session refresh, provider linking, cancellation and account deletion/revocation also remain unverified. Complete and record the [live acceptance checklist](authentication.md#live-acceptance-checklist) with the tested build, platform, API environment and result. Keep authentication marked **live acceptance pending** until those results exist.
