# Implementation status

Updated 26 September 2026. Source implementation follows the accepted defaults in ADR 0001. The original plan remains a historical design/acceptance document; it is not a claim that external release gates passed.

## Delivered source

| Area | Implemented behavior | Evidence / limit |
|---|---|---|
| Identity | Google/Apple token validation, Apple Android callback, fresh challenges, explicit credential linking, account-scoped sessions and rotating refresh credentials | API security tests; native adapters compile. Real provider acceptance needs registered OAuth/app/service IDs. |
| Groups/invites | Home/Trip/Couple/Other and hidden Direct groups; placeholders; encrypted optional contact data; seven-day scoped links; explicit link/verified-email claims; archive, leave and creator deletion rules | Group/API tests. Typed phone is an address, never proof of ownership; recipients claim through the shared link. Contact-email discovery requires fresh authoritative provider proof. |
| Ledger | Four split modes, deterministic integer-paise rounding, exact-gap errors, single payer, optimistic revisions, atomic expense/balance/event writes, 30-day restore and once-only dispute reversal | Domain property tests and HTTP journey tests, including concurrent writers and request replay. |
| Mobile | Onboarding/demo, groups/friends, expense/settlement flows, settings/linking/deletion, secure per-account cache, offline write lock, foreground refresh | Analyzer/widget/repository tests, Android debug build and iOS simulator build/launch. Production signing/device acceptance remains. |
| Billing/ads | Account RevenueCat identity, annual localized offering, purchase/restore, bounded account-scoped provisional ad suppression, authenticated webhooks plus server fetch, renewal/grace/expiry/refund handling, support overrides | Mocked provider tests and policy tests. Live store products, purchase timing and cross-store restoration remain release gates. Banners default off; no interstitial path is present. |
| Notifications/jobs | Generic FCM messages after committed events, per-type preferences, session-bound devices, durable work and retry, nightly ledger reconciliation, resumable deletion | Worker tests. Delivery is at least once; provider acceptance plus a crash before recording completion can duplicate a push. Real APNs/FCM delivery is unverified. |
| Infrastructure | .NET 10 ARM64 API/worker assets, on-demand/PITR DynamoDB, filtered streams, SQS/DLQs, scheduled jobs, least-privilege table permissions, HTTP throttling, bounded logs and alarms | CDK policy tests; no deployment. Production IAM/stream behavior and alarm delivery require an AWS environment. |

Backend writes include account/session conditions and a durable response keyed by an idempotency UUID. Expired idempotency responses are eligible for deletion after 30 days; caller-generated expense/payment IDs still prevent duplicate entities. The 50-member cap counts retained ledger identities. Balances preserve direct debts, including zero-net cycles. Home totals aggregate across authorized groups.

## Original Hisaab verification recorded

- Complete .NET Release suite: **168 passed** (63 domain, 75 API/security/workers, 23 storage/infrastructure, 7 support).
- Real localhost HTTP smoke: health, development authentication, group/placeholders, equal ₹100 split, identical request replay, balance conservation and resolved actor/field-change history passed.
- Actual framework-dependent Linux ARM64 API/worker publishing and CDK synthesis passed; worker runtime manifest and prohibited infrastructure checks passed.
- Mobile tests: **29 passed** across 25 default-suite cases and four explicitly ads-enabled lifecycle cases (those four intentionally skip when ads are disabled). Flutter analyzer is clean. Android debug packaging is verified in the implementation PR.
- iOS simulator native build, launch and visual inspection passed before the final Dart-only identity/ads fixes. A final iOS rebuild was not repeated because the host had less than 2 GB free; latest Dart changes are covered by analysis/tests and Android compilation. Final signed iOS acceptance remains a release gate.

## Deliberate changes from the plan

