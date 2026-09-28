# API abuse protection

All HTTP requests pass shared admission before session lookup, body binding or endpoint work. Authenticated requests also consume account admission. DynamoDB stores conditional counters, so opening another session, changing receipt IDs/idempotency keys, restarting a Lambda or scaling out does not reset the allowance. Shared admission rejections return HTTP 429, `code: rate_limited`, `Retry-After` seconds and `Cache-Control: no-store`.

| Scope | Default ceiling |
|---|---:|
| Every request, per source IP | 600/minute |
| All `/v1/auth` requests combined, per source IP | 30/minute |
| All authenticated requests combined, per account | 240/minute |
| Authenticated `/v1/auth` requests combined, per account | 30/minute |
| AI create/complete/retry requests combined, per source IP | 30/minute |
| AI create/complete/retry requests combined, per account | 12/minute |
| Actual provider attempts, including failures and automatic retries, per account | 10/rolling hour |

The three AI entry routes are `POST /v1/groups/{groupId}/receipts`, `POST /v1/receipts/{id}/complete` and `POST /v1/receipts/{id}/retry`. Admission counts invalid/replayed requests too; existing idempotency still prevents duplicate work. Manual receipt creation shares the create route and its admission limit. Receipt polling, review, media and the remaining routes retain general admission, plus existing upload/download byte and monthly scan quotas.

General request counters use fixed UTC minute windows. Traffic near a boundary can consume the allowance on both sides. Counter rows use `RATE#<scope>#<SHA256(subject)>`, the window number as sort key, and a short DynamoDB TTL; expiration is enforced by choosing the current window, never by waiting for asynchronous TTL deletion. Each scope is shared across routes. A conditional transaction admits all applicable counters or none. Persistent contention returns 429 with a one-second retry. Store errors fail closed through normal API error handling; no route runs unmetered.

Source identity comes only from `Connection.RemoteIpAddress`. The [AWS HTTP API v2 adapter](https://github.com/aws/aws-lambda-dotnet/blob/master/Libraries/src/Amazon.Lambda.AspNetCoreServer/APIGatewayHttpApiV2ProxyFunction.cs) populates it from API Gateway's trusted request context. Forwarded IP, account and device headers are ignored. IPv4-mapped addresses are normalized; an IPv6 /64 shares an allowance. Missing source addresses share one conservative `unknown` bucket. Shared networks can therefore share an IP allowance. Do not enable arbitrary forwarded-header trust in front of this middleware.

Settings under `Hisaab:RateLimits` are `RequestsPerIpPerMinute`, `AuthRequestsPerIpPerMinute`, `RequestsPerAccountPerMinute`, `AuthRequestsPerAccountPerMinute`, `AiRequestsPerIpPerMinute` and `AiRequestsPerAccountPerMinute`. Each must be 1–10000; invalid settings stop startup instead of disabling enforcement. Keep the same configuration across all API instances. New routes automatically receive general limits; mark any future inference entry with `AiRequestRateLimit` and add provider-side admission before spending.

The gateway retains 50 requests/second and burst 100 defaults, with 5 requests/second and burst 10 on each AI entry route. [AWS documents gateway throttling as best effort](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-throttling.html); the application counters and atomic worker budget provide separate enforcement. This is application abuse protection, not a claim of complete DDoS protection. Direct signed S3 uploads are bounded separately by size, checksum and expiry and do not pass API middleware.

`Hisaab:Receipts:MonthlyBudgetUsd` now stops **all plans** before a provider attempt would exceed the conservative reserved liability. Set `MaxAttemptCostUsd` to a safe upper bound for the validated model and request limits; the application does not observe the final provider invoice. Failed/time-out attempts retain their liability. Provider enablement, consent, monthly allowances, the emergency stop and circuit breaker remain required. See [receipt operations](receipts.md).

## Phone OTP

Phone routes also receive the general authentication limits above. SMS sends share the following additional durable counters across sign-in, linking, reauthentication and all API instances. Windows align to Unix time; hour/day limits are fixed windows, not rolling allowances. Rejected provider sends retain their reserved allowance.

| Scope | Ceiling |
|---|---:|
| SMS resend cooldown, per phone number | 60 seconds |
| SMS sends, per source IP | 5/10 minutes and 20/day |
| SMS sends, per phone number | 3/hour and 5/day |
| SMS sends, entire environment | 10/minute and 100/day by default |
| Code checks, per phone number across challenges | 10/10 minutes |
| Code checks, per challenge | 5 within its 10-minute lifetime |

Only the global SMS ceilings are configurable: `Hisaab:Auth:Phone:MaxSmsPerMinute` and `MaxSmsPerDay` accept `1`–`10000`; invalid values fail closed. Phone numbers use the keyed identity hash for counters. The cooldown is reserved before provider work, so even a failed send can require waiting before retrying. Twilio can apply tighter limits and destination restrictions. These attempt ceilings do not measure the final SMS invoice; configure provider geography, fraud controls and usage monitoring before enabling delivery. See [phone setup](authentication.md#configure-phone-otp).

Phone admission failures return `429 phone_rate_limited` with `Retry-After` for the rejected local window or cooldown. Provider rate-limit responses use a conservative 60-second retry hint. Waiting does not guarantee admission if another applicable limit remains exhausted.

## Verification and rollout

Run `dotnet test Hisaab.slnx --configuration Release --disable-build-servers`; tests cover independent limiter instances, parallel admission, window reset/TTL, source normalization, header spoofing, invalid auth before work, all AI entry routes, separate accounts, storage failure, paid/free budget boundaries and gateway synthesis.

Publish API and workers for `linux-arm64`, review the CDK diff, then update the existing stack while preserving its configuration-secret parameter. Verify health and bounded invalid authentication/AI requests return 429 with a retry header; do not send live inference merely to load-test limits. Alarm on HTTP errors and observe legitimate-client 429s before raising any ceiling. Update all API/worker code together so paid scans cannot retain the old budget exemption.
