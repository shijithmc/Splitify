# Feature Name
**Snap & Split: AI Bill Scanning with Shared Receipts**

---

# Elevator Pitch
Photograph any bill and AI reads every line item, tax and total in seconds. Everyone in the group sees the same receipt and can split it item by item, which ends the "who ordered what" argument.

---

# Problem Statement
Typing a restaurant or grocery bill into a split app is slow and error-prone. It's even worse when people want to split by what they ordered instead of equally. Group members also can't see the original bill today, so disputes come down to "trust me". Reading the bill automatically and sharing the original image with every participant removes both the data-entry work and the trust gap, and it makes Hisaab clearly better than typing numbers into WhatsApp.

---

# User Stories

> **As a** payer at a restaurant, **I want** to photograph the bill and have items, taxes and total filled in automatically **so that** I can log a 15-item bill in under 30 seconds.

> **As a** payer, **I want** to review and correct what the AI read before saving **so that** a wrong reading never becomes a wrong balance.

> **As a** payer, **I want** to assign each line item to the people who had it, with tax and service charge shared proportionally **so that** nobody pays for someone else's drinks.

> **As a** group member, **I want** to see the original bill image on the expense **so that** I can check the charge myself without asking.

> **As a** group member, **I want** to be notified when a scanned bill involving me is added, with my itemised share **so that** I understand what I owe and why.

> **As a** user with a long supermarket receipt, **I want** to capture it in several photos **so that** the whole bill is read, not just the top.

> **As a** user in a regional-language restaurant, **I want** bills in Hindi, Tamil, Kannada, Malayalam and other Indian scripts to be read **so that** scanning works wherever I eat.

> **As a** privacy-conscious member, **I want** location metadata stripped and the bill visible only to group members **so that** my data isn't exposed beyond the group.

> **As a** free user, **I want** a monthly allowance of free scans **so that** I can try the feature before deciding to subscribe.

> **As a** support agent, **I want** to see a scan's status, the model's raw result and any failure reason **so that** I can resolve "scan got it wrong" tickets.

> **As a** product owner, **I want** accuracy, edit-rate and cost-per-scan metrics **so that** I can tune the AI model and pricing.

---

# Stakeholder Map

| Stakeholder | Interest / Impact | Input Needed Before Build |
|---|---|---|
| End user (payer) | Speed, accuracy, easy correction | Review-screen UX sign-off |
| End user (group member) | Transparency, fair itemised share | Visibility rules for bill images |
| Product owner | Differentiation, conversion lever (scan limits), engagement | Free vs paid scan allowance decision |
| Engineering lead | New Receipts bounded context, async AI pipeline, AWS→Google integration, cost control | Gemini access path (Gemini API vs Vertex AI) and model-pinning policy |
| Mobile lead | Camera capture, edge detection, compression, multi-page, item-assignment UI | Client framework (Flutter assumed) |
| ML / AI owner | Extraction accuracy, prompt + schema design, evaluation set | Golden test set of ≥200 real Indian bills |
| Security / compliance | Bill images contain PII (names, phone numbers, card last-4, GSTIN, addresses) sent to a third-party AI provider; DPDP disclosure | Privacy-notice update, confirmation that the provider doesn't train on our data, region choice |
| Finance | Per-scan AI cost vs revenue | Monthly AI budget ceiling + alarm threshold |
| Ops / support | Failed-scan triage | Scan-lookup view in the support tool |

---

# Acceptance Criteria

**Capture**
1. [ ] [MUST] "Scan bill" appears on the add-expense screen and as a shortcut in each group.
2. [ ] [MUST] User can capture with the camera or pick from the gallery (JPEG, PNG, HEIC) or a PDF (first 3 pages).
3. [ ] [MUST] The camera shows edge detection plus an auto-crop preview, and the user can retake before uploading.
4. [ ] [MUST] Up to 3 images can be captured for one long bill and are read as a single bill.
5. [ ] [MUST] Images are compressed on the device (longest side ≤ 2048 px) and location/EXIF metadata is stripped before upload.
6. [ ] [MUST] Files over 10 MB after compression are rejected with a clear message.
7. [ ] [MUST] Camera permission denial shows an explanation plus a "Choose from gallery" fallback.

**AI reading**
8. [ ] [MUST] The app extracts merchant name, bill date, currency, line items (name, quantity, unit price, line total), subtotal, each tax line (CGST, SGST, IGST, VAT), service charge, discount, tip/round-off and grand total.
9. [ ] [MUST] Extraction results appear within 10 seconds for 90% of single-image bills. The user sees a progress state throughout, never a frozen screen.
10. [ ] [MUST] If line items + taxes + charges − discount don't equal the grand total within ₹1, the review screen highlights the gap. The payer can save only after fixing it or confirming "Use grand total, split difference proportionally".
11. [ ] [MUST] Low-confidence fields are visibly flagged for review.
12. [ ] [MUST] Photos that aren't bills (selfies, blank pages) return "This doesn't look like a bill — try again or enter manually". No expense is created.
13. [ ] [MUST] Blurry or unreadable images return a retake prompt with a tip ("Flatten the bill, avoid glare").
14. [ ] [MUST] Bills printed in Indian regional scripts are read. Item names are kept in their original script, with an English transliteration when the model provides one.
15. [ ] [MUST] Text printed on the bill can never change app behaviour. The AI output is treated strictly as data and validated against a fixed structure; anything outside that structure is rejected.
16. [ ] [MUST] If the AI service is unavailable, the user can still save the expense by entering it manually, with the bill image attached.

**Review & itemised split**
17. [ ] [MUST] Nothing is saved without the payer's explicit confirmation on the review screen. The AI never creates or changes an expense by itself.
18. [ ] [MUST] Every extracted field can be edited, and line items can be added or deleted.
19. [ ] [MUST] Payer can choose "Split total" (the existing 4 modes) or "Split by items".
20. [ ] [MUST] In "Split by items", each line item can be assigned to one or more members. Shared items divide equally among their assignees. Unassigned items block saving and are highlighted.
21. [ ] [MUST] Tax, service charge, discount and round-off are distributed in proportion to each person's item subtotal. The per-person breakdown sums exactly to the grand total, in paise.
22. [ ] [MUST] Before saving, each person's share shows as "Items ₹X + tax ₹Y + service ₹Z = ₹Total".
23. [ ] [SHOULD] Quantity lines can be split by unit (e.g. "3 × Beer" → 1 each to 3 people).

**Sharing & visibility**
24. [ ] [MUST] The saved expense shows a bill thumbnail. Any expense participant, or any member if it's a group expense, can open the full image and the itemised breakdown.
25. [ ] [MUST] Non-members can't access the image even with a copied link. Image links expire within 15 minutes.
26. [ ] [MUST] Each participant's notification shows their itemised total ("You owe ₹640 for Paneer Tikka, 1/2 Naan basket + tax").
27. [ ] [MUST] Any participant can flag "This doesn't match the bill", which notifies the payer and records it in the activity log.
28. [ ] [MUST] Edits to a scanned expense follow the existing concurrency rule (second writer rejected and shown latest), and the image stays attached.
29. [ ] [MUST] Deleting the expense deletes the image after the 30-day restore window. The payer or group creator can remove just the image at any time.
30. [ ] [SHOULD] Duplicate detection: a scan with the same merchant, date and total as an expense in the last 7 days warns "Possible duplicate — already added by Priya".

**Limits & monetisation**
31. [ ] [MUST] Free users get 5 successful scans per calendar month. The counter is shown ("3 of 5 scans left").
32. [ ] [MUST] Ad-free subscribers get unlimited scans, subject to a fair-use cap of 100 per month.
33. [ ] [MUST] Failed or non-bill scans don't count against the allowance.
34. [ ] [MUST] Hitting the cap shows the paywall, with "Enter manually" always available. The core expense flow is never blocked.
35. [ ] [MUST] No ads appear on the capture, processing, review or itemised-split screens.

**Privacy & compliance**
36. [ ] [MUST] Before the first scan, a one-time notice says the bill image is processed by Google's AI service. The user must accept before continuing.
37. [ ] [MUST] Account deletion anonymises the uploader on shared bills. Images stay with the group record because they are other members' evidence too. Any group member can remove an image.
38. [ ] [MUST] Bill images are stored encrypted, never public, and never written to logs.

---

# User Journey Map

**Happy Path: restaurant dinner, 4 people, itemised split**
1. Dinner ends and Arjun paid ₹3,860. He opens the "Goa Trip" group and taps **Scan bill**.
2. The camera opens with edge detection. He frames the bill, it auto-captures, he taps **Use photo**.
3. A progress state shows: "Reading your bill…" (skeleton list animating). About 5 seconds.
4. The review screen shows: "Fisherman's Wharf · 26 Sep · 14 items · Subtotal ₹3,272 · CGST ₹82 · SGST ₹82 · Service ₹327 · Round-off +₹0.40 · Total ₹3,860". Totals match (green tick). The "Kingfisher ×3" line is flagged low-confidence in amber. He checks it and it's correct.
5. He picks **Split by items** and taps member avatars on each item. Starters are shared by all 4, and each beer goes to one person.
6. Breakdown preview: Arjun ₹1,120, Priya ₹840, Rahul ₹1,090, Meera ₹810, summing to ₹3,860 exactly.
7. **Save**. The expense appears with a bill thumbnail and the balances update.
8. Priya gets a push notification: "Arjun added Fisherman's Wharf — you owe ₹840". She taps it, sees the bill image and her items, and is satisfied. No dispute.

**Key Error Path: AI misreads the total**
1. Faded thermal paper makes the AI read ₹3,160 instead of ₹3,860.
2. The item sum check doesn't match. The review screen shows a red banner, "Items add up to ₹3,860 but total reads ₹3,160 — check the total", and highlights the total field.
3. Arjun zooms into the bill image (shown side by side), corrects the total to ₹3,860, and the banner turns green.
4. He saves. The correction is logged anonymously as an accuracy signal. The scan still counts as successful.

**Secondary Error Path: AI service down**
1. The scan times out after 20 seconds or the provider returns errors.
2. The app shows "Couldn't read the bill right now — enter details manually, the photo stays attached", with a **Try again** button.
3. The user saves manually with the image attached. The failed scan doesn't consume allowance.

---

# Edge Cases & Boundary Conditions

| Condition | Expected Behaviour | v1? |
|---|---|---|
| Empty / zero-state | First visit to Scan shows a 3-frame tip card (flatten, good light, whole bill in frame) plus the privacy notice | In |
| First-time vs returning | First-timer sees tips + privacy consent + a free-scan counter explainer. Returning user goes straight to camera | In |
| Max volume | ≤ 3 images per bill, ≤ 10 MB each, ≤ 150 line items per bill; above that, grand-total-only mode | In |
| Long receipt (supermarket) | Multi-image capture; overlapping lines between photos de-duplicated by the model and flagged for review | In |
| Handwritten bill (local dhaba, auto) | Best effort; low confidence flags most fields; user edits | In |
| Regional scripts / bilingual bills | Supported; original script kept | In |
| Non-INR bill (foreign trip) | Currency detected and shown; v1 blocks save unless the group currency matches — "Multi-currency coming soon — enter converted amount" | Partial |
| Discounts, happy-hour offers, complimentary items (₹0) | Discount shown as negative line, distributed proportionally; ₹0 items shown but ignorable | In |
| Tax-inclusive MRP bills (grocery) | No separate tax lines; line totals = prices; totals check still applies | In |
| Tip written by hand on printed bill | Detected as tip if legible, otherwise user adds it manually | In |
| Concurrent access | Two members scan the same bill: duplicate warning on the second (AC 30). Concurrent edits: existing version conflict rule | In |
| Collaborative "claim your items" | Each member taps their own items on a shared scanned bill before finalising | Out (v2) |
| Permission boundary | Non-member requesting image gets 404; removed group member loses image access immediately | In |
| Offline / slow network | Capture works offline; upload queued with "Will read when you're online" plus a local notification when ready. 2G: upload progress bar, resumable | Partial (queue v1, background resume v2) |
| Accessibility | Screen reader announces each item, price and assignees; assignment by list selection, not only avatar drag; camera has a manual shutter + audio feedback | In |
| Mobile / small screen | Review screen collapses the image into a toggle; item list scrolls with a sticky running total | In |
| Partial failure mid-flow | Upload OK but reading fails → retry once automatically, then manual fallback with image kept. Save fails after review → draft kept on device, retry doesn't duplicate (idempotency key) | In |
| Prompt injection text printed on a bill | Ignored; output must match a fixed structure; out-of-structure output = failed scan | In |
| Non-bill / inappropriate image | "Not a bill" response; image deleted within 24h, not stored with any expense | In |
| Very large bill (₹10 lakh+ wedding catering) | Allowed up to the existing ₹1 crore expense ceiling | In |
| Scan allowance boundary | 5th scan works; 6th shows paywall; month resets 1st of month, IST | In |
| Subscription lapses mid-month | Falls back to the free allowance, counting scans already used this month | In |
| Model version upgrade changes output | Pinned model version; upgrade only after the golden-set evaluation passes | In |

---

# Out of Scope (This Iteration)

- We will NOT offer collaborative "claim your items" where each member selects their own items. *Future: v2. Adds a shared draft state and real-time updates.*
- We will NOT auto-convert foreign currency bills. *Future: arrives with multi-currency in v2.*
- We will NOT auto-categorise expenses or produce spending insights from items. *Future: v3 insights / Pro.*
- We will NOT read UPI screenshots, bank SMS or e-mail invoices. *Future: v3 "import from screenshot".*
- We will NOT scan bills in bulk (e.g. 20 receipts at once). *Future: v3 trip-end bulk import.*
- We will NOT save anything automatically without the payer confirming. A human is always in the loop, by design.
- We will NOT train or fine-tune our own model. Prompting a hosted model with a fixed output structure is enough for v1.
- We will NOT support video capture or live-camera text overlay.

---

# Dependencies & Prerequisites

| Type | Dependency | Status | Owner |
|---|---|---|---|
| Feature | Hisaab v1 core: groups, expenses, 4 split modes, balances, activity, push | Not started (parent spec) | Backend/Mobile |
| Feature | Ad-free entitlement (drives scan allowance) | Not started (parent spec) | Backend |
| Feature | Expense model extended with line items + item-to-member assignments + proportional charge distribution | Not started | Backend |
| Data | Golden evaluation set: ≥200 real Indian bills (restaurant, grocery, fuel, pharmacy, handwritten, 5+ scripts) with hand-labelled correct values | Not started | ML owner |
| Infrastructure | New Receipts bounded context: private encrypted S3 bucket (image upload via short-lived signed links), async pipeline (upload event → queue → Lambda → AI call → result stored → push notification), dead-letter queue, scan-status record in DynamoDB | Not started | Backend/DevOps |
| Infrastructure | AWS → Google authentication without long-lived keys (workload identity federation for Vertex AI), or an API key held in Secrets Manager (Gemini API) | Not started | DevOps |
| Infrastructure | Cost guardrails: per-user scan counter, daily global spend alarm, circuit breaker on provider error rate | Not started | Backend |
| Legal / Compliance | Privacy notice update: bill images processed by Google as a sub-processor; DPDP disclosure; retention terms | Not started | Legal |
| Legal / Compliance | Confirm the chosen Google tier contractually excludes our data from model training (free tiers of Google AI services may use inputs for improvement; paid/Vertex tiers generally don't — verify current terms) | Not started | Legal/Eng lead |
| Third Party | Google Cloud project with billing, Gemini Flash access, quota increase for launch volume | Not started | Eng lead |
| Third Party | App Store / Play privacy labels updated (photos collected, shared with a third party for processing) | Not started | Product |

---

# Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Misread amounts create wrong balances and erode trust | Med | High | Mandatory human review; totals check with ₹1 tolerance; low-confidence flags; side-by-side image; post-launch accuracy dashboard; golden-set gate before any model change |
| Privacy: bills leak PII (phone, card last-4, GSTIN, address) to a third party or non-members | Med | High | Explicit consent before first scan; paid Google tier with no-training terms; strip EXIF; private encrypted storage; 15-minute signed links; membership check on every image request; no images in logs |
| AI cost runaway (abuse, retries, bots) | Med | Med | Monthly allowance per user; fair-use cap for subscribers; per-user rate limit (e.g. 10 scans per hour) at API Gateway + app level; global daily spend alarm; failed scans capped at 3 retries |
| Latency: AI call exceeds API timeout and the user abandons | Med | Med | Async processing (the upload request returns immediately; result pushed/polled); 20-second hard timeout then manual fallback; client compression keeps payloads small |
| Provider outage or model deprecation breaks scanning | Low | Med | Circuit breaker + manual fallback with image kept; pinned model version; provider access behind an adapter interface in the Receipts context so a different model can be swapped in |
| Prompt injection via text printed on a bill | Low | Med | No tools or actions given to the model; strict output structure with validation; output treated as untrusted data; amounts range-checked |
| Scan paywall annoys free users and hurts adoption | Med | Med | Manual entry never blocked; 5 free scans/month; A/B test 3 vs 5 vs 10 against conversion and D30 retention |
| Poor accuracy on regional scripts or handwriting | High | Med | Golden set includes 5+ scripts and handwritten bills; publish accuracy per category internally; graceful low-confidence UX |
| Cross-cloud dependency (AWS + Google) complicates ops and security review | Med | Low | Keyless federation, single adapter, dedicated alarms, runbook for Google-side incidents |

---

# Open Questions

1. **Should scanning be a paid lever (5 free/month, unlimited with subscription) or free for everyone?** It changes the subscription from "ad-free" to "ad-free + unlimited scans" and reverses the parent spec's "no functional limits" assumption. **Default: 5 free/month, unlimited (100 fair-use) with the ₹299 subscription.** It's the strongest conversion lever available, and AI cost scales with use.
2. **Gemini API (AI Studio key) or Vertex AI (Google Cloud)?** This decides data-use terms, regional hosting, enterprise SLA and auth model. **Default: Vertex AI in the Mumbai region (asia-south1) if Gemini Flash is available there.** It gives no-training terms, India data residency and keyless auth from AWS. Otherwise use the paid Gemini API tier.
3. **Which Gemini Flash version, and how is it upgraded?** Model versions change behaviour and pricing. **Default: pin the current GA Flash version at build time; upgrade only when the golden set shows equal or better accuracy at equal or lower cost.**
4. **Who can view the bill image: all group members, or only that expense's participants?** A bill may show what non-participants didn't order and personal data. **Default: all current group members for group expenses; only the two people for 1:1 expenses.**
5. **Should the bill image survive the uploader deleting their account?** It's evidence other members rely on, but it may contain the uploader's PII. **Default: keep with the group record, anonymise the uploader, and let any member remove it.**
6. **Should confirmed corrections be used to improve prompts?** Using real bills for improvement needs consent. **Default: store only anonymised field-level "was corrected" flags, never images, for accuracy metrics.**
7. **How are GST lines handled when the bill shows tax-inclusive and exclusive items together?** It affects distribution accuracy. **Default: distribute every non-item charge proportionally to item subtotal. The payer can override per charge.**
8. **What's the monthly AI budget ceiling?** It sets alarm and kill-switch thresholds. **Default: alarm at 80% of an agreed monthly budget; pause free-tier scans (not paid) at 100%.**

---

# Success Metrics

| Type | Metric | Definition | Target | Measurement |
|---|---|---|---|---|
| Leading | Scan adoption | % of new expenses created via scan | ≥ 25% of expenses by month 2 | Expense creation source |
| Leading | Scan success rate | % of scans that return a valid bill reading | ≥ 92% | Receipts context status records |
| Leading | Itemised split usage | % of scanned expenses saved with "Split by items" | ≥ 35% | Expense split mode |
| Lagging | Zero-edit accuracy | % of scans saved with no edits to total and tax fields | ≥ 85% | Review-screen diff flags |
| Lagging | Scan-driven conversion | % of users who hit the scan cap and subscribe within 7 days | ≥ 6% | Paywall source attribution |
| Lagging | Dispute rate | "Doesn't match the bill" flags per 100 scanned expenses | < 1 | Activity events |
| Lagging | Retention lift | D30 retention of users with ≥1 scan vs without | +10 points | Cohort analysis |
| Health | Scan latency | Upload complete → reading ready, p50 / p95 | ≤ 5 s / ≤ 12 s | Pipeline timestamps |
| Health | AI error rate | Provider errors + invalid-output responses / total calls | < 2% | Adapter metrics |
| Health | Cost per successful scan | AI spend / successful scans | Within the agreed budget; alarm at +30% week-on-week | Google billing export + scan count |
| Health | Pipeline dead-letter depth | Unprocessed scan jobs | 0 sustained > 15 min | Queue alarm |

---

# Assumptions Made

- Assumed **scanning becomes a subscription benefit (unlimited) with 5 free scans/month**. If it stays fully free, AI cost is covered only by ads, and the ₹299 value proposition stays "ad-free only".
- Assumed **"shared with everyone" means the bill image and itemised breakdown are visible to all group members**, not that it's published outside the group. If it meant public/social sharing, a different privacy model is needed.
- Assumed **Gemini Flash via Vertex AI in an India region** with contractual no-training terms. If only the free Gemini API tier is used, bill data may be used by Google, which is unacceptable for PII-bearing receipts.
- Assumed **the AI result is always reviewed by a human before saving**. If full auto-save is wanted, accuracy targets and dispute handling must be much stronger.
- Assumed **processing is asynchronous** (upload returns immediately; result arrives in seconds). If synchronous, AI latency risks API timeouts.
- Assumed **itemised split moves from the parent spec's v3 into this feature**. That adds line items to the expense model now.
- Assumed **INR-only saving in v1**. Foreign-currency bills are detected but need manual conversion.
- Assumed **≤150 line items and ≤3 images per bill**. Beyond that, grand-total-only mode.
- Assumed **the Flutter client** with on-device edge detection and compression. If native or MAUI, the capture libraries change.
- Assumed **AWS remains the primary platform**, with Google used only for AI inference behind a replaceable adapter. If the model is ever switched to Amazon Bedrock, only the adapter changes.

---

# Recommended Phasing

| Phase | Scope | Value Delivered | Estimated Effort |
|---|---|---|---|
| v1: Snap & Split MVP | Camera/gallery/PDF capture, multi-image, compression + EXIF strip; async Gemini Flash reading with fixed output structure; totals check + confidence flags; mandatory review; split total or split by items with proportional tax/charges; shared bill image + itemised notifications; dispute flag; duplicate warning; allowance + paywall; manual fallback; consent notice; cost guardrails; golden-set evaluation harness | Fast, trustworthy bill entry; transparent shared receipts; conversion lever | L (~5–6 weeks on top of core v1, 1 backend + 1 mobile + part-time ML) |
| v2 | Collaborative "claim your items"; foreign-currency bills with conversion; background resumable upload offline; per-unit quantity split; accuracy-driven prompt tuning | Group self-service splitting; travel use case | M |
| v3+ | Item-level categories + spending insights; UPI screenshot / e-mail invoice import; bulk trip-end scanning; second-model fallback | Pro-tier value, deeper engagement | L |

---

**Next steps:** answer Open Questions 1 and 2 first; they change subscription positioning and the Google integration path. Then "dynamodb do it" to fold the line-item and scan-job entities into the single-table design, or "EA do it" to build the Receipts context.