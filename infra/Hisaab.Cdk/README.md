# Hisaab infrastructure

This CDK application synthesizes an HTTP API and three .NET 10 ARM64 Lambda functions using the real API and worker projects. It also defines a retained on-demand DynamoDB table with point-in-time recovery, three SQS work queues with dead-letter queues, a worker-failure queue, filtered DynamoDB stream wakeups, scheduled maintenance, bounded log retention and CloudWatch alarms. No deployment occurs during build, tests or synthesis.

Run from the repository root:

```sh
dotnet publish src/Hisaab.Api/Hisaab.Api.csproj -c Release -r linux-arm64 --self-contained false -o artifacts/api
dotnet publish src/Hisaab.Workers/Hisaab.Workers.csproj -c Release -r linux-arm64 --self-contained false -o artifacts/workers
dotnet run --project infra/Hisaab.Cdk/Hisaab.Cdk.csproj
dotnet test tests/Hisaab.Infrastructure.Tests/Hisaab.Infrastructure.Tests.csproj
```

For CDK CLI use `--app "dotnet run --project infra/Hisaab.Cdk/Hisaab.Cdk.csproj"`. Context keys `environment` (`dev`, `staging`, `prod`), `apiAsset`, and `workerAsset` customize the stack name and asset locations. Publish both real projects before synthesizing deployable assets. The executable refuses to synthesize when a Lambda's assembly, dependency manifest or runtime configuration is missing. The worker class-library project explicitly generates `Hisaab.Workers.runtimeconfig.json`. The synthesis policy test uses an isolated synthetic asset only for template assertions.

`ConfigurationSecretArn` is an optional CloudFormation parameter naming an existing Secrets Manager JSON secret. Its values use flattened configuration paths (for example, `Hisaab:RevenueCat:SecretKey`). The functions receive `Hisaab__SecretsArn`; a conditional IAM policy grants access to that exact secret only. This stack generates no provider credentials. A customer-managed KMS key on the configuration secret additionally requires a reviewed `kms:Decrypt` permission for that key before deployment.

All Lambda environments use `ASPNETCORE_ENVIRONMENT=Production`, disable development authentication, and receive the table name and queue URLs. Fill provider, billing, push, legal and other launch configuration before a deployment. CloudWatch alarms are created without notification destinations; attach the approved operations destination before launch.

The HTTP API retains its default throttle of 50 requests/second with a burst of 100. Receipt upload creation (`POST /v1/groups/{groupId}/receipts`), completion (`POST /v1/receipts/{id}/complete`), and retry (`POST /v1/receipts/{id}/retry`) each have an explicit route using the existing API Lambda integration, with a lower throttle of 5 requests/second and a burst of 10. These limits are shared by all callers of each route; the application also applies shared per-account limits across the AI entry routes. Gateway throttles are best-effort targets, not guaranteed spending ceilings. Application receipt quotas and the reserved scan budget remain necessary cost controls. See [AWS HTTP API throttling](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-throttling.html).

The HTTP API server-error alarm measures `AWS/ApiGateway` `5xx / Count × 100` for the API and `$default` stage, using five-minute sums. It breaches at 0.5% or higher, so application-returned HTTP failures are covered even when Lambda invocations complete normally. Zero/missing traffic is non-breaching. Lambda invocation-error and worker/DLQ alarms remain separate signals. [AWS HTTP API metrics](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-metrics.html)

The worker accepts DynamoDB stream, SQS and scheduled event envelopes. A failure retries the entire SQS batch; work processing must remain idempotent through durable rows. Stream wakeups are restricted to inserts/modifications of `OUTBOX` and `WORK#billing` partitions. Maintenance events use `outbox-dispatch` every minute, `billing-reconcile` and `account-deletion` hourly, and `ledger-reconcile` daily. Scheduled runs repair missed stream notifications.

The table uses `PK`, `SK`, numeric `Version`, JSON-string `Data`, and optional numeric `ExpiresAt` (Unix seconds) for TTL. IAM grants strongly consistent Get/Query and conditional transaction Put/Delete/ConditionCheck operations on that table; no table Scan permission is granted. HTTP idempotency must be stored as a transaction row, since DynamoDB transport request tokens expire after ten minutes.

The durable JSON adapter is for single-process local development. It serializes transactions under a per-path semaphore, checks every expected version before changing state, and writes through a temporary file followed by an atomic replacement. Use DynamoDB for multiple processes or hosted deployments. Pagination cursors are bound to the partition and prefix; callers must still authorize the requested partition. The adapter validates 100 distinct actions, 400 KiB item size and 4 MiB transaction size, including existing rows deleted or independently conditioned.

The test suite verifies storage rollback, concurrent optimistic writes, idempotency rows, durable restart, limits, cursor isolation, AWS request construction and synthesized policies. It does not claim a live DynamoDB integration test, deployed IAM validation, real push delivery, provider/store verification, or load-tested SLOs. AWS deployment, billing accounts, alert routing and release gates remain operator work.

Receipt media uses a private TLS-only encrypted retained S3 bucket. A dedicated 1536 MiB receipt Lambda has reserved concurrency four and consumes one-message SQS batches with maximum concurrency two. WORK#receipt-scan stream events dispatch due-time-aware wakeups, and one-minute maintenance repairs interrupted work and purges media. The API grants signed PUTs to quarantine and serves authorized image chunks; only the receipt worker normalizes and deletes media. Receipt logs use TEXT explicitly for CloudWatch EMF aggregate budget/circuit metrics. See [receipt operations](../../docs/runbooks/receipts.md) for WIF, model validation, budget, retention and release gates.
