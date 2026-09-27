Pulled Play Store page + App Store + feedback forum. Now reading more Play reviews.

# Splitwise Review Research: What to Fix and What to Build in Our App

## Verdict
The biggest complaint by far is Splitwise's free tier: a cap of 3–5 expenses per day, a 10-second ad or wait screen before each add, and a ₹999/year subscription with no one-time option. Our planned model (no limits on core features, ads only, ₹299) answers it directly, so keep it and tighten three things:
- **Drop interstitial ads.** Reviewers hate ads that interrupt adding an expense.
- **Add a lifetime purchase option.** Reviewers repeatedly ask for a one-time payment instead of a subscription.
- **Move 7 Splitwise free features into our v1.** Without them we launch behind what Splitwise gives away free.

**Two things need action now:**
1. **Rename the app.** "The Hisaab" already exists (thehisaab.com). It is an India-built, free, ad-free Splitwise alternative with UPI and offline support, so the name collides with a direct competitor.
2. **Differentiate on more than "no limits".** That competitor is already free with no ads, so "no limits" alone won't win. Our edge has to be AI bill scanning with item-level splits, reliability, and UPI settle-up.

**What I looked at:** the Google Play India listing (4.3★, 1.95 lakh reviews, 1 crore+ downloads, updated 17 Sept 2026) and about 50 of its "most relevant" reviews read in full; App Store India (4.4★, 13K ratings) and US (4.0★, 28K ratings) review pages; the top-voted ideas on Splitwise's feedback forum; and a few third-party write-ups. Those write-ups are mostly competitor marketing, so I only used them where a primary source agreed.

---

## A. Negative reviews, ranked by volume, and how we fix each

