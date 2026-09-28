# Feature Name
**Hisaab: Shared Expense Splitting with Ad-Free Premium**

---

# Elevator Pitch
Friends, flatmates and travel groups log shared costs, see who owes whom, and settle up. Everyone can use it free with ads, and ₹299 removes the ads on every device.

---

# Problem Statement
Indian users split rent, trips, groceries and dinners every week. Today they track it in WhatsApp threads, spreadsheets or memory, and that leads to disputes, forgotten debts and awkward reminders. Splitwise limits its free tier (daily expense caps, paywalled features), which leaves room for an India-priced app that is generous on the free tier and pays for itself with ads plus a cheap ad-removal subscription. If we don't build it, the opportunity goes to whoever ships the cleanest ₹-first experience.

---

# User Stories

> **As a** flatmate, **I want** to add a shared expense and split it equally, by exact amount, by percentage or by shares **so that** everyone's share is correct without doing the maths by hand.

> **As a** group member, **I want** one net balance per person in each group and across all my groups **so that** I know exactly who to pay and how much.

> **As a** debtor, **I want** to record that I paid someone **so that** my balance clears and the other person is notified.

> **As a** trip organiser, **I want** to create a group and invite people by link or phone/email, including people who haven't signed up yet **so that** I can log expenses before they install the app.

> **As a** new user, **I want** to sign in using Apple, Google or a phone number with an SMS code **so that** I don't have to create or remember a password.

> **As a** free user, **I want** ads that never block me from adding an expense or settling up **so that** the free app stays usable.

> **As a** paying user, **I want** ₹299 to remove ads on both my iPhone and Android devices under one account **so that** I don't pay twice.

> **As a** subscriber who changed phones, **I want** to restore my purchase **so that** ads stay off without paying again.

> **As a** user leaving the app, **I want** to delete my account and data **so that** my privacy is respected, while my friends' records stay correct.

> **As a** support/ops agent, **I want** to see a user's subscription state and entitlement history **so that** I can resolve "I paid but still see ads" tickets in under 5 minutes.

> **As a** product owner, **I want** ad revenue, conversion and churn metrics **so that** I can tune ad frequency against conversion.

---

# Stakeholder Map

| Stakeholder | Interest / Impact | Input Needed Before Build |
|---|---|---|
| End user (free) | Speed, accuracy, ads that don't intrude | Ad placement rules sign-off |
| End user (paid) | Ad-free everywhere, easy restore | Price point + billing period confirmed |
| Product owner | Retention, conversion to paid, ad ARPU | Free-tier limits (none vs capped), ad frequency caps |
| Engineering lead | DDD bounded contexts, DynamoDB access patterns, Lambda cost | Access-pattern catalogue sign-off; direct store APIs vs RevenueCat decision |
| Mobile lead | Client stack (Flutter / native / MAUI), StoreKit 2 + Play Billing, AdMob | Client framework decision |
| Ops / support | Entitlement lookup, refund handling, abuse | Admin tooling scope |
| Security / compliance | India DPDP Act 2023, Apple/Google account-deletion rules, token handling | Privacy policy, data retention policy, DPO contact |
| Finance | Net revenue after store fee + GST, ad payout | Apple/Google merchant accounts, tax forms, bank linkage |
| Apple / Google (platform) | Review compliance (Sign in with Apple parity, restore button, deletion) | Developer accounts, subscription products configured |

---

# Acceptance Criteria

**Auth**
1. [ ] [MUST] User can sign in with Apple on iOS, Google on both iOS and Android, or a phone number verified by SMS OTP. Phone codes expire, retries are bounded, and sign-in, linking and deletion reauthentication require server verification.
2. [ ] [MUST] The same email signing in with Apple and with Google is not silently merged; the user is offered an explicit account link after re-authenticating.
3. [ ] [MUST] Apple "Hide My Email" relay addresses work end-to-end (sign in, notifications, account lookup).
4. [ ] [MUST] A session survives an app restart, and sign-out clears all local data.
5. [ ] [SHOULD] Sign in with Apple is available on Android via the web flow.

