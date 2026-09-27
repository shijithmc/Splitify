# Revised v1 implementation plan

Prepared 27 September 2026. **Proposed plan, not implemented changes.** Baseline: `70ffc8a`, including the merged Hisaab and Snap & Split source. The user requested a revised implementation plan and five screened names. This deliverable does not rename the app, change billing, provision services or authorize the next implementation phase.

Inputs: [unaltered review research](docs/research/splitwise-review-input-2026-09-27.md), [current implementation status](docs/IMPLEMENTATION_STATUS.md), [original plan](HISAAB_IMPLEMENTATION_PLAN.md), [receipt plan](SNAP_SPLIT_IMPLEMENTATION_PLAN.md), and the [five-name screening report](docs/research/name-screening-2026-09-27.md). The historical plans remain intact. If adopted, this revision supersedes their deferred status for multiple payers, simplify debts, CSV, default categories and the earlier possibility of interstitial ads.

## 1. Recommendation and boundaries

Build the expanded v1 on the existing Flutter/.NET/DynamoDB implementation. Preserve integer-paise accounting, private shared receipts, explicit review, identity proof and transactional writes. Deliver expense-level settlement, multiple payers and debt simplification as one accounting milestone before adding their UI independently.

The differentiation is item-level bill scanning, dependable balances and a clear UPI handoff. Free expense entry alone is insufficient: [The Hisaab](https://thehisaab.com/) already markets an India-focused alternative with UPI and offline use. Its claims establish a positioning and name collision, not verified product quality.

| Decision | Recommended planning default | Consequence / adoption gate |
|---|---|---|
| Core pricing | Add/edit/split/settle/search, comments, history, categories, recurrence and CSV remain free. No daily/paywall expense or group-count limits. | Publish a versioned free-at-launch feature list; enforce it in routes/API authorization and release review. AI quota is separately disclosed. |
| Technical limits | Remove the current 10,000 allocated-expense cap after pagination/load verification. Retain **50 ledger identities per group**, including former members, for this release. | **Explicit deviation from the research's unlimited-members promise.** The same technical limit applies to every plan. Do not publish “unlimited members.” Literal unlimited members requires a separate ledger/storage redesign and re-estimate before adoption. |
| Ads | Banners on eligible list screens only. No interstitial, rewarded, video or timer paths. | Research alternates between banner-plus-native and banners-only; choose the narrower existing implementation. Native feed ads are deferred, not required for v1 acceptance. |
| Yearly | Intended India price ₹299/year; ad-free plus 100 successful AI scans per IST month. | Use the store's localized price and verified product identity. Preserve the existing annual scan promise. |
| Lifetime | Intended India price ₹899 once; **lifetime ad removal**, with the standard 5 free AI scans/month. | Separate `ad_free` and subscription scan benefits before selling this. Do not advertise unlimited or lifetime premium AI. No new scan add-on is included in this plan. |
| Trials | No trial or forced offer at launch. | Check store offerings as well as client copy/configuration. Free flows never require a purchase screen. |
| UPI | Include in v1 with QR/copy fallback; payment records require explicit user confirmation. | Device/app proof is a release gate. A bank/payment-provider-verified status is outside scope. |
| Recurrence and member consolidation | Both remain v1 MUSTs. | If capacity fails, issue a revised scope proposal; do not silently move them to v1.1. |
| Name | Choose from the separately screened shortlist after live store and trademark checks. | No identifiers, artwork, domains or products are renamed or purchased in this planning task. |

“Free forever” means no later paywall on the published launch feature set; it does not promise unlimited AI inference, immunity from abuse controls, or unbounded device/storage resources. Rate limits protect service availability and must never become paid unlocks or artificial wait screens.

## 2. What the code already does

| Area | Baseline evidence | Remaining work |
|---|---|---|
| Ledger | [Expense](src/Hisaab.Domain/Expense.cs), [LedgerEngine](src/Hisaab.Domain/LedgerEngine.cs), [SettlementRules](src/Hisaab.Domain/SettlementRules.cs): single payer, four split modes, direct pair debt, partial payments, dispute reversal. | Contribution maps, immutable obligations, expense allocations, simplified transfers, payment correction semantics. |
| Identity | Name-only placeholders and scoped invitation claims already preserve participant history. Typed phone is not proof. | Private nicknames; safe group participant consolidation. No automatic account merge. |
| Retry handling | Durable server idempotency and unique payment IDs exist. | Mobile settlement saves generate new IDs on retry; persist the logical command so an ambiguous successful payment cannot be recorded twice. Add cross-party duplicate detection. |
| History | Financial change events exist; activity shows newest 100. Old description changes retain only a changed flag. | Full before/after revisions, per-expense pagination, comments, search, categories and export. Missing historic text cannot be reconstructed. |
| Mobile | Working demo, expense/payment flows, read-only offline cache; receipt drafts are encrypted and recoverable. | Ordinary expense drafts, calculator, duplicate action, UPI profile/handoff, recurrence screens. |
| Billing | Annual-only mobile offering; backend verifies RevenueCat. | Lifetime product parser and non-consumable lifecycle. Current receipt quota upgrades any verified `ad_free` account: that must change first. |
| Notifications/ads | Durable transactional outbox, preferences, generic receipt pushes, banner guards. | Exact event enum replaces permissive prefixes; contextual Android permission, comments and user-set reminders. Refund entry and free-feature register missing. |
| Receipt scanning | Camera/gallery/PDF, mandatory review, exact item assignments, private images, 5/100 allowance source implemented. | Preserve all receipt controls through ledger migration; real provider/device/evaluation gates remain outstanding. |

The baseline reports 243 passing .NET tests and 45 Flutter tests across configurations. These establish prior source checks, **not acceptance of the new scope or a production release**. See the status document for real cloud, AI, stores, push and physical-device prerequisites.

## 3. Accounting contract comes first

### Contributions, obligations and payments

Store a versioned map of payer contributions alongside expense shares. Require `sum(contributions) = amount = sum(shares)`, in integer INR paise. For each participant, the expense net is `contribution − share`. Deterministically match negative and positive nets in stable participant-ID order into per-expense debtor/creditor obligations; retain the algorithm version and original contribution evidence. A legacy payer becomes one contribution equal to the total.

Maintain separate records for actual cash transfers and the allocation/netting journal that explains which obligations were discharged. Actual transfer amounts count once, even when one transfer clears several linked obligations. Receipt/item review remains mandatory; the confirming actor must be an authorized contributing payer, and mismatch notices target relevant contributing payers.

Expense status is derived from its remaining obligations: **Unpaid**, **Partly settled**, **Paid**, or **Settled by offset**. Show a breakdown for mixed payment/offset cases. A zero group net does not imply that each expense was paid. “Settle this expense” must preview the cash amount, affected people, other obligations being offset, and resulting balances before confirmation. Recording permission belongs to a participating sender/receiver under the existing group rules; arbitrary viewers cannot assert someone else's payment.

Use an unqualified **Paid** badge only when direct cash fully discharges the expense's obligations. Routed payments use “Settled through simplified payment”; mixed cases show the cash/offset breakdown. Keep “Record an already-made payment” separate from a suggested net transfer: if A actually paid B ₹100 on X in the reciprocal example below, record ₹100 without the proposed offset. X becomes Paid and Y still leaves B owing A ₹80. Never replace observed cash with the suggested ₹20.

Simplify-debts suggestions are a versioned derived view; merely enabling or viewing them changes no ledger rows. On confirmation, commit the actual transfer, exact affected obligations, noncash offsets and notification event together. Reject stale group versions. Turning suggestions off does not undo previously confirmed settlements.

Required golden cases:

| Input / action | Required outcome |
|---|---|
| A owes B ₹100 on X; B owes A ₹80 on Y. Settle X using netting. | Preview ₹20 cash A→B plus ₹80 reciprocal offset, touching X and Y. Only explicit confirmation commits it. X displays ₹20 paid + ₹80 offset; Y ₹80 offset. Never record ₹100 cash when ₹20 moved. |
| A owes B ₹100; B owes C ₹100. A sends C ₹40 using simplification. | Reduce each linked obligation by ₹40; record only ₹40 cash. Remaining obligations are ₹60 each. Reversal restores exactly those effects once. |
| A→B→C→A cycle, ₹100 on each edge. | Net positions are zero, but obligations remain until an explicit reviewed offset action. Then mark offset, not paid; cash remains zero. |
| Total ₹1,000; A paid ₹700, B ₹300; shares A ₹400, B ₹250, C ₹350. | Nets A +₹300, B +₹50, C −₹350. Deterministic obligations C→A ₹300 and C→B ₹50. Partial/replayed payments preserve these totals. |
| A payment is allocated, then someone edits/deletes its expense. | Require an explicit previewed allocation correction with expected versions. Preserve actual cash, reverse affected allocations once, apply the revision and expose any credit/refund due. No silent reassignment or deletion of payment evidence. |

The conservation test is per participant: open receivables minus open payables, including refund credits and signed unapplied-payment clearing balances, equals expense contribution-minus-share totals plus actual cash sent minus cash received. Noncash offsets preserve each participant's net, and the group's nets sum to zero. Allocation amounts cannot exceed the relevant obligation or the transfer's permitted routing; a chain may allocate the same cash along multiple edges, but must not create cash or a second balance adjustment. Persist enough route evidence to replay and reverse exactly. Deleting X after A paid B ₹100 must preserve that cash and produce a reviewed B→A ₹100 refund credit.

Metadata-only edits can preserve allocations. Financial edits, delete/restore and member consolidation must use a reviewed correction command when allocations are affected; block a plain write until that preview is accepted. Reject a reversal while dependent allocations remain unless the same atomic correction reverses/reallocates them. Legacy payments stay visibly **unallocated to expenses**; do not invent historical Paid chips. Offer a separately reviewed attribution action if needed.

Represent those legacy payments with explicit unapplied-payment clearing credits/liabilities, distinct from refund credits. For legacy X=A→B ₹100 plus recorded A→B cash ₹100, X remains unattributed but the clearing entries make net payable zero. Show “payment recorded; expense attribution pending”; never suggest another ₹100. Reviewed attribution consumes the clearing entries and discharges X without posting new cash. Reconciliation and every settlement preview include unapplied balances, including partially allocated payments.

### Payment retry and possible duplicates

Create and persist the payment UUID, idempotency key, canonical payload and selected expense/route before network submission. Disable concurrent submission; retries after timeout, restart or UPI return reuse that command until its outcome is known. Payload edits create a new command only after resolving the old one.

Before a new transfer, compare normalized parties, amount, method, time window and optional external reference against recent non-reversed records from either party. Return a possible-duplicate response with the existing payment, followed by an explicit “different payment” confirmation path. Fence that check with the group version so simultaneous submissions cannot bypass it. Do not permanently deduplicate legitimate repeated rent payments solely by amount; bank references are user input, not verified evidence.

### Participant consolidation

“Merge duplicate member” means **group participant consolidation**, not account or subscription transfer. Creator can merge two unclaimed placeholders, or consolidate an unclaimed placeholder into a member whose claim was proved/confirmed. Two distinct authenticated accounts require a separate identity-recovery design and remain unsupported.

Preview balances and affected records; require current group version. Keep an immutable alias/tombstone and audit event, prevent alias cycles, reject stale commands and cancel self-debt created by consolidation. Preserve original expense, receipt and payment evidence. Resolve aliases consistently in shares, payer contributions, allocations, receipt assignments, recurrence, history, search and reconciliation. Never copy credentials, VPA ownership or purchase rights. A removed member gains no access from matching a name or typed phone number.

## 4. Entry, history and scheduled expenses

| Workstream | Contract and acceptance detail |
|---|---|
| Calculator | Parse bounded `+ − × ÷` expressions with normal precedence; do not use executable evaluation. Use exact decimal/rational intermediates, round the final amount half-up to paise, and validate the result server-side. Define unary minus for intermediate values; reject nonpositive final totals, division by zero, overflow and incomplete expressions. Shared Dart/C# vectors cover `120+85.5+40 = 245.50` and `1/3+1/3+1/3 = 1.00`. |
| Ordinary drafts | Encrypted per-account local drafts with group, expression, contribution/share inputs and stable save command. Restore after process death; clear only after confirmed success or explicit discard. Revalidate membership/current versions before save. Offline drafting is allowed; automatic financial write sync remains v1.1. Exclude draft data from backup/logs. |
| Duplicate | One tap opens an editable new draft dated today. Revalidate active participants, category and contributions. Do not copy payment links, comments, old history or private receipt image access automatically. Saving remains explicit; use a new entity ID. |
| Categories | Stable default IDs plus Uncategorized; backfill legacy rows without fabricating an old category. Custom categories remain v2. |
| Comments/history | Bounded plain-text comments, participant ACL, idempotent submission, rate limits and event-based notification. Immutable paged revisions record actor/time and exact before/after fields, including description, category, contributions and allocations. Label unavailable legacy values honestly. Retention/account deletion applies to comment content and actor identity; never log raw text. |
| Search | Free complete-history search across authorized groups by normalized description, exact/ranged amount, participant, category and date. Paginated DynamoDB queries with indexed metadata and bounded group fan-out; no global table Scan or prohibited search service. Continue through empty filtered pages with a next cursor. Show partial/loading state until exhausted; never filter only the newest 100 records and call it full history. Check current ACLs before returning candidates. |
| CSV | Free authenticated export using a versioned snapshot policy and bounded asynchronous job for large histories. Include amounts/currency/dates/contributions/shares and payment allocation context. Quote Unicode/newlines correctly and neutralize spreadsheet-formula text. Private expiring downloads require current membership; omit VPA/contact data. Cancel/delete artifacts when access is revoked. |
| Recurrence | Weekly, fortnightly, monthly, yearly templates; INR and explicit group timezone, default Asia/Kolkata. Stable occurrence slots use template plus anchored due date and snapshot the schedule version. Preserve logical-period uniqueness across versions; version alone cannot create a second occurrence. Expense, occurrence marker, ledger writes and outbox commit exactly once. Skip/edit races use expected versions; “this occurrence” versus “future” changes are explicit. |

Recurrence uses an anchored calendar date: a 31st-day monthly bill clamps to the month's last day and returns to the 31st later; a Feb 29 yearly bill clamps in non-leap years. Define execution time and daylight-saving behavior for any enabled timezone. Bound catch-up after outages and expose missed occurrences for review. Archived groups and missing/removed payers pause the template with an actionable state; never silently charge a new member. Do not reuse an old receipt as evidence of a new recurring bill.

Future edits use a nonoverlapping effective cutover and retain generated/skipped occurrence slots. An old schedule-version job fails its template-version condition; replaying it beside the new job cannot generate the same billing period twice. Frequency/date changes cannot recreate a materialized period; changing that expense requires an explicit expense correction.

Search/export/reconciliation must work beyond 10,000 historical expenses before removing that cap. Measure read cost, first-page latency, cancellation and complete traversal on 10,001 and 100,000-record fixtures; substring search may require multiple group-scoped pages, so do not promise constant-time global search. A faster derived index is a measured follow-up if these queries miss the agreed budget.

## 5. UPI, privacy, billing and notifications

**UPI:** owner-editable VPA lives separately from broadly returned profile data. Fetch it only for an authorized current group/friend relationship; verify that relationship on every request. A syntactically valid VPA is not verified ownership. Show recipient identity, VPA, amount and note before handoff, keeping private nicknames secondary. Prefill these fields through a constrained URI; test note/recipient escaping and support QR/copy when launch fails or no supported app exists. Never collect a UPI PIN or hold funds.

On return, ask Yes/No/Unsure. Only Yes submits the persisted record command; app resumption, callback success strings and QR display never prove payment. Label it “recorded by you,” not bank-verified. Test GPay, PhonePe, Paytm and BHIM on supported Android/iOS combinations; Android's intent chooser has no guaranteed identical iOS behavior. [Google Pay's documented integration](https://developers.google.com/pay/india/api/android/in-app-payments) is merchant guidance and requires payment verification; it does not establish universal support for this app's person-to-person handoff. Unverified combinations ship with the QR/copy path until device testing passes.

If the group/expense changed while the user paid externally, preserve the reported cash and original command, resolve any ambiguous submission, then offer allocation review against the new state. Keep unapplied clearing entries when authorized cash recording succeeds but expense attribution cannot. Local pending confirmation must remain visible until the server confirms it. Never reopen UPI or suggest paying again solely because an expected version is stale.

**Nicknames/invites:** private owner-scoped nicknames cannot modify another person's public name, notification text or shared audit actor. Keep verified-email/scoped-link claims; sharing an invitation addressed to a phone number remains supported. Automatic phone lookup/contact matching requires a separate consent and ownership-proof design; it is not delivered by typing a phone number. Contact-book discovery is outside this v1 plan.

For creator-initiated linking, let the creator select the exact unclaimed placeholder and issue a scoped invitation. The authenticated claimant proves/accepts the claim; its original participant ID and history survive. The creator cannot unilaterally attach a stranger's account.

**Billing:** model product ID, purchase kind, store, sandbox flag, lifecycle/revocation and benefit set. Parse RevenueCat non-subscription transactions explicitly; a missing expiry alone is insufficient proof of a valid lifetime purchase. One canonical authenticated account owns cross-platform benefits. Restore must not silently move another account's purchase. Test annual+lifetime coexistence: annual expiry leaves lifetime ad removal but returns scanning to 5/month; refund/revocation removes only the affected benefit. Support grants retain their explicit scope/expiry and must not accidentally grant scans. [RevenueCat's non-subscription guidance](https://www.revenuecat.com/docs/platform-resources/non-subscriptions) documents product and refund-notification requirements; verify pinned native SDK support during implementation.

Allow an annual subscriber to buy lifetime deliberately after showing that it **does not cancel annual renewal**; link to the originating store's manage screen. Annual continues to provide 100 scans until expiry. Lifetime owners may choose annual for that scan allowance with truthful benefit-specific copy; hide redundant lifetime purchases. Do not imply a prorated credit or automatic conversion. Replace the current blanket purchase-disable rule for any ad-free account with product-specific eligibility and test this matrix.

Settings → Premium → Manage/cancel and Settings → Premium → Request refund must each **open the correct store flow within two in-app taps**. External sign-in, store decisions and completing cancellation/refund are outside that tap promise. Show the originating purchase store and handle lifetime/no-subscription states without a dead manage link. [Apple refund help](https://support.apple.com/en-au/118223) and [Google Play's refund flow](https://support.google.com/googleplay/workflow/9813244?hl=en) remain store-controlled. Remove annual-only suffixes and inaccurate interstitial copy from the lifetime/free screens.

**Push:** replace prefix matching with a closed event enum and reject unknown types server-side. Include expense add/edit/delete/restore, payment recorded/disputed/corrected, comment added, invitation, explicitly user-set reminder, receipt ready and receipt mismatch. Decide whether receipt-image removal needs notification; it is not admitted implicitly by a prefix. No promotional events. Scope recipients after commit, recheck ACL/preferences at delivery, deduplicate by event ID on the client, and preserve generic receipt text unless detail consent exists. A recurring expense uses the normal expense event. Ask Android 13+ permission after the first successful group action with a rationale; denial leaves core use working and Settings offers the next route without repeated prompts. Other platform permission timing receives equivalent device checks.

## 6. Storage, migration and rollout

After selecting a cleared name, inventory visible branding separately from identifiers: Flutter title, Android label, iOS display name, legal/help copy, stores and artwork versus `app.hisaab.hisaab`, `hisaab` deep links, native channels, storage keys and OAuth/Firebase/RevenueCat associations. Decide identifiers before first public release; preserve or explicitly migrate any existing installations, sign-in callbacks, invitations, data and purchases. Do not globally replace strings or treat a display-name change as a purchase migration. Name clearance blocks public branding/store submission, not feature work under the internal project name.

Keep the existing modular API/domain/worker and local/DynamoDB adapters. Add feature models and documented access patterns first; this plan does not pretend to be the requested future single-table design. Candidate records are expense revision/obligation, payment/allocation journal, member alias, comment, recurrence/occurrence, private nickname/VPA, search metadata and export job. Each needs ownership, retention, pagination and an atomic-write budget.

1. Deploy compatible readers and additive schema versions before new writes. Map old payer/category fields in memory, preserve IDs and historical data. Older clients must preserve new fields or receive an explicit upgrade/review response before editing a multi-payer or allocated expense.
2. Implement a pure replay model and migration dry-run. Reconcile per-person nets, original cash totals, active obligations and allocations against the old ledger. Keep existing unallocated payments as cash evidence; do not assign them to old expenses automatically.
3. Budget maximum transactions before enabling writes. Existing receipts may use 24 revision pages plus 50 balance writes within the current 100-action/4 MiB transaction ceiling. History/search/allocation additions cannot be appended without headroom analysis. Pre-stage immutable paged allocation evidence, then atomically publish a version/hash-checked commit marker with the bounded balance update if necessary; readers ignore uncommitted pages and cleanup expires them. No unbounded allocation fan-out in one transaction.
4. Backfill bounded pages with checkpoints and group-version fencing. Rebuild derived indexes from authoritative revisions; detect races and resume rather than overwrite concurrent writes. Reconciliation reports mismatches and stops rollout instead of silently repairing money.
5. Enable by internal cohort, then small production cohort after external gates. Gate multi-payer/settlement writes together; independently control recurrence, UPI, lifetime and ads. Monitor migration failures, conflicts, duplicate warnings, cost and receipt behavior.
6. Rollback disables new writers/jobs while retaining readers and audit evidence. Do not revert to code unable to read the new ledger or delete recorded payments. Rehearse restore/replay, interrupted backfill, queued jobs and account deletion before widening rollout.

No SnapStart, OpenSearch/Elasticsearch/AOSS/SearchCache or AWS WAF. No infrastructure is deployed by this planning change.

## 7. Delivery sequence and estimate

Planning envelope: **13–15 calendar weeks** with two backend/platform engineers, two mobile engineers, one QA engineer and part-time product/design, provided store/provider access is ready. This is an initial capacity assumption, not a date commitment or a measured “25% increase.” One or two total engineers require re-estimation. M0 can change the range, especially if literal unlimited members or unrestricted phone discovery is required.

| Milestone | Indicative window / owner | Deliverable and exit gate |
|---|---|---|
| M0: contracts and proof | Weeks 1–2; tech/product leads + mobile | Adopt limits/benefits/settlement semantics; choose cleared name; prove UPI fallback matrix; map store products; size max receipt+allocation transaction. No schema work proceeds with unresolved money semantics. |
| M1: ledger foundation | Weeks 3–5; backend pair | Multi-payer obligations, allocation/netting/reversal model, stable mobile commands and compatibility readers. Golden cases, concurrency, conservation and migration dry-run pass. |
| M2: settlement and entry | Weeks 5–7; mobile pair + backend | Targeted/partial/simplified settlement, duplicate warning, calculator, encrypted drafts, duplication and categories. Process-kill and two-device journeys pass. |
| M3: history and collaboration | Weeks 6–9; backend/mobile split | Immutable history, comments, nickname/profile ACL, search and CSV. Complete traversal past the old cap and negative authorization tests pass. |
| M4: automation and payments | Weeks 8–11; backend/mobile split | Recurrence/skip, participant consolidation, UPI handoff, lifetime verification, manage/refund, exact push enum and permission flow. Replay/device/store matrix passes. |
| M5: release candidate | Weeks 12–15; QA + whole team | Backfill rehearsal, load/chaos/security/accessibility, receipt regression, name/config migration, internal beta and production gates with measured evidence. |

The overlap depends on separate owners. Contract/API mocks let entry, settings and design progress while accounting is proved. External store review, trademark clearance and credentials have no guaranteed duration and are not hidden inside the estimate. The v1 exit includes recurrence and consolidation; a schedule-driven cut needs a new explicit plan.

## 8. Acceptance traceability

`R01–R21` refer to the numbered new ACs in the supplied research; they avoid collisions with the original AC numbers. All are v1 MUST unless marked below.

| Requirement | Milestone | Verification |
|---|---|---|
| R01 expense/share settlement | M1–M2 | Partial, reciprocal, chain, cycle, reversal and edit-after-payment fixtures; correct badges and notification. |
| R02 calculator | M2 | Shared arithmetic vectors, invalid/overflow inputs, live preview equals saved paise. |
| R03 name-only member/claim | Existing + M4 creator UI | Creator selects exact placeholder and initiates proof-bearing link; claimant accepts without changing participant ID/history; no name/phone-based takeover. |
| R04 nickname | M3 | Other users, shared history and exports cannot observe the private override. |
| R05 UPI | M0 proof + M4 | Installed/missing apps, cancel/unsure/success, kill/resume and repeated callbacks; only confirmed record once. |
| R06 VPA privacy | M3–M4 | Owner write; current related-user read; unrelated/former/revoked access denied. |
| R07 duplicate | M2 | Opens today's draft; new ID; no copied settlement or private media access. |
| R08 draft recovery | M2 | Hard kill at multiple form/save states, account switch, stale membership and ambiguous save response. |
| R09 comments | M3 | Participant ACL, replay/rate bounds and correct opted-in recipients. |
| R10 edit history | M3 | Every changed field and actor visible across pages; unavailable legacy fields labeled. |
| R11 recurrence | M4 | Weekly/fortnightly/month-end/leap-year, timezone, skipped run, old/new schedule job race without duplicate period and removed payer. |
| R12 full search | M3 | Matching old records beyond first 100/10,000, combined filters, empty continuation pages and revoked group. |
| R13 categories | M2–M3 | Default selection/filter/export plus legacy Uncategorized. |
| R14 consolidation | M4 | Preview, alias cycles, same-person proof, unchanged group nets, self-debt cancellation and receipt replay. |
| R15 lifetime | M4 | Both stores: buy/restore/refund/revoke, sandbox separation, wrong account, cross-platform login and annual coexistence. |
| R16 manage/refund | M4 | Two in-app taps to correct external store flow; no subscription/lifetime handling. |
| R17 no trial | M4 | Product-offering assertion, paywall navigation and free-flow tests. |
| R18 push allow-list | M4 | Every permitted event plus rejection of unknown/promotional types; existing receipt/dispute events retained explicitly. |
| R19 permission | M4 | Android 13+ fresh install, first action, denial, OS Settings and token recovery on physical devices. |
| R20 duplicate payment | M1–M2 | Double tap, timeout, restart and simultaneous opposite-party entry; deliberate distinct repeat remains possible. |
| R21 read-only share link | **v1.1 SHOULD** | Future revocable/expiring access, no write route, redacted profiles/receipts and token enumeration resistance. |
| Original AC16 multiple payers | M1–M2 | Contributions and shares independently sum to total; unequal contribution vectors and receipt regression. |
| Original AC22 simplify debts | M1–M2 | Derived preview changes no ledger; confirmed route preserves cash/nets and reverses exactly. |
| Original AC25 ad restriction | M4 | No interruptive ad SDK path/config; protected screens and premium/consent lifecycle tests. |
| Original AC40 CSV | M3 | Snapshot consistency, large Unicode exports, formula escaping and download ACL. |
| P1–P3 free core and published permanence | M0 + M5 | Feature registry and free-account E2E; remove expense cap; disclose equal technical group cap; no later paid route substitution. |
| P4–P5 push/store access | M4 | R16/R18/R19 plus offline help/error routes. |

Existing MUSTs still apply: sign-in/account deletion, direct friends, split modes, disputes, private media, mandatory scan review, scan quotas, current-member authorization and no silent paid entitlement grant. Verify these while changing the ledger; the new table is additive, not a replacement for original acceptance.

## 9. Release evidence and later phases

Use focused domain/property tests for money; API tests for command races and authorization; real DynamoDB integration for write limits, stream retries and migration; Flutter tests for recovery/state; physical-device journeys for UPI, billing, permissions and capture. The source-only planning PR requires document/link/scope review, not rerunning app tests as evidence for unbuilt features.

Before release, measure crash-free sessions ≥99.8% over a defined beta window and at least 10,000 sessions. Define push success as device-acknowledged receipt within a stated window among opted-in reachable devices with valid tokens; target ≥97% and report provider acceptance separately. OS-limited background cases and unknown acknowledgments need separate counts, not silent exclusion. Keep foreground online convergence p95 ≤2 seconds and existing API/receipt latency targets; polling frequency is not a measurement. If sample size is insufficient, mark the target unproven.

Track ratings ≥4.6 at 1,000 ratings and the percentage of 1-star reviews mentioning limits/ads/pay as post-launch outcomes, with a documented coding method and denominator. ASO search installs are leading evidence only when attribution is available. Never log raw comments, VPA, receipts or contact data for analytics. Preserve the outstanding 200+ permissioned receipt corpus, real Mumbai provider, signed stores/push, accessibility, camera/HEIC and AWS operational gates from the status document.

| Phase | Scope |
|---|---|
| v1.1 | Offline add/edit command queue with explicit conflict handling; per-expense currency and separate currency balances (no conversion/netting across currencies); revocable read-only group link. These each need a follow-up design and estimate. |
| v2 | Expense-date conversion, personal ledger, custom categories, basic free category/month charts, tablet/iPad layout, per-item percentage/share modes and collaborative item claiming. |
| v3+ | Separately priced advanced insights, UPI screenshot/invoice import and a web application. |

## 10. Research confidence

The supplied review summary is useful qualitative input, not a representative ranked survey. Its approximately 50 “most relevant” reviews were not independently recoded here; helpful votes and forum votes do not establish complaint prevalence.

Primary checks on 27 September 2026:

- [Splitwise's own help page](https://feedback.splitwise.com/knowledgebase/articles/2010350) confirms a free daily expense limit and Pro removal, but does not establish a universal current 3–5 count or wait duration.
- The retrieved [Google Play listing](https://play.google.com/store/apps/details?hl=en_IN&id=com.Splitwise.SplitwiseMobile) showed 4.0 stars and 16 September update, differing from the supplied snapshot. `hl=en_IN` alone does not establish an India-only rating. Its feature list supports the parity audit: multiple payers, comments/history, recurrence, categories, CSV and debt simplification are listed outside its Pro section.
- The [India App Store listing](https://apps.apple.com/in/app/splitwise/id458023433) showed 4.4 and 13K ratings, with several in-app purchase prices but unlabeled durations. Do not treat ₹999/year as the sole verified current offer.
- The [official feedback forum](https://feedback.splitwise.com/forums/162446-general/filters/top) supports demand for individual settlement, calculator entry and name-only members. Vote counts are time-sensitive and are not delivery commitments.

Marketing must use this app's tested behavior and disclosed limits, not an unverified claim that every competitor user sees a particular price, delay or restriction. Name-screening findings and their separate store/registry limitations are recorded in the linked report.
