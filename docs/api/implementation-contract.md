# Implementation contract

JSON uses camelCase. Money is integer paise; dates YYYY-MM-DD; timestamps UTC ISO-8601. Enums serialize as strings. Authentication: Bearer access token. Ledger/group/device/preferences mutations require `Idempotency-Key` header (UUID). Identity operations, account deletion and server billing refresh have their own state/credential checks. Errors: `{ code, message, correlationId }` with appropriate HTTP status.

All endpoints have shared per-IP rate limits before authentication and per-account limits after authentication. AI receipt create/complete/retry routes share tighter limits. HTTP 429 responses include `Retry-After`; see [API abuse protection](../runbooks/api-rate-limits.md) for ceilings, counter semantics and rollout verification.

## HTTP API (under /v1)

- POST /auth/dev `{displayName}` -> session (Development + explicit DevAuth only).
- POST /auth/sign-in `{provider: google|apple|phone, idToken, nonce, authorizationCode?, displayName?}` -> session. Google/Apple use an ID token; phone uses the six-digit SMS code in `idToken`. GET /auth/challenge -> `{nonce}` for Google/Apple.
- POST /auth/phone/challenge `{phoneNumber}` -> `{nonce,expiresAt,resendAfterSeconds:60}`. Phone numbers require E.164 format including `+` and country code. The nonce is bound to that number and sign-in purpose; the response never contains the code.
- POST /auth/phone/link/challenge `{phoneNumber}` -> the same challenge shape; requires recent authentication. Submit proof to `/auth/link` with `{provider:phone,idToken:code,nonce}`.
- POST /auth/phone/reauthenticate/challenge `{phoneNumber}` -> the same challenge shape; requires an authenticated account with that linked phone. POST /auth/phone/reauthenticate `{nonce,code}` -> session for that same account, rotating the current session.
- POST /auth/apple/callback accepts Apple form POST for configured Android web sign-in; validates the unexpired state and redirects only to the configured package.
- POST /auth/refresh `{refreshToken}` -> session. POST /auth/sign-out -> 204.
- POST /auth/link `{provider,idToken,nonce,authorizationCode?}` -> user; requires recent authentication.
- GET /me -> `{user, entitlement, preferences}`. DELETE /me `{confirm:true}` -> deletion state. PATCH /me/preferences `{expenses:true,payments:true,invites:true}`.
- GET /groups -> `{items:[GroupSummary]}`. POST /groups `{name,type:Home|Trip|Couple|Other|Direct}` -> GroupDetail.
- GET /groups/{id} -> GroupDetail. PATCH /groups/{id} `{version,name?,archived?}` -> GroupDetail.
- POST /groups/{id}/members `{displayName,email?,phone?}` -> Member (placeholder).
- POST /groups/{id}/members/{participantId}/external `{version}` -> GroupDetail; creator-only, unclaimed placeholder at least 90 days old.
- POST /groups/{id}/invites/revoke `{token}` -> `{revoked:true}`; creator-only, scoped to this group.
- GET /invites -> fresh verified-email invitations; requires authoritative email proof from a sign-in within ten minutes.
- POST /groups/{id}/invites `{participantId?}` -> `{token,url,expiresAt}`. POST /invites/accept `{token}` -> GroupDetail.
- POST /groups/{id}/leave `{acknowledgeBalance}`; DELETE /groups/{id} `{version}`.
- GET /groups/{id}/expenses?cursor=... -> `{items:[Expense],nextCursor}` (25 per page).
- POST /splits/preview `{amountPaise,mode:Equal|Exact|Percentage|Shares,participants:[{participantId,value}]}` -> `{shares:{pid:paise},roundingOrder:[pid]}`.
- POST /groups/{id}/expenses `{id,description,amountPaise,date,payerId,mode,participants:[{participantId,value}]}` -> Expense.
- PUT /groups/{id}/expenses/{expenseId} same + `{version}` -> Expense.
- DELETE /groups/{id}/expenses/{expenseId} `{version}` -> Expense.
- POST /groups/{id}/expenses/{expenseId}/restore `{version}` -> Expense.
- GET /groups/{id}/activity -> `{items:[Activity]}`; GET /activity -> `{items:[Activity]}`.
- POST /groups/{id}/settlements `{id,fromId,toId,amountPaise,method:Cash|UPI|Other}` -> Settlement.
- POST /groups/{id}/settlements/{id}/dispute `{version}` -> Settlement.
- GET /groups/{id}/settlements -> `{items:[Settlement]}`.
- GET /balances -> `{netPaise,owedPaise,owingPaise,friends:[{id,displayName,netPaise}]}`.
- GET /billing/entitlement -> Entitlement. POST /billing/refresh -> Entitlement (server RevenueCat fetch only).
- POST /devices `{id,token,platform}`; DELETE /devices/{id}.