**Groups & Friends**
6. [ ] [MUST] User can create, rename and archive a group. Group types: Home, Trip, Couple, Other.
7. [ ] [MUST] User can invite by share link, phone or email. Invitees who haven't signed up appear as placeholder members and can be assigned expenses.
8. [ ] [MUST] An invitee explicitly claims placeholder history through a scoped invitation link or a freshly verified provider email. A typed phone number or phone sign-in alone does not claim placeholder history.
9. [ ] [MUST] Expenses can be logged 1:1 with a friend outside any group.
10. [ ] [MUST] A group can't have more than 50 members. Adding a 51st shows a clear error.

**Expenses**
11. [ ] [MUST] User can add an expense with description, amount, date, payer(s), and split mode: equal, exact, percentage or shares.
12. [ ] [MUST] Shares always sum exactly to the total. Rounding remainders (paise) go to participants in a fixed, visible order, and the split preview shows the result before saving.
13. [ ] [MUST] Save is blocked when exact amounts don't add up to the total or percentages don't add up to 100, and the message names the gap (e.g. "₹12.50 left to assign").
14. [ ] [MUST] Any participant can edit or delete an expense. Deleted expenses can be restored for 30 days, and every change is recorded in the activity log showing who changed what.
15. [ ] [MUST] If two users edit the same expense at once, the second save is rejected with "This expense changed — review latest", and nothing is silently overwritten.
16. [ ] [SHOULD] Multiple payers on one expense.
17. [ ] [COULD] Category and notes on each expense.

**Balances & Settle Up**
18. [ ] [MUST] Group view shows each member's net balance. Home view shows a total owed/owing and a per-friend breakdown.
19. [ ] [MUST] Balances update within 2 seconds of an expense save for everyone in the group, including after pull-to-refresh.
20. [ ] [MUST] "Settle up" records a payment (cash/UPI/other, label only). The receiver is notified and can dispute it.
21. [ ] [MUST] A member with a non-zero balance can't leave a group without a warning. Archiving a group keeps its history.
22. [ ] [SHOULD] A "Simplify debts" toggle per group reduces the number of payments needed.

**Ads (free tier)**
23. [ ] [MUST] Free users see banner ads on list screens only (home, group list, activity).
24. [ ] [MUST] No ads appear on the add-expense, edit-expense, settle-up, sign-in or subscription screens.
25. [ ] [MUST] Interstitials are capped at 1 every 5 minutes and 4 per day, and never show mid-flow.
26. [ ] [MUST] If an ad fails to load, the layout shows no empty placeholder gap and no errors.
27. [ ] [MUST] Ad requests carry no user PII (no email, phone or name).

**Subscription (₹299 ad-free)**
28. [ ] [MUST] A "Remove ads — ₹299/year" screen shows the local store price, renewal terms, Restore Purchases, Terms and Privacy links.
29. [ ] [MUST] Ads disappear within 5 seconds of a successful purchase, without restarting the app.
30. [ ] [MUST] Entitlement is tied to the Hisaab account, not the device or store. A purchase on iOS removes ads on Android after the same account signs in.
31. [ ] [MUST] Restore Purchases works after reinstall and on a new device.
32. [ ] [MUST] Server-verified store events drive entitlement changes (renew, cancel, expire, refund, billing grace period, revoke). A client-only receipt is never trusted.
33. [ ] [MUST] During the store billing grace period the user stays ad-free. After expiry, ads return on the next app launch.
34. [ ] [MUST] Refunded or revoked purchases remove the entitlement within 1 hour of the store notification.
35. [ ] [SHOULD] If a purchase is on a different store account than the signed-in user, a clear message explains the mismatch.
36. [ ] [SHOULD] Subscription status and next renewal date are visible in Settings.

