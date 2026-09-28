> Historical design: AI bill scanning was removed on 28 September 2026. Manual receipt attachments remain. See [current receipt contract](../api/receipts-contract.md).

# ADR 0002: Snap & Split implementation defaults

Accepted for source implementation, 26 September 2026, following the user's instruction to implement the reviewed plan. External release gates remain open.

- Free allowance is 5 successful scans; a server-verified active/grace subscription allows 100. Both reset at the IST month boundary. Copy displays the cap rather than advertising unlimited scans. Ad-only support grants do not confer paid scan allowance.
- The provider adapter uses Mumbai Vertex only with a pinned model identifier, strict JSON schema, no tools and mandatory human review. `gemini-3.5-flash` is the evaluation candidate; source tests do not validate provider availability, residency, retention or accuracy. Enablement remains off until those checks pass.
- Any current group member can remove an image, reconciling conflicting spec criteria 29 and 37 in favor of the account-deletion privacy rule. Initial scanned expense confirmation requires the signed-in payer. Later ledger participants retain existing edit rights with explicit receipt review.
- Pushes default to generic text. Itemized amount/name content requires explicit notification-detail opt-in and fresh membership/preference checks at delivery.
- Canonical reviewed revisions use **1.5 MiB maximum over 24 × 64 KiB pages**. The planned 768 KiB limit did not cover 150 Unicode items each assigned to 50 UUID members; maximum-size tests established the larger bound. The whole expense/balance/revision transaction stays below DynamoDB's 100-action and 4 MiB limits. Raw provider extraction retains the smaller 768 KiB parser bound because it contains no member assignment matrix.
- V1 retains foreground encrypted drafts; background OS job resumption and per-unit item allocation remain deferred. A quantity line can be edited into individual rows. Foreign original amounts remain separate from manually converted INR values.
- Raw provider diagnostics are not retained pending the privacy decision identified in the plan. Support receives audited state/error metadata. Production correction and acquisition analytics remain unimplemented and are not represented as measured accuracy.
- Flutter 3.44.6 sets the effective Android minimum to 24; the pre-existing maxOf(23, flutter.minSdkVersion) configuration is preserved. Native HEIC requires Android 28+; the previously stated Android 23 baseline was not supplied by this toolchain, and complete HEIC support on older devices remains an explicit release gate. PDF import handles the first three pages locally. No claim of completed physical-device acceptance is made.
- Monthly spend uses conservative per-attempt liability, with required configured budget/cost bounds, an 80% alarm, free-tier pause and audited runtime emergency controls. Actual billed cost is a separate reconciliation task.

See [plan](../../SNAP_SPLIT_IMPLEMENTATION_PLAN.md), [receipt operations](../runbooks/receipts.md) and [status](../IMPLEMENTATION_STATUS.md) for evidence and remaining acceptance work.
