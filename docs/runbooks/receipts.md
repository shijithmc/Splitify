# Manual receipt operations

AI bill scanning was removed on 28 September 2026. No extractor, provider token exchange or AI budget admission is registered. Old scanning flags and provider configuration cannot re-enable it. New scan requests, consent, allowance and retries return `410 ai_scanning_removed`. Existing shared receipts and accounting records remain available.

The mobile app attaches photos and accepts manually entered amounts and items. Legacy encrypted drafts retain their images and entered review data when converted to manual entry. Queued backend scan jobs become manual drafts without calling a provider; held historical scan reservations are released. `WORK#receipt-scan` remains the durable partition name for compatibility, but its worker only validates images and performs retention cleanup.

Development uses a local worker and AES-GCM files below `.local/receipts`; keep the generated local encryption key with those files. Hosted environments retain the private S3 bucket, SQS queue and receipt Lambda because manual attachments and existing receipt retention depend on them. Upload/download quotas and API rate limits remain enforced. Worker errors, queue age and dead-letter alarms remain; obsolete AI budget/circuit alarms have been removed.

Publish and deploy API and workers together. Verify old scan submissions return 410, manual upload → validation → review → save works, historical receipt media remains authorized, and queued legacy work cannot invoke a provider. Do not restore a pre-removal worker build when rolling back unrelated changes. No AI-specific project/IAM credentials are needed; Google/Apple sign-in credentials remain separate and must be preserved.

## Access and deletion

Uploads are five-minute signed PUT grants binding content type, length and SHA-256. Untrusted originals land in quarantine. The worker decodes and re-encodes JPEGs, strips metadata and produces thumbnails before exposure. Quarantine has a one-day lifecycle backstop. No signed S3 GET URL is returned. Per-account downloads reserve at most 300 MiB per conservative rolling hour and 60 chunks per UTC minute, including failed reads. Ten-minute image tickets remain bound to account and session; every ≤1 MiB media request rechecks active membership and attachment state. A copied ticket alone does not grant access.

Receipt removal immediately hides media and retains a purge tombstone. Physical deletion runs after ten minutes to cover still-valid PUT grants and in-flight validators. Initial orphan uploads expire after 24 hours; validated private drafts expire after seven days. Historical non-bill images retain their scheduled purge; historical unreadable drafts retain their existing deadline so manual attachment remains possible. New uploads are not classified by AI. Expense deletion hides media immediately and retains it through the 30-day restore window. Account deletion anonymizes shared uploaders, cancels private jobs and purges private parsed pages/media. Purge enumerates object versions, including delete markers. These are scheduled targets; operational outages can delay physical deletion, so monitor queues and run deletion/restore drills.

S3 is private, TLS-only, encrypted and retained on stack deletion; deleting the stack does not fulfill retention obligations. No media replication or backups are configured. If restoring database backups, apply deletion tombstones before opening receipt access. Do not remove the retained bucket until an authorized retention/migration procedure has completed.

## Support and acceptance

Audited `lookup-receipt` returns bounded state and error metadata only; see [support commands](../../tools/Hisaab.Support/README.md). AI pause/resume commands and the extraction evaluation tool no longer exist. Historical extraction metadata remains readable for old receipts and is not generated for new attachments.

Production IAM/load/deletion drills and physical-device camera/crop/HEIC/PDF/accessibility checks remain relevant for manual attachments. Do not log receipt content, image bytes or signed upload URLs.
