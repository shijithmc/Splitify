# API abuse protection

All HTTP requests pass shared admission before session lookup, body binding or endpoint work. Authenticated requests also consume account admission. DynamoDB stores conditional counters, so opening another session, changing receipt IDs/idempotency keys, restarting a Lambda or scaling out does not reset the allowance. Rejections return HTTP 429, `code: rate_limited`, `Retry-After` seconds and `Cache-Control: no-store`.

| Scope | Default ceiling |
|---|---:|
| Every request, per source IP | 600/minute |
| All `/v1/auth` requests combined, per source IP | 30/minute |
| All authenticated requests combined, per account | 240/minute |
| Authenticated `/v1/auth` requests combined, per account | 30/minute |
| Receipt create/complete requests combined, per source IP | 30/minute |
| Receipt create/complete requests combined, per account | 12/minute |

The receipt upload routes are `POST /v1/groups/{groupId}/receipts` and `POST /v1/receipts/{id}/complete`. Admission counts invalid/replayed requests too; idempotency still prevents duplicate work. Receipt polling, review, media and the remaining routes retain general admission plus upload/download byte limits. AI scanning has been removed; legacy AI requests return 410.

Request counters use fixed UTC minute windows. Traffic near a boundary can consume the allowance on both sides. Counter rows use `RATE#<scope>#<SHA256(subject)>`, the minute as sort key, and a short DynamoDB TTL; expiration is enforced by choosing the current window, never by waiting for asynchronous TTL deletion. Each scope is shared across routes. A conditional transaction admits all applicable counters or none. Persistent contention returns 429 with a one-second retry. Store errors fail closed through normal API error handling; no route runs unmetered.

Source identity comes only from `Connection.RemoteIpAddress`. The [AWS HTTP API v2 adapter](https://github.com/aws/aws-lambda-dotnet/blob/master/Libraries/src/Amazon.Lambda.AspNetCoreServer/APIGatewayHttpApiV2ProxyFunction.cs) populates it from API Gateway's trusted request context. Forwarded IP, account and device headers are ignored. IPv4-mapped addresses are normalized; an IPv6 /64 shares an allowance. Missing source addresses share one conservative `unknown` bucket. Shared networks can therefore share an IP allowance. Do not enable arbitrary forwarded-header trust in front of this middleware.

Settings under `Hisaab:RateLimits` are `RequestsPerIpPerMinute`, `AuthRequestsPerIpPerMinute`, `RequestsPerAccountPerMinute`, `AuthRequestsPerAccountPerMinute`, `ReceiptRequestsPerIpPerMinute` and `ReceiptRequestsPerAccountPerMinute`. Each must be 1–10000; invalid settings stop startup instead of disabling enforcement. Keep the same configuration across all API instances. New routes automatically receive general limits; mark receipt upload endpoints with `ReceiptWriteRateLimit`.

The gateway retains 50 requests/second and burst 100 defaults, with 5 requests/second and burst 10 on each receipt upload route. [AWS documents gateway throttling as best effort](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-throttling.html); the application counters and upload/download quotas provide separate enforcement. This is application abuse protection, not a claim of complete DDoS protection. Direct signed S3 uploads are bounded separately by size, checksum and expiry and do not pass API middleware.

## Verification and rollout

Run `dotnet test Hisaab.slnx --configuration Release --disable-build-servers`; tests cover independent limiter instances, parallel admission, window reset/TTL, source normalization, header spoofing, invalid auth before work, both receipt upload routes, separate accounts, storage failure and gateway synthesis.

Publish API and workers for `linux-arm64`, review the CDK diff, then update the existing stack while preserving its configuration-secret parameter. Verify health and bounded invalid authentication/receipt requests return 429 with a retry header. Alarm on HTTP errors and observe legitimate-client 429s before raising any ceiling. Update API and worker code together so legacy queued jobs also stop AI processing.
