# Hisaab

Shared expenses for friends, flatmates and trips. Flutter for iOS/Android, a transactional .NET 10 backend, DynamoDB/CDK infrastructure, and account-wide ad removal through RevenueCat.

## Try the app

```sh
cd apps/mobile
flutter pub get
flutter run
```

Choose **Explore the local demo**. The visible DEMO badge identifies an isolated, persistent playground: create groups, add/edit expenses, preview four split modes, inspect balances, record payments and dispute them. Demo mode needs no cloud credentials; it cannot make purchases or send live invitations.

Toolchain: Flutter 3.44.6 / Dart 3.12.2, .NET SDK 10.0.3xx, Java 17 / Android SDK 36, Xcode + CocoaPods for iOS. Android 23+ and iOS 15+ are supported build targets. The repository directory remains `Splitify`; the product is Hisaab.

## Run the backend

```sh
./scripts/run-api.sh
```

Development API: `http://localhost:5080`. It persists to the ignored `.local/` directory. Development login is explicitly enabled by this script; hosted environments require real provider tokens and DynamoDB configuration.

```sh
curl -s http://localhost:5080/health
curl -s http://localhost:5080/v1/auth/dev \
  -H 'Content-Type: application/json' \
  -d '{"displayName":"Aarav"}'
```

Use the returned access token as `Authorization: Bearer …`. Ledger mutations require a UUID `Idempotency-Key`. See the [API contract](docs/api/implementation-contract.md). The mobile app's real login uses Apple/Google; it never silently switches to developer authentication.

## What is implemented

- Apple/Google token verification, rotating sessions, explicit credential linking and resumable account deletion.
- Groups/direct friends, scoped invitations and placeholder history claims; archive/leave rules and retained-member limits.
- Integer-paise equal/exact/percentage/shares splits, visible rounding, version conflicts, atomic ledger updates, delete/restore and payment disputes.
- Foreground refresh, account-scoped read-only offline cache, activity and independently configurable push notifications.
- RevenueCat server verification, durable webhook work, account entitlement history, purchase/restore recovery and audited temporary support grants.
- Consent-gated banners; ads default off. Production price comes from the store offering; ₹299/year is the intended India product configuration.
- ARM64 Lambda/CDK source, durable outbox processing, scheduled reconciliation/deletion/entitlement checks, DLQs, alarms and CI.

This is a runnable source implementation, not a deployed or store-approved release. Read the [implementation status and release gates](docs/IMPLEMENTATION_STATUS.md) for tested behavior, remaining scope and external prerequisites. No AWS resources, live ads or store products were created.

## Verify

```sh
dotnet build Hisaab.slnx
dotnet test Hisaab.slnx
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug --dart-define=ENABLE_DEMO=true
flutter build ios --simulator --no-codesign
```

Backend tests cover ledger conservation, concurrent/replayed mutations, authorization, identity/invite proof, billing, deletion, push workers and synthesized infrastructure. Mobile tests cover arithmetic, repository behavior, demo workflows, protected ad routes and narrow-screen layouts. Mocks and simulator builds do not establish real store, push or AWS acceptance.

## Configuration and operations

- [Mobile setup](apps/mobile/README.md): native identifiers, sign-in, Firebase, store products, legal URLs, ads and invite associations.
- [Infrastructure setup](infra/Hisaab.Cdk/README.md): publish assets, synthesize templates and configure an existing Secrets Manager secret.
- [Configuration keys](.env.example): empty example only; never commit populated secrets.
- [Support runbook](docs/runbooks/support.md): account/transaction lookup and audited, expiring grants.
- [Accepted defaults](docs/decisions/0001-v1-defaults.md), [original plan](HISAAB_IMPLEMENTATION_PLAN.md), [unaltered product specification](docs/hisaab-product-spec.md).

No SnapStart, OpenSearch/Elasticsearch/AOSS/SearchCache or AWS WAF is allowed. No money moves through Hisaab; settlements are records only.
