# External TestFlight beta

Release setup prepared on 27 September 2026.

- App Store Connect app: `6816609891`, **Hisaab: Shared Expenses**. The shorter name Hisaab was unavailable. The installed app remains Hisaab.
- Bundle: `app.hisaab.hisaab`; team: `733WGQVMLJ`.
- Version: `1.0.0`; build: `202609271147`.
- Signing: existing Apple Distribution certificate and **Hisaab App Store** provisioning profile. Private credentials and profiles remain outside Git.
- Backend: the existing AWS Mumbai beta environment in [live authentication status](live-auth-status.md).
- Demo, ads, push and purchases are disabled. Google sign-in remains limited to configured Google test accounts. The owner confirmed working Apple sign-in on the physical iPhone; Apple sign-in is the review path.
- Privacy notice: [Hisaab beta privacy notice](../privacy.md). The release configuration points to its public GitHub URL.
- External testing uses the **External Testers** invitation-only group. Public enrollment is disabled; invite only testers outside France.

## Encryption

Receipt drafts use standard AES-256-GCM from the Dart cryptography package, in addition to platform HTTPS and secure storage. Do not describe this as operating-system-only encryption.

The owner excluded France for this beta. Apple's App Store Connect questionnaire, answered with standard encryption and no France distribution, determined that no encryption documents were required. Reassess the declaration before changing countries or encryption. The source Info.plist intentionally leaves the encryption answer unset so future uploads receive an explicit assessment.

## Build

Use Flutter 3.44.6 and the committed dependency locks. Supply the public live client configuration through ignored `apps/mobile/config/production.json`, and signing plus the reversed Google client ID through ignored `apps/mobile/ios/Flutter/Local.xcconfig`. Keep `ENABLE_DEMO=false` and the disabled services above unchanged for this beta.

```sh
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build ipa --release \
  --build-name=1.0.0 --build-number=<unique-build-number> \
  --dart-define-from-file=config/production.json \
  --export-options-plist=<local-export-options.plist>
```

The export options use `app-store-connect`, manual signing, the existing distribution certificate, team `733WGQVMLJ` and the Hisaab App Store profile. Preserve the exported IPA and archive outside the task worktree before removing it. Verify the bundle/version, distribution signature, Sign in with Apple entitlement and bundled privacy manifest before upload.

Upload with Apple's authenticated upload tooling, wait for processing to become valid, provide build-specific testing notes, assign the external group and submit TestFlight App Review. Upload success is not review approval; external installs require Apple's beta approval.

## Verification

Flutter analysis passed. The existing mobile suite passed 71 tests, with four configuration-gated tests skipped. The live API returned health `200` and unauthenticated account `401`. The iOS icon dimensions and opacity, privacy-manifest syntax and Runner resource inclusion passed validation. An independent pre-PR review found no issues.