**Account & Privacy**
37. [ ] [MUST] In-app account deletion is reachable within 3 taps from Settings (Apple 5.1.1(v)).
38. [ ] [MUST] Deletion revokes the Apple token, removes PII, and shows the user as "Deleted user" in other people's shared expenses, keeping their balances correct.
39. [ ] [MUST] Deletion warns about any active store subscription and links to store management, since the store bills independently.
40. [ ] [SHOULD] User can export all their data as CSV.

**Notifications**
41. [ ] [MUST] Push notifications fire when someone adds an expense involving you, when you're recorded as paid or paying, and when you're invited. Each type can be muted.

---

# User Journey Map

**Happy Path: first trip expense, then going ad-free**
1. Install the app, then onboarding shows 3 cards: split / track / settle.
2. Tap "Continue with Google" (or Apple) and complete the native sheet, or choose phone sign-in and verify the SMS code. The existing native sign-in target is under 3 seconds; SMS delivery latency is measured separately.
3. Empty home state: "No expenses yet — create a group or add a friend."
4. Create group "Goa Trip", pick type Trip, share the invite link to WhatsApp.
5. Three friends join via the link. Rahul hasn't installed the app, so he's added by phone as a placeholder.
6. Tap "+ Add expense": "Villa ₹24,000", paid by you, split equally among 4. Preview shows ₹6,000 each. Save.
7. Group screen: "You are owed ₹18,000". Friends get a push notification. A banner ad shows at the bottom of the group list.
8. Next day an interstitial would fire, but you're in add-expense, so it's suppressed.
9. You open Settings, then "Remove ads ₹299/year". The App Store sheet appears, you confirm, and ads vanish within 5 seconds.
10. Later you sign in on an Android tablet with the same account and it's ad-free right away.
11. Priya taps "Settle up" and records ₹6,000 via UPI. You're notified and your balance drops to ₹12,000.

**Key Error Path: paid but still seeing ads**
1. Purchase succeeds in the store, but the network drops before the backend confirms.
2. The app hides ads locally (provisional entitlement), keeps retrying server verification with backoff, and the store server notification also reaches the backend on its own.
3. If the server hasn't confirmed within 24 hours, the app re-asks the store on the next launch. The user can also tap Restore Purchases.
4. If it still fails, Settings shows "Purchase pending verification — Contact support" with a pre-filled transaction ID. Support looks up the entitlement history and grants it manually.

---

# Edge Cases & Boundary Conditions

| Condition | Expected Behaviour | v1? |
|---|---|---|
| Empty / zero-state | Home, group and activity screens each show an illustrated empty state with one primary action | In |
| First-time vs returning | First-timer gets onboarding and a sample-group coach mark. Returning user goes straight to home with a cached snapshot | In |
| Max volume | 50 members per group. 10,000 expenses per group, paginated at 25 per page. Max amount ₹1,00,00,000 per expense. Description 100 characters | In |
| Concurrent edit | Version check: second writer rejected and shown latest. Concurrent adds both succeed and balances stay consistent | In |
| Permission boundary | Only group members can view or edit. Non-member API calls get 404, not 403, so we don't reveal the group exists. Only the creator can delete the group | In |
| Offline / slow network | v1: read-only cached view plus "You're offline" banner, and saving is disabled. v2: offline expense queue with sync | Partial |
| Accessibility | Screen reader labels on every amount ("owes you six thousand rupees"), 44pt touch targets, dynamic type, colour isn't the only owe/owed signal | In |
| Mobile / small screen | 320pt-wide layouts are supported, and the split editor scrolls with a sticky total | In |
| Partial failure mid-flow | Expense save and balance update happen in one transaction, so either both succeed or neither does. Client uses an idempotency key so retries don't double-post | In |
| Rounding | Integer paise only. Remainder goes to the first N participants in sorted order, and the preview shows it | In |
| Placeholder never joins | Their balances still count and can be settled by others. After 90 days the organiser is prompted to "Mark as external" | In |
| Same email, Apple + Google | Not auto-merged. User is offered a link after re-authenticating | In |
| Apple private relay email | Stored as-is and used for lookup. Phone/email invites can't match it, so link invites are the fallback | In |
| User deletes account with open balances | Warned first. After deletion, others see "Deleted user" and can still record settlements | In |
| Subscription on store account A, app account B | Entitlement goes to the app account that initiated the purchase (via the app account token). Mismatch message shown | In |
| Family Sharing / Play family library | Disabled for this product | In (off) |
| Refund after 6 months | Entitlement revoked when the store notification arrives | In |
| Price change / regional pricing | Store-managed. App shows the store's localised price, never a hard-coded ₹299 | In |
| Multi-currency trip | Out of v1: single INR per group | Out (v2) |
| Minor (under 18) user | Ads switch to non-personalised (child-directed flags) if age is unknown — see Open Q | Partial |

