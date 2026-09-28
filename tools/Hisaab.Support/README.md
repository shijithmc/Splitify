# Support CLI

The CLI uses the standard AWS credential chain and the selected region. Run it with an approved operator IAM role, without credentials in command arguments or source.

```sh
dotnet run --project tools/Hisaab.Support -- lookup TABLE USER_UUID
dotnet run --project tools/Hisaab.Support -- lookup-transaction TABLE APP_STORE TRANSACTION_ID
dotnet run --project tools/Hisaab.Support -- lookup-transaction TABLE PLAY_STORE TRANSACTION_ID
dotnet run --project tools/Hisaab.Support -- grant TABLE USER_UUID 24 "Verified purchase awaiting provider repair" OPERATOR --confirm
dotnet run --project tools/Hisaab.Support -- revoke TABLE USER_UUID "Provider verification restored" OPERATOR --confirm
```

`lookup-transaction` hashes the exact supplied transaction ID using SHA-256 and reads `STORE#STORE#hash / OWNER`. Store names are case-insensitive at the command line and normalize to RevenueCat's `APP_STORE` or `PLAY_STORE` values. Both current and original transaction IDs can resolve when an authenticated webhook has indexed them. A missing row may mean the wrong store/environment or an unprocessed webhook; it does not establish that the customer never purchased.

The transaction result is the first recorded webhook attribution. It can be stale after an account transfer and does not prove current entitlement or authorize changing ownership. Confirm the intended account in RevenueCat, then inspect the returned account status, verified entitlement and support override. The command prints no raw transaction ID and never automatically grants access. Audit history is the oldest-first initial page, with a continuation cursor when more exists; the entitlement's verification timestamp is the current snapshot.

Read-only lookups require `dynamodb:GetItem` and `dynamodb:Query` on the chosen table, with any leading-key restrictions covering both `STORE#...` and the resolved `USER#...` partition. Grant/revoke additionally require conditional table writes and the separately approved support authorization. Grants expire in 1–168 hours and every mutation records a reason and operator identifier. The supplied operator text is an audit annotation, not a replacement for AWS IAM/CloudTrail identity.

Do not paste lookup output into public tickets. Transaction IDs supplied as arguments can remain in shell history; follow the support team's approved handling policy. No provider secrets or payment credentials are needed for these lookups. See [the support runbook](../../docs/runbooks/support.md) for the paid-but-still-seeing-ads workflow and release prerequisites.

Receipt support commands:

```sh
dotnet run --project tools/Hisaab.Support -- lookup-receipt TABLE RECEIPT_UUID INC-123 OPERATOR
```

Every receipt lookup, including a miss, writes an audit entry with the ticket/operator. Output includes only state, attempt count, sanitized error code, legacy quota/lease flags, retention flags and timestamps. It excludes account/group IDs, merchant/items, blob keys, URLs and image bytes. Existing receipts remain available for troubleshooting after AI scanning is removed.

AI evaluation and runtime scan controls have been removed. Receipt lookup cannot requeue work or change receipt state.

Receipt lookup needs `dynamodb:GetItem` scoped to `RECEIPT#*` and transactional writes scoped to `SUPPORT_AUDIT`. The role needs no S3, receipt revision-page queries, user profiles or ledger writes. Restrict the exact table ARN and enforce operator identity through IAM/CloudTrail; the CLI's operator text is only an annotation. Audit access itself is a write and must not be represented as an unaudited read-only tool.