- Foreground one-second active-group polling and two-second home polling replace the proposed WebSocket invalidation service. Polling stops behind protected flows and in the background. The ≤2-second convergence target still needs two-device measurement under realistic load; a polling interval alone is not an SLO result.
- Durable DynamoDB work rows with filtered stream wakeups and scheduled repair replace an EventBridge domain-event bus. EventBridge rules schedule maintenance. No redundant GSI is added where strongly consistent base-table queries serve the access pattern.
- Mobile uses a small `ChangeNotifier` controller and explicit typed models/API repository rather than Riverpod and a generated OpenAPI client. The versioned HTTP contract is documented in `docs/api/implementation-contract.md`.
- Ad enablement is compile-time configuration; remote ad/purchase kill switches are a pre-launch follow-up. Banners are the only ad format implemented. Interstitials cannot fire; enabling them later requires the frequency/reservation tests from the original plan.
- Existing separately created Hisaab accounts are **not consolidated**. Linking an unowned provider after proving both credentials works; an already-owned provider returns `account_merge_required`. Support must not manually rewrite ledger ownership or transfer a subscription without a separately reviewed recovery design.
- Activity exposes the latest 100 events; cursor-based historical activity browsing, product analytics pipelines and public legal/help page hosting remain follow-up work. Expense listing is cursor-paginated at 25 records.
- Optional multiple payers, simplify-debts, CSV export, categories/notes, offline writes and all other v2/v3 features remain outside this build.

## Snap & Split delivered source

- Native camera preview with bundled edge estimate, crop/retake, up to three images, local PDF/HEIC rasterization, orientation/metadata removal and ≤2048 px JPEG normalization. Encrypted per-account draft manifests/images support foreground upload and recovery after restart.
- Mandatory editable review, original-script names, confidence warnings, manual INR conversion, total or item splits, deterministic exact-paise charge allocation and server preview. Immutable paged revisions attach atomically with expenses/balances. Existing manual expense APIs remain compatible and cannot silently rewrite receipt allocations.
- Private shared image tickets bound to session/account, fresh ACL checks on every chunk, image removal, mismatch flags, duplicate warning, opt-in detailed notifications and receipt push routing.
- Regional Vertex adapter, strict schema/parser, keyless WIF, queue/worker leases, bounded retries and successful-scan reservations. Five free /100 subscriber scans per IST month; independent upload quotas and configured budget/circuit/runtime stops.
- S3/CDK source, delayed purge tombstones, account deletion/anonymization, audited support commands and a protected external-corpus evaluation tool. No raw provider output or production receipt corpus is retained for analytics.

Mobile verification: **45 tests passed across configurations** (41 default-suite tests, plus four ads-enabled lifecycle tests); Flutter analyzer is clean. Two receipt widget journeys exercise explicit review/save, protected ad routes and invalidated review acknowledgement.

Verification: **243 .NET tests passed** (81 domain, 123 API, 23 infrastructure, 16 support/evaluation). Real in-process HTTP upload → validation → preview → save → shared thumbnail and copied-ticket rejection passed. Linux ARM64 API/worker publishing and CDK synthesis passed. Android debug packaging and iOS arm64 simulator compilation passed; visual simulator interaction was unavailable because the host was locked. The maximum Unicode 150-item × 50-member assignment transaction and shared arithmetic vectors pass.

Capture limits: edge detection is a bounded rectangular estimate with explicit crop/full-image review, not validated perspective correction. Native picker/camera inputs briefly use app-private temporary files, cleaned in finally; abrupt process death can leave those inputs until OS/plugin cleanup. Durable draft files remain encrypted and excluded from backup.

**Still gated:** live Mumbai Vertex/WIF/token renewal, 200+ permissioned real-bill evaluation, production IAM/load/latency, billing reconciliation, physical-device camera/crop/HEIC/PDF/accessibility and signed push/store journeys. Scanning remains off by default. Flutter 3.44.6 already sets the effective Android minSdk to 24 (the existing maxOf expression is preserved). The original Android 23 support claim therefore needs a separately validated toolchain. Native HEIC works only on Android 28+ or iOS; older Android HEIC acceptance remains unresolved. Raw support diagnostics and production correction/conversion analytics are not implemented. Per-unit allocation and background OS upload jobs remain deferred as recorded in ADR 0002.

