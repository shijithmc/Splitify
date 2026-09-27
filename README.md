# Hisaab

Shared expenses for friends, flatmates and trips. Flutter for iOS/Android, a transactional .NET 10 backend, DynamoDB/CDK infrastructure, and account-wide ad removal through RevenueCat.

## Try the app

```sh
cd apps/mobile
flutter pub get
flutter run
```

Choose **Explore the local demo**. The visible DEMO badge identifies an isolated, persistent playground: create groups, add/edit expenses, preview four split modes, inspect balances, record payments and dispute them. Demo mode needs no cloud credentials; it cannot make purchases or send live invitations. For Snap & Split, open a group → **Scan bill** → **Try the sample itemised bill** to review, assign and save a synthetic receipt.

Toolchain: Flutter 3.44.6 / Dart 3.12.2, .NET SDK 10.0.3xx, Java 17 / Android SDK 36, Xcode + CocoaPods for iOS. Flutter 3.44.6 sets the effective Android minimum to 24; iOS remains 15+. HEIC currently requires Android 28+ or iOS; resolving older Android HEIC support remains a release gate. The repository directory remains `Splitify`; the product is Hisaab.

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
- Snap & Split capture, encrypted drafts, mandatory receipt review, exact item assignments, shared private receipts and scan allowances. AI uses a strictly validated Mumbai Vertex adapter and stays disabled until provider configuration and acceptance are complete.

This is a runnable source implementation, not a deployed or store-approved release. Read the [implementation status and release gates](docs/IMPLEMENTATION_STATUS.md) for tested behavior, remaining scope and external prerequisites. No AWS resources, live ads or store products were created.

The [revised v1 plan](V1_REVISION_IMPLEMENTATION_PLAN.md) proposes the expanded free feature set, expense-level settlements, UPI handoff and lifetime ad removal. It includes a [five-name screening report](docs/research/name-screening-2026-09-27.md). These are planning deliverables; the expanded features, prices and replacement name have not been adopted or implemented.

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
- [Receipt API](docs/api/receipts-contract.md), [receipt operations](docs/runbooks/receipts.md), [protected evaluation harness](tools/Hisaab.ReceiptEval/README.md), [implementation plan](SNAP_SPLIT_IMPLEMENTATION_PLAN.md) and [unaltered feature specification](docs/snap-split-product-spec.md).

No SnapStart, OpenSearch/Elasticsearch/AOSS/SearchCache or AWS WAF is allowed. No money moves through Hisaab; settlements are records only.