---

# Out of Scope (This Iteration)

- We will NOT move money in-app (UPI collect/pay, wallets). Settle-up is record-only. *Future: UPI intent deep link, prefilled with amount and payee VPA (v2).*
- We will NOT support multiple currencies or FX conversion. *Future: per-group currency plus conversion at expense date.*
- We will NOT scan receipts with OCR or store receipt photos. *Future: S3 photo attachment (v2), OCR (v3).*
- We will NOT add recurring expenses. *Future: v2 scheduler.*
- We will NOT build a web app. *Future: v3.*
- We will NOT offer premium features beyond ad removal (charts, export insights, themes). *Future: Pro tier bundle reassessed after conversion data.*
- We will NOT support email/password login. Phone-OTP login is included alongside Apple and Google; configured SMS delivery and live-device acceptance remain release prerequisites.
- We will NOT support offline writes. The sync conflict model adds significant complexity.
- We will NOT build a full admin console. Support gets a minimal entitlement lookup/grant tool only.
- We will NOT use AWS WAF, per the account-wide ban. Abuse control is API Gateway throttling plus app-level rate limits.

---

# Dependencies & Prerequisites

| Type | Dependency | Status | Owner |
|---|---|---|---|
| Feature | Identity: Apple + Google ID-token validation, account creation, account linking | Not started | Backend |
| Feature | Push notifications (FCM + APNs via SNS or direct) | Not started | Backend/Mobile |
| Data | Access-pattern catalogue signed off before table design (groups by user, expenses by group by date, balances by group, balances by user-pair, activity by user, entitlement by user, store-transaction lookup) | Not started | Eng lead |
| Infrastructure | AWS: API Gateway (HTTP API), Lambda (.NET, ARM64, no SnapStart), DynamoDB single table + GSIs, EventBridge for domain events, SQS DLQs, Secrets Manager, CloudWatch | Not started | DevOps |
| Infrastructure | IaC: CDK (C#) or SAM. Dev / staging / prod environments | Not started | DevOps |
| Infrastructure | Architecture: DDD bounded contexts (Identity, Groups, Ledger/Expenses, Settlement, Billing/Entitlement, Notifications, Ads-config), feature-folder layout, one type per file | Not started | Eng lead |
| Legal / Compliance | India DPDP Act 2023 privacy notice + consent, data-retention policy, grievance officer | Not started | Legal |
| Legal / Compliance | App Store guidelines 4.8 (Sign in with Apple parity), 3.1.1 (IAP for digital goods), 3.1.2 (subscription disclosure), 5.1.1(v) (deletion) | Not started | Product |
| Legal / Compliance | Google Play Payments policy, Data Safety form, account-deletion URL | Not started | Product |
| Third Party | Apple Developer Program: Sign in with Apple service ID + key, auto-renewable subscription product, App Store Server Notifications V2 endpoint, App Store Server API key | Not started | Mobile |
| Third Party | Google Play Console: subscription product, Real-time Developer Notifications (Pub/Sub → HTTPS push to API), Play Developer API service account | Not started | Mobile |
| Third Party | Google Cloud OAuth client IDs (iOS, Android, web) | Not started | Mobile |
| Third Party | AdMob account, ad units, UMP consent SDK | Not started | Mobile |
| Third Party | Optional: RevenueCat, to abstract both stores (see Open Q2) | Decision pending | Eng lead |

---

# Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Balance drift: expense and balance writes diverge, so users see wrong totals and lose trust | Med | High | Transactional write of expense plus affected pairwise balances; 50-member cap keeps each transaction under the DynamoDB 100-item limit; nightly reconciliation job recomputes from the ledger and alerts on mismatch |
| Entitlement wrong: paid user sees ads, or refunded user doesn't | Med | High | Server is the source of truth; store server notifications plus a periodic re-verify; idempotent event handling keyed by store transaction ID; support grant tool; alarm on notification DLQ depth |
| Cross-store identity: purchase tied to the wrong account | Med | Med | Pass an app account token (iOS `appAccountToken`, Play `obfuscatedAccountId`) on every purchase and map entitlement to it |
| Ads hurt retention before users convert | Med | High | Banner-only launch, tight interstitial caps, A/B test frequency; tracked guardrail: D7 retention must not drop >5% vs the no-ad control |
| App Store rejection (Sign in with Apple parity, restore button, deletion, subscription disclosure) | Med | Med | Pre-submission checklist mapped to ACs 1, 28, 31, 37 |
| Low net revenue: ₹299 minus 15–30% store fee minus 18% GST ≈ ₹215 net at the 15% tier | High | Med | Enrol in Apple Small Business Program and Play's 15% tier; ads carry the free tier; revisit price after 90 days |
| Abuse: invite spam, fake groups, scraping unauthenticated endpoints | Med | Med | API Gateway throttling plus per-user app-level rate limits on invite/create endpoints; the only unauthenticated routes are store webhooks, which are signature-verified (Apple JWS, Google Pub/Sub OIDC token) |
| Lambda cold starts hurt perceived speed | Med | Low | ARM64, ReadyToRun/trimmed publish, memory right-sizing, lazy init. No SnapStart |
| DPDP non-compliance fine | Low | High | Consent at signup, deletion flow, data export, minimal PII in logs |

---

# Open Questions

1. **Is ₹299 a yearly subscription, monthly, or a one-time lifetime purchase?** It changes the product type, renewal handling and revenue model. **Default: ₹299/year auto-renewable.** ₹299/month overprices the Indian market; lifetime is simpler but gives up recurring revenue.
2. **Integrate Apple/Google billing directly, or through RevenueCat?** Direct means no vendor fee but about 2–3 extra weeks building receipt/notification handling for both stores. RevenueCat is faster and you already run it in Coursellm. **Default: RevenueCat, with its webhook feeding a Lambda Billing context that owns the entitlement.**
3. **Mobile client framework: Flutter, .NET MAUI or native?** This drives SDK choice for auth, billing and ads. **Default: Flutter, which matches your other projects.**
4. **Does the free tier have limits beyond ads (e.g. expenses per day)?** This is the conversion lever versus Splitwise's approach. **Default: no functional limits; ads only. Generous free tier is the positioning.**
5. **Target market: India only or global?** It affects currency, the GDPR/UMP consent flow and pricing tiers. **Default: India launch, INR only, UMP consent shown only to EEA/UK users.**
6. **Should Android offer Sign in with Apple?** It helps users who switch from iPhone to Android. **Default: yes in v1.1 via the web flow; Google-only on Android at launch.**
7. **Do we collect phone numbers (for invite matching)?** It raises PII and DPDP scope. **Default: optional phone number, never required, used only for invite matching.**
8. **Ad personalisation: personalised or non-personalised by default?** It trades ad revenue against privacy and minors risk. **Default: personalised only with consent; non-personalised otherwise.**
9. **Data retention for deleted groups/accounts?** It sets the DPDP obligation. **Default: PII purged within 30 days; anonymised ledger kept while other members still reference it.**
10. **Should there be a free trial for ad-free?** It affects conversion. **Default: no trial in v1.**

---

# Success Metrics

| Type | Metric | Definition | Target | Measurement |
|---|---|---|---|---|
| Leading | Activation rate | % of new signups who add ≥1 expense within 24h | ≥ 40% | Analytics event funnel |
| Leading | Group virality | Average invites accepted per created group | ≥ 1.5 | Invite→join events |
| Leading | Paywall view→purchase | % of paywall views that end in a purchase | ≥ 3% | Store + analytics |
| Lagging | D30 retention | % of users active on day 30 | ≥ 25% | Cohort analysis |
| Lagging | Paid conversion | % of MAU with active ad-free entitlement | ≥ 2% by month 3 | Entitlement table / MAU |
| Lagging | Renewal rate | % of yearly subs that renew | ≥ 60% | Store notifications |
| Lagging | Blended ARPU | (ad revenue + net sub revenue) / MAU / month | ≥ ₹4 | AdMob + store reports |
| Lagging | Support tickets on entitlement | Tickets tagged "paid but ads" per 1,000 subs per month | < 2 | Support tool |
| Health | API error rate | 5xx / total requests | < 0.5% | CloudWatch |
| Health | p95 latency | Add-expense API p95 | < 400 ms warm, < 1.5 s cold | CloudWatch / X-Ray |
| Health | Balance reconciliation mismatches | Groups where stored balance ≠ recomputed ledger | 0 | Nightly job + alarm |
| Health | Store webhook DLQ depth | Unprocessed billing events | 0 sustained > 15 min | SQS alarm |

---

# Assumptions Made

- Assumed ₹299 is a **yearly auto-renewable** subscription. If it's monthly or lifetime, the product config, renewal logic and revenue model all change.
- Assumed the **only paid benefit is ad removal**. If Pro features are planned, the entitlement model needs feature flags, not a single boolean.
- Assumed **India-first, INR-only**. If the launch is global, multi-currency and GDPR consent move into v1.
- Assumed **settle-up only records payments; no money moves through the app**. If in-app UPI is wanted, RBI/payment-aggregator compliance lands in scope.
- Assumed **the Flutter client** is used. If native or MAUI, the SDK integration effort changes.
- Assumed **the backend is C# .NET on Lambda (ARM64), API Gateway HTTP API and DynamoDB single-table, following DDD with bounded contexts**, as specified. If a relational ledger is later preferred, the reporting design changes.
- Assumed a **50-member group cap**. If larger groups (e.g. office groups of 200) are needed, the balance model must switch from transactional pairwise updates to async projection.
- Assumed **entitlement is per account and cross-platform**. If per-store only, users who switch platforms pay twice and support load rises.
- Assumed **AdMob** as the ad network. With another network, the consent and mediation setup changes.
- Phone-OTP login was added to the accepted scope on **28 September 2026**. SMS provider setup, attempt budgets and live acceptance are tracked in the [authentication runbook](runbooks/authentication.md).

---

# Recommended Phasing

| Phase | Scope | Value Delivered | Estimated Effort |
|---|---|---|---|
| v1 — MVP | Apple/Google/phone-OTP sign-in, account linking + deletion; groups + 1:1 friends; invites (link/phone/email, placeholders); expenses with 4 split modes; balances; record settle-up; activity feed; push; AdMob banners + capped interstitials; ₹299/yr ad-free cross-platform entitlement with restore; nightly reconciliation; support entitlement tool | Core Splitwise-equivalent loop, monetised from day 1 | XL (~10–12 weeks, 2 backend + 2 mobile) |
| v2 | Simplify debts; multi-currency; receipt photos; recurring expenses; offline add queue; UPI intent deep link; CSV export; search; Sign in with Apple on Android | Parity-plus vs Splitwise Pro, stronger retention | L |
| v3+ | Receipt OCR; spending charts/insights; web app; Pro tier bundle; itemised bill splitting | New paid value beyond ad removal, higher ARPU | L–XL |

---

**Next steps:** "dynamodb do it" for the single-table design from these access patterns, or "EA do it" to start building the backend. Answer Open Questions 1–3 first; they change the billing and client design. I can also publish this spec as a shareable page.