| # | Complaint | Evidence | Our fix | Where |
|---|---|---|---|---|
| C1 | **Daily cap of 3–5 expenses on the free tier.** Kills trip use, which averages about 10 entries a day | The most common theme in Play reviews, Oct 2023 to Sep 2026. Top reviews have 485, 472, 311, 293, 286, 266 and 231 helpful votes. Splitwise's own reply (Jan 2024) confirms "four new expenses per day". App Store reviews say the same | **No limit on adding expenses, groups, members, unequal splits or search, ever.** Put it in store listing copy: "Unlimited expenses. Free forever." | Parent spec; add as a product principle |
| C2 | **10-second unskippable ad or wait before each expense** | Many reviews (Varun Trivedi, 311 votes; Simarpreet, 485; Shardul Mandloi) | **No interstitials, wait timers or video ads anywhere.** Banner on list screens plus one native ad in the activity feed. Never in add/edit/settle/scan flows | Change AC 25 |
| C3 | **Subscription too expensive (₹999/yr, "more than Netflix"). Users want one-time or lifetime** | Simarpreet (485), Abhishek Samal (472), Arthak (122), plus a 2019 review | Keep **₹299/year** and add **Lifetime ₹899** as a one-time purchase | New AC; Open Q1 |
| C4 | **Occasional/trip users won't subscribe; "each of us needs to pay"** | Deepak Gokhale, Puneet Gupta, Renisha Shrestha; an App Store user asks for per-trip pricing | Core is free, so the problem mostly goes away. A subscriber's scans attach to the group, so the whole group benefits | Covered by C1 |
| C5 | **Dark patterns: forced "try Pro" to use free parts, trial auto-charged, refunds hard** | Gilberto Torrezan Filho, Noppakit TH, Amol Thakkur (Aug 2026) | **No free trial in v1.** A paywall never blocks a free feature. Settings has "Manage / cancel subscription" (deep link to the store) and "Request refund" (store refund flow), each within 2 taps | New ACs |
| C6 | **Promotional push notifications disguised as reminders** | Brodyjohn Stancliff (Aug 2026): a push saying he was "almost" done turned out to be an upsell | **Push is transactional only** (expense added, payment recorded, invite, reminder the user set). No marketing push. Enforced in code, not by policy | New AC |
| C7 | **Features taken away over time (bill photo upload, charts, currency, search moved to Pro)** | Nitin Garg (83), Aryan V, a third-party article | **Free-forever list published in-app.** Anything free at launch never moves behind the paywall | Product principle |
| C8 | **Can't settle a single expense; only the total balance** | Jemima Samuel (68 votes). #1 on the feedback forum (985 votes, "under review" for years) | **"Settle this expense"** marks one expense paid by a person and shows a "Paid" chip on it. The balance adjusts. Partial settle-ups can target specific expenses | New v1 AC |
| C9 | **Reliability: balances not syncing, login loop, Android 13+ notifications failing, crash on launch** | Third-party troubleshooting article. A double settle-up bug created negative debts | Transactional ledger + nightly reconciliation (already spec'd). Idempotent settle-ups (a duplicate record is caught). Android 13+ notification permission asked in context. Crash-free target ≥99.8% | New ACs + health metric |
| C10 | **Payment-wallet issues (withdraw limits, pending money)** | Kelsey Prentice, an App Store US review (Splitwise Pay) | **We never hold money.** Settle-up is record-only plus a UPI hand-off (see F7) | Out of scope, confirmed |
| C11 | **Duplicate accounts when invitees join** | App Store (mondalreshmi, Apr 2024) | Placeholder claim by matched phone/email/link (already spec'd). Add a **"Merge duplicate member"** action for the group creator | New AC |
| C12 | **Can't itemise from existing gallery photos; scanning is Pro-only** | App Store reviews; Johnny Martinez (Aug 2026) says it doesn't scan receipts but asks for money | Gallery + PDF scanning already in Snap & Split. **5 free scans/month** | Already covered |

## B. Most-requested features

| # | Request | Evidence | Decision | Phase |
|---|---|---|---|---|
| F1 | Settle individual expenses | Forum #1, 985 votes | **Build** (see C8) | **v1** |
| F2 | Calculator in the amount field (`120+85.5+40`) | Forum #2, 955 votes; App Store (Nov 2022) | **Build.** Amount field accepts + − × ÷ and shows the result live | **v1** |
| F3 | Personal expense tracking | Forum #4, 835 votes | Build a "Personal" non-shared ledger that counts in the spending chart | v2 |
| F4 | Custom categories | Forum #5, 669 votes | Default categories + custom ones, free | **v1** (default set), v2 (custom) |
| F5 | Add friends without email/phone | Forum #7, 625 votes; App Store US | **Build.** Name-only placeholder members | **v1** |
| F6 | Edit a friend's display name (nickname) | Forum #9, 463 votes | **Build.** Private nickname only you see | **v1** |
| F7 | **UPI payment** | Forum #10, 458 votes (India); third-party sources say Splitwise has no GPay/UPI (Play listing shows only Paytm) | **Build a UPI hand-off:** "Pay ₹840 via UPI" opens the UPI app picker with payee VPA + amount + note. The user confirms and a settle-up is recorded. Fallback: show a UPI QR + copy VPA. **We never collect or hold money** | **v1** (moved from v2) |
| F8 | Duplicate / copy a past expense | Play (N P, Jun 2024) | **Build.** "Duplicate" action on any expense | **v1** |
| F9 | Save drafts mid-entry | App Store US | **Build.** Auto-saves the unsaved expense on the device and restores on reopen | **v1** |
| F10 | View balances without installing (share link) | Offered by competitor The Hisaab | **Build.** Read-only group link. Link holders see balances; nothing can be edited without sign-in. Expires or can be revoked | v1.1 |
| F11 | Multi-currency, free | Pro-only in Splitwise; App Store says entering other currencies is painful | Free per-expense currency + conversion at expense date | v2 (keep); promote to v1.1 if the golden-cohort data shows international trips |
| F12 | Search full history, free | Pro-only in Splitwise; Aryan V | Free search on description/amount/member/date | **v1** |
| F13 | Charts with percentages, category spend | App Store (Ess197) | Free basic chart (category %, month). Advanced insights are a later Pro feature | v2 |
| F14 | iPad split-screen / tablet layout | App Store US | Adaptive layout + iPad multitasking | v2 |
| F15 | Search people by phone number | App Store (mondalreshmi) | Invite by phone (already spec'd). Contact-book matching needs opt-in consent | v1 |
| F16 | Offline entry | Splitwise supports it (Play listing); the competitor markets offline-first | Offline add/edit queue with sync | **v1.1** (moved up from v2) |
| F17 | Custom percentage splits within an itemised bill | App Store US | Per-item split mode (equal / shares / %) inside "Split by items" | v2 |

## C. Splitwise free features our v1 spec lacks (must match at launch)

| Gap | Splitwise free? | Our prior spec | Change |
|---|---|---|---|
| Comments on expenses | Yes | Missing | **Add to v1** |
| Edit history per expense | Yes | Activity log only | **Add** per-expense history view, v1 |
| Simplify debts | Yes | v2 | **Move to v1** |
| Multiple payers | Yes (listing) | SHOULD | **Make MUST, v1** |
| Recurring bills (monthly/weekly/yearly) | Yes | v2 | **Move to v1**. Rent is our core use case |
| Export CSV | Yes | SHOULD | **Make MUST, v1** |
| Categories | Yes | COULD | **Make MUST, v1** (default set) |
| Offline entry | Yes | v2 | **v1.1** |
| Multi-currency entry (no conversion) | Yes, 100+ currencies | v2 | v1.1: entry in any currency; conversion stays v2 |

---

## D. Changes to the Hisaab spec

**New product principles** (at the top of the spec, where every PR is judged against them):
- P1: Adding, editing, splitting, settling and searching expenses is free, unlimited, and never gated or delayed.
- P2: Ads never interrupt a task. Banners and native ads only; no interstitials, video or timers.
- P3: Anything free at launch stays free.
- P4: Push notifications are transactional only; never marketing.
- P5: Canceling and getting a refund each take at most 2 taps from Settings.

**Changed ACs:**
- AC 25 (interstitials capped) → **replaced:** "No interstitial, video or rewarded ads exist anywhere in the app."
- AC 16 multiple payers → [MUST]. AC 22 simplify debts → [MUST] v1. AC 40 CSV export → [MUST].

**New ACs (v1, all [MUST] unless marked):**
1. [ ] Payer can mark a single expense (or one person's share of it) as settled. The expense shows a "Paid" chip, the balance updates, and the other person is notified.
2. [ ] The amount field evaluates `+ − × ÷` expressions live, and the saved amount is the result rounded to paise.
3. [ ] A member can be added by name only (no phone/email) and later linked to a real account by the group creator.
4. [ ] User can set a private nickname for any friend, visible only to them.
5. [ ] "Pay via UPI" opens the device's UPI app picker, prefilled with payee VPA, amount and note. When the user returns, the app asks "Did the payment succeed?" and records a settle-up only on Yes. If no UPI app is installed, a UPI QR + copyable VPA are shown. The app never receives, holds or moves money.
6. [ ] Payees can add their UPI ID in their profile, and it's shown only to people they share a group or friendship with.
7. [ ] Any expense can be duplicated with one tap, opening prefilled with today's date.
8. [ ] An unsaved expense survives the app being closed or killed and is offered for restore on the next open.
9. [ ] Comments on expenses, with notifications to participants.
10. [ ] Per-expense edit history showing who changed which field from what to what.
11. [ ] Recurring expenses: weekly, fortnightly, monthly, yearly. Created automatically on schedule, with an edit/skip option.
12. [ ] Free full-history search by description, amount, member, category and date range.
13. [ ] Default categories selectable on each expense.
14. [ ] The group creator can merge two member records that belong to the same person, and balances combine correctly.
15. [ ] A Lifetime ad-free non-consumable purchase is available alongside the yearly plan. Restore works for both. Entitlement is cross-platform.
16. [ ] Settings shows "Manage subscription" and "Request a refund", each opening the store's own flow within 2 taps.
17. [ ] No free trial is offered at launch. No screen requires starting a trial to continue.
18. [ ] Push notification types are limited to an allow-list (expense added/edited, payment recorded, comment, invite, user-set reminder). Any other type is rejected server-side.
19. [ ] Android 13+: the notification permission is asked after the user's first group action, with an explanation, and re-offered from Settings if denied.
20. [ ] Recording the same settle-up twice (double tap or retry) creates one record. When both parties record the same payment, the second is flagged as a possible duplicate instead of creating negative debt.
21. [SHOULD] [ ] A read-only share link shows group balances without sign-in and can be revoked (v1.1).

**Updated success metrics:**
- Health: crash-free sessions ≥ 99.8%. Push delivery success ≥ 97%.
- Lagging: Play/App Store rating ≥ 4.6★ at 1,000 ratings. Share of 1★ reviews mentioning "limit", "ads" or "pay" < 10%.
- Leading: installs from "splitwise alternative" searches (ASO keyword tracking).

## E. Updated phasing

| Phase | Adds (vs prior plan) | Effort change |
|---|---|---|
| v1 MVP | + settle single expense, calculator input, name-only members, nicknames, UPI hand-off, duplicate, drafts, comments, edit history, recurring, simplify debts, multi-payer, categories, search, CSV, member merge, lifetime purchase, no-interstitial ads | XL → **XL+ (~13–15 weeks)** |
| v1.1 | Offline entry queue, multi-currency entry, read-only share link | M |
| v2 | Currency conversion, personal expenses, custom categories, charts with %, iPad layout, per-item % splits, collaborative item claiming | L |
| v3+ | Insights (Pro), OCR import from UPI screenshots / invoices, web app | L–XL |

## F. New risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Name clash with "The Hisaab"** (existing free Indian competitor) | High | High | Rename before any branding or store work. Run a trademark search + Play/App Store name check |
| Free, ad-free competitor (The Hisaab) undercuts our ads model | Med | High | Differentiate with AI scanning + item-level split, reliability, and a low-friction UPI hand-off. Keep ads to banners only so the experience stays close |
| UPI apps may restrict or warn on intent payments to individuals (NPCI fraud controls) | Med | Med | **[UNVERIFIED]** Test the intent flow on GPay, PhonePe, Paytm and BHIM before committing. QR + copy-VPA fallback is always available |
| v1 scope grew ~25% from the parity items | High | Med | Cut line if needed: recurring and member merge → v1.1. Never cut C1/C2 (the free-forever principles) |
| Lifetime purchase cannibalises yearly revenue | Med | Low | Price lifetime at 3× yearly (₹899). Review mix after 90 days |

## G. Open questions (new)

1. **New app name?** It's a blocker. **Default:** shortlist 5 and run trademark and store checks before design starts.
2. **Lifetime price: ₹899 or ₹999?** **Default: ₹899** (3× yearly).
3. **Is UPI hand-off in v1 or v1.1?** It depends on the intent-flow test in the risk table. **Default: v1** with the QR fallback.
4. **Should recurring expenses slip to v1.1 if the timeline is tight?** **Default: keep them in v1.** Rent is the #1 flatmate use case.

---

**Next steps:** (1) Pick the new app name. (2) Say "dynamodb do it" to design the single-table model now that the entities are settled (expense line items, settle-per-expense links, recurring schedules, comments, edit history, UPI profile). (3) Say "CEO take decisions" if you want the ₹299 yearly / ₹899 lifetime / ads-only mix pressure-tested.

Sources:
- [Splitwise on Google Play (India): listing + reviews](https://play.google.com/store/apps/details?id=com.Splitwise.SplitwiseMobile&hl=en_IN)
- [Splitwise on App Store (India) reviews](https://apps.apple.com/in/app/splitwise/id458023433?see-all=reviews)
- [Splitwise on App Store (US) reviews](https://apps.apple.com/us/app/splitwise/id458023433?see-all=reviews)
- [Splitwise feedback forum: top ideas](https://feedback.splitwise.com/forums/162446-general/filters/top)
- [The Hisaab: Splitwise free plan limits 2026 (competitor)](https://thehisaab.com/blog/splitwise-free-plan-limits)
- [Splitt: Splitwise stopped working 2026 (competitor)](https://splitt-app.com/blog/splitwise-stopped-working-alternative.html)
- [tricount: Splitwise alternatives in India 2025](https://tricount.com/en-us/blog/top-splitwise-alternatives-in-india-2025-which-app-should-you-switch-to)
- [Splitwise daily limit explainer](https://split-circle.com/en/blog/splitwise-daily-limit)
- [splitty: Splitwise free limits](https://splittyapp.com/learn/splitwise-free-limits/)