# Receipt HTTP contract

All routes require the existing Bearer session. All mutations except media tickets and previews require a UUID `Idempotency-Key`. Receipt reads and idempotency replays recheck active account, session, current group membership and private draft ownership. `HasLeft` members cannot read receipts. Money is integer paise; all dates are ISO-8601 and receipt/expense/image IDs are UUIDs. Item and charge IDs use 1–36 ASCII letters, digits, underscores or hyphens; participant IDs refer to the existing group roster.

## Consent, allowance, upload

`GET /v1/receipts/allowance`:

```json
{"plan":"free","cap":5,"used":1,"reserved":0,"remaining":4,"resetsAt":"2026-10-01T00:00:00+05:30","scanAvailable":true,"reason":null,"consentVersion":"2026-09-26-v1","consentAccepted":true}
```

Paid eligibility is the server-verified RevenueCat entitlement; ad-only support grants do not qualify. Monthly successes and in-flight reservations share the cap. A terminal failure does not consume a success. Attempts (including automatic retries and failed attempts) are limited to ten per rolling hour. Initial admission pins an IST quota month; an automatic retry preserves it; an explicit retry after a terminal failure enters the current month.

`PUT /v1/receipts/consent`: `{"version":"2026-09-26-v1","accepted":true}`.

`POST /v1/groups/{groupId}/receipts`:

```json
{"id":"a156f830-a433-473c-bac9-d41c5e2595f5","scanRequested":true,"images":[{"id":"a291f830-a433-473c-bac9-d41c5e2595f5","contentType":"image/jpeg","sizeBytes":24511,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}
```

One to three preprocessed JPEG/PNG images, each at most 10 MiB. Upload admission independently caps ten sessions per rolling hour, 100 outstanding drafts and 300 MiB of pending declared bytes per account (deployment configurable). Unsealed uploads expire after 24 hours; sanitized drafts after seven days. Final attachment or physical purge releases the byte reservation. Client renders PDF pages/HEIC and removes EXIF before this upload contract. Server validates actual bytes/checksum, re-encodes, checks dimensions and freezes canonical images before extraction. Response is `{"receipt": <status>, "uploads":[{"id":"...","url":"...","method":"PUT","headers":{},"expiresAt":"..."}]}`. Supply every returned upload header. A local relative URL is authenticated with the current Bearer token; never forward a session token to a remote S3 upload origin. Retrying create returns fresh upload grants only while awaiting upload.

`POST /v1/receipts/{id}/complete`: `{"version":1}` seals the manifest; response is compact `{"id":"...","state":"validating","version":2}`. Validating, inference and cleanup run asynchronously from durable work; inference cannot start from an unsealed S3 upload event. Manual intent still sanitizes the image but makes no provider request.

## Status, retry, review and finalization

`GET /v1/receipts/{id}` returns:

```json
{"id":"...","groupId":"...","state":"ready","version":6,"attempts":1,"errorCode":null,"imagesRemoved":false,"expenseId":null,"revision":0,"revisionHash":null,"expiresAt":"...","manualAvailable":true,"media":[{"id":"...","contentType":"image/jpeg","sizeBytes":10000,"width":1000,"height":1800,"thumbnailSizeBytes":1500}],"extraction":{"classification":"bill","document":{},"model":"...","promptVersion":"1","schemaVersion":"1","warnings":[]},"review":null}
```

States: `awaiting_upload`, `validating`, `queued`, `processing`, `ready`, `manual_ready`, `failed`, `unreadable`, `not_bill`, `attached`; cancelled/expired private drafts return 404. Review is a confirmed `ReceiptRevision` containing `receiptId`, `revision`, `review`, `shares`, `reviewHash`, `reviewedAt`. Extraction `document` uses the `ReceiptReview` structure below, without assignments. Poll while foregrounded with bounded backoff. Manual fallback remains available whenever sanitized media exists and has not been rejected as a non-bill or removed.

`POST /v1/receipts/{id}/retry`: `{"version":6}`. Only a failed, unattached, validated draft with fewer than three actual provider attempts can retry. One automatic transient retry is allowed after the first attempt, then one user retry. Attempts use a 20-second deadline and generation/lease fencing. Provider billing after an ambiguous timeout cannot be guaranteed exactly once.

`POST /v1/receipts/{id}/preview`: `ReceiptReview` body:

```json
{"merchant":"Cafe","date":"2026-09-26","sourceCurrency":"INR","grandTotalPaise":11000,"items":[{"id":"item-1","name":"Dinner","quantity":"1","unitPricePaise":10000,"lineTotalPaise":10000,"assigneeIds":["alice","bob"],"ignored":false}],"charges":[{"id":"tax-1","name":"GST","kind":"Tax","amountPaise":1000,"includedInItemPrices":false}],"splitByItems":true,"differenceAcknowledged":false,"acknowledgedReviewHash":null,"convertedToInr":false,"subtotalPaise":10000}
```

Preview returns `reviewHash`, `itemSubtotalPaise`, `additiveChargesPaise`, `differencePaise`, `requiresDifferenceAcknowledgement`, canonical `shares`, per-person `people` breakdown, `warnings`, and optional decimal-string `sourceDifference` for the original currency. Foreign total-only conversion reports `differencePaise:0` to avoid adding original-currency lines to an INR total. Review has optional original foreign `sourceGrandTotal`/`sourceSubtotal`; items preserve optional `sourceUnitPrice`/`sourceLineTotal` and transliteration/confidence. Charges may specify weights to override proportional distribution. Inclusive charges are informational and not added twice.

For a difference above 100 paise, accept by resubmitting `differenceAcknowledged:true` and the exact preview `acknowledgedReviewHash`. Manual currency conversion also requires the current preview hash. Any changed item, charge, assignment or total invalidates acknowledgment. Every non-ignored item in item mode needs active participant assignees. Maximum 150 items, 20 charges and 50 participants; reviewed serialized document at most 1.5 MiB, paged into at most 24 × 64 KiB chunks. Excess detected items use explicit grand-total-only extraction, never silent truncation.

Existing expense create/update JSON gains:

```json
{"receipt":{"receiptId":"...","version":6,"payerConfirmed":true,"review":{}}}
```

`GET /v1/groups/{groupId}/expenses/{expenseId}` retrieves one exact expense by ID (including its receipt reference) for notification routing; receipt detail/media remain separately authorized. All existing expense fields are still required. New receipt attachment requires the signed-in payer. Server recalculates item shares and commits attachment revision, expense, balances and audit in one conditional transaction. Ordinary edits preserve the receipt; changing date/payer/shares requires a reviewed receipt submission. Manual attachment fences any outstanding AI attempt and releases its reservation.

`POST /v1/receipts/{id}/duplicate-check` uses the review body and returns `{"items":[{"expenseId":"...","receiptId":"...","addedBy":"participant-id","createdAt":"..."}]}`. It warns about active expenses in the preceding seven days matching normalized merchant, exact bill date, currency and total; it does not reject saves. Resolve `addedBy` from group members.

## Private media and reporting

`POST /v1/receipts/{id}/media-ticket` returns `{"ticket":"...","expiresAt":"..."}`. Ticket validity is ten minutes, bound to the account and session. `GET /v1/receipts/{id}/media/{mediaId}?ticket=...&thumbnail=false&offset=0&length=1048576` returns bytes; every chunk also requires Bearer and fresh membership. Fetch chunks up to 1 MiB, concatenate in order, and use status size fields. Thumbnails are JPEG. No raw S3 download URL is exposed; copied tickets cannot grant another account access. Responses forbid caching.

`DELETE /v1/receipts/{id}/images`: `{"version":6}` immediately revokes all media access and durably schedules removal; any current member may remove shared media. Accounting breakdowns remain. Expense deletion schedules purge after its 30-day restoration window; restoring before the purge clears that schedule. Uploader account deletion anonymizes shared receipts and cancels/purges private drafts.

`POST /v1/groups/{groupId}/expenses/{expenseId}/receipt-flags`: `{"reason":"total"}` (`total`, `items`, `image`, `other`). Payer or expense participants may report once per account/expense; creates activity and payer notification, without balance changes.

## Runtime controls

Live inference fails closed unless `Hisaab:Receipts:Enabled` and `ProviderValidated` are true, EmergencyStop is false, and `MonthlyBudgetUsd`/`MaxAttemptCostUsd` are configured positive values. Durable `OPERATIONS/RECEIPTS` contains `emergencyStop` and `pauseFree`. Per-attempt budget liability is atomically reserved in `RECEIPT_BUDGET/yyyyMM` (UTC finance month); failure/timeouts do not refund this conservative cost estimate. `MonthlyBudgetUsd` is a hard admission ceiling shared by every account and plan, including paid subscribers. An attempt may reach the ceiling exactly but cannot exceed it; allowance reports `scanAvailable:false` with `scan_paused` when the next attempt cannot fit. `pauseFree` can still stop free scans earlier, but no subscription or runtime resume bypasses the budget ceiling. Five consecutive provider failures open a five-minute circuit. Store audit/operational records contain counts and sanitized codes, never image bytes or provider raw output.

The receipt worker is the sole public-API inference path. Before every provider call, including automatic retries, it conditionally commits the account's hourly attempt admission, monthly scan reservation, shared budget liability and receipt lease together. Concurrent worker instances and duplicate queue deliveries cannot reserve the same budget version or receipt lease twice. Manual attachment, previews and duplicate checks do not invoke the provider. The budget bounds configured per-attempt liability, not a provider invoice: `MaxAttemptCostUsd` must conservatively cover the permitted model, images, output and thinking tokens.

Media downloads independently reserve the bounded response byte count before fetching storage. Defaults: 300 MiB per account over the preceding hour and 60 chunks per UTC minute; both thumbnails and full images count. `Hisaab:Receipts:MaxDownloadBytesPerHour` and `MaxDownloadChunksPerMinute` customize these ceilings. Byte accounting includes the oldest partial minute conservatively (up to 59 seconds extra); failed or interrupted reads are not refunded because storage/egress may already have incurred cost. Admission atomically checks active account/session and the usage-row version; concurrent requests cannot overshoot. `receipt_download_rate_limited` (429) asks the client to retry later. Receipt access and session-bound tickets remain separately checked on every chunk.
