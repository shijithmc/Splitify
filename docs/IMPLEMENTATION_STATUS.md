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

## Verification recorded

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