See [receipt contract](api/receipts-contract.md), [operations](runbooks/receipts.md), [accepted implementation defaults](decisions/0002-snap-split.md) and [evaluation harness](../tools/Hisaab.ReceiptEval/README.md). No cloud deployment or real AI benchmark ran in this implementation.

## Release gates

1. Supply the AWS account/profile/region, environment/domain strategy and budget. Configure a high-entropy encryption key/contact HMAC key and provider secrets through an existing Secrets Manager secret. Deploy only through a reviewed environment process; SnapStart, OpenSearch and WAF remain prohibited.
2. Register final iOS/Android identifiers, signing credentials and Google/Apple OAuth audiences. Verify Apple private relay, Android callback/state and both-credential linking on physical devices. Configure universal/app-link associations on the invite host.
3. Configure RevenueCat `ad_free`, annual products at the intended India price, explicit restore/transfer policy, store notifications, test users and merchant accounts. Verify purchase, interrupted verification, reinstall, wrong-account restore, refund/revoke, billing grace and cross-store entitlement. SDK responses alone never grant server premium.
4. Configure Firebase/APNs and AdMob. Test push permissions, muted types, token refresh, logout, consent, no-fill and ad disposal. Ads remain disabled until age/audience/consent policy is reviewed; current requests are non-personalized with conservative age treatment and no app-supplied PII.
5. Publish reviewed Terms, Privacy and account-deletion/help pages; set support/grievance contacts and retention policy. Verify legal URLs on the paywall and independent store-subscription cancellation guidance during deletion.
6. Exercise real DynamoDB transactions/permissions/streams, DLQ recovery, interrupted account deletion, backup restore and support grants. Connect alarms to an operations destination. Establish provider retry/rate budgets and AWS cost alerts.
7. Load test 50 retained members, 10,000 expenses and many-group home aggregation. Measure API latency, HTTP error ratio, hot-group contention, foreground freshness and reconciliation. Current local tests do not validate production performance targets.
8. Complete physical-device accessibility, signed internal distribution and the store acceptance matrix from the original plan. Record measured evidence before declaring all MUST criteria or production launch complete.

The debug demo is reviewable without those accounts. It is visibly isolated, cannot purchase or issue live invites, and must be disabled for store release.

## Illustrated Flutter interface — 27 September 2026

Applied the approved illustrated visual system to existing mobile flows. Added bundled café/receipt illustrations and Outfit/Work Sans fonts, shared Material 3 theme tokens, illustrated group tiles, clearer expense/payment hierarchy, live account scan allowance and store-priced annual plan cards. Home routes scanning and payment recording through a group chooser. Sign-in remains provider-backed with a separate local-demo entry.

This is presentation and navigation work on the supported implementation. The expanded-v1 gallery is not a shipped-feature inventory; the proposed accounting, recurrence, UPI handoff, lifetime billing and other additions remain in the revised plan. No backend or infrastructure was changed.

New widget coverage checks narrow displays, large text, payer/split controls, live store prices and quota, camera/crop controls, sign-in Back handling, and Home receipt/payment navigation. Local verification: Flutter analyzer clean; 53 default-suite tests passed, plus 4 ads-enabled lifecycle tests; final iOS simulator debug build passed. Welcome, Home and group-specific receipt navigation were inspected in the iPhone 16 Pro simulator. The PR CI also checks the Android debug build and unchanged backend suite. Real camera capture, identity providers, store transactions and cloud deployment retain their existing environment-specific release gates.

## Authentication readiness — 27 September 2026

Apple Android code exchange now includes the registered callback URL for the configured Services ID; native iOS code exchange omits it. Google and Apple ID-token audiences require exact matches. New offline tests exercise the production verifier using signed JWTs and discovery/JWKS responses, alongside the Apple exchange and session tests. These checks do not use live provider accounts.

Flutter sign-in handles cancellation without displaying provider diagnostics, prevents overlapping requests, initializes the Google SDK once, and protects reauthentication/linking against account changes. Provider registration, signing, API deployment and real-account acceptance remain pending; use the [authentication runbook](runbooks/authentication.md) for the matching client/server configuration and acceptance checklist.