Session = `{accessToken,refreshToken,user,entitlement}`. User = `{id,displayName,email?}`.
GroupSummary = `{id,name,type,archived,version,memberCount,netPaise}`.
GroupDetail = `{id,name,type,archived,version,creatorId,members:[Member],balances:[Balance]}`.
Member = `{id,userId?,displayName,isPlaceholder,isExternal,isDeleted,hasLeft,createdAt?}`. GroupDetail members also include the computed `externalReviewDue` flag.
Balance = `{participantId,netPaise,counterparties:{pid:paise}}`.
Expense = `{id,groupId,description,amountPaise,date,payerId,mode,participants:[{participantId,value}],shares:{pid:paise},version,deletedAt?,createdBy,updatedAt}`.
Settlement = `{id,groupId,fromId,toId,amountPaise,method,version,disputed,createdBy,createdAt}`.
Activity = `{id,groupId,kind,actorId,actorName,description,createdAt,entityId,changes?}`. Names resolve at read time, including `Deleted user`. Expense `changes` contains accounting `before`/`after` values and a `descriptionChanged` flag without duplicating description text.
Entitlement = `{adFree,status,expiresAt?,store?,verifiedAt?}`.

Backend recomputes shares and enforces versions. Positive balance means is owed. 50 retained participants, one payer, INR only. Deleted expense restore window 30 days. Settlements reverse once on receiver dispute. Group reads use a version-stable snapshot.

Private resources require current membership; unauthorized group access returns 404. Auth/device responses contain credentials or PII and must not be logged. The account merge conflict is deliberate: already-owned provider identities are not consolidated by this API.

Phone challenges have separate purposes: sign-in, linking and reauthentication proof cannot be substituted for each other. Authenticated challenges bind the current account and authentication event; routine access-token refresh preserves them, while a different login or reauthentication does not. Linking remains an explicit action after reauthentication and cannot move a phone identity from another account. Phone login does not enable phone invitation discovery or automatically claim placeholder histories. SMS verification is server-side through Twilio Verify; missing or disabled provider configuration fails closed. See [authentication setup](../runbooks/authentication.md#configure-phone-otp) for service settings and live acceptance.

A phone challenge expires after ten minutes and permits five provider code checks. A successful exchange consumes it atomically with the session or credential-link write. Resends request a new challenge and are subject to a shared 60-second per-number cooldown plus the [SMS attempt limits](../runbooks/api-rate-limits.md#phone-otp). The UI must use the returned nonce and expiry, never infer successful authentication from SMS delivery. `displayName` supplies a new account's name; returning phone sign-in preserves the existing profile and does not clear an email linked through Google/Apple. The session/user response shape is unchanged; no raw phone number is returned in `user`.

Phone failures use the standard error envelope: `422 phone_invalid` for malformed numbers; `422 phone_code_invalid` for a malformed code; `401 phone_code_invalid` for rejected, expired or exhausted proof; `422 phone_not_linked` when reauthentication uses a number not linked to the current account; `429 phone_rate_limited` with `Retry-After` for SMS send/check limits; and `503 phone_unavailable` for disabled, missing or unavailable SMS service. Existing `challenge_invalid`, `challenge_expired`, `reauthentication_required`, `account_merge_required` and session errors still apply where their checks fail.
