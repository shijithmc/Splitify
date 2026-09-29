# Personal spending in HiSaab

Personal spending opens from the **Your spending** card on Home or from Account.
Home, Groups, Activity and Account keep their existing roles. The new pages use
the approved cream/terracotta/sage visual design and bundled wallet artwork.

## Working flows

- Private overview, searchable transactions, category budgets, payday settings,
  cash entry, category corrections that apply to future imports, and exclusion
  of transfers or other non-spending records.
- **Daily budget** is remaining monthly category caps divided by days until the
  selected payday. It is a budget estimate, not a bank balance or a guarantee of
  available cash. Unpaid bills and money awaiting reimbursement are not added.
- Opt-in Android bank SMS import, with a 90-day initial scan and bounded delta
  scans. A native SMS receiver captures supported messages while Flutter is not
  running. Permission rejection keeps statements and manual entry available.
- CSV import and text PDF import with a selection/review step. Passwords are
  used in memory only. iOS uses PDFKit; Android PDF text extraction requires
  Android 15+. Older Android devices can import CSV.
- **Add to a group** previews the title, amount, date, payer and equal split.
  Sharing uses existing authenticated group endpoints. Bank account details,
  reference numbers, source metadata and personal category rules stay private.
- **Link existing expense** selects an expense paid by the user with the same
  total. It changes the private budget, without creating another group expense.
- CSV export and explicit private-data deletion are available without a plan.

## Storage and accounting

Personal transactions, rules, budgets and pending sharing commands use an
account-specific AES-256-GCM file with an independent key in Keychain/Keystore.
Writes are serialized and replaced atomically; ciphertext is bound to the
account hash with authenticated additional data. Sign-out closes the store and
clears its in-memory state. Account deletion erases it, including pending shares.

This initial feature does **not** synchronize the private ledger to the server.
The UI explains this and offers a CSV spreadsheet record before switching devices.
CSV export is not a restorable backup of budgets, rules or group links. Raw SMS,
statements and statement passwords are not uploaded. The Android receiver stores
only parsed fields in an encrypted, owner-bound queue; Dart acknowledges records
only after its encrypted ledger commit. Signing out or changing owner disables
capture. Enabling capture on another account requires explicit consent again.

Money uses integer paise. A linked ₹1,260 debit split between three people stays
a ₹1,260 bank movement; the category budget counts the user's ₹420 share. The
other ₹840 is not available cash. Reimbursements are credit/transfer records,
not another reduction in category spending. Explicit own-account transfers and
ATM withdrawals are excluded; ordinary person-to-person payments still count
unless the user excludes them. Unknown categories use Other.

Refunds require review before reducing a budget. The user confirms the personal
portion, from zero to the bank refund total. For example, a ₹1,260 refund for
that shared purchase reduces personal spending by ₹420 after review, avoiding
a ₹1,260 reduction for a purchase that counted only ₹420.

A durable expense UUID is saved before sharing. After an interrupted request,
HiSaab checks that exact expense before retrying. Duplicate group links are
rejected. Linked records refresh when their page opens, the app resumes, or a
group changes. If the expense was deleted, became inaccessible, or changed payer
or total, its original debit counts and a review warning appears. Reinstating a
valid link restores the current user share.

## Supported import formats and limits

CSV supports `Date,Description,Amount,Type` or `Date,Description,Debit,Credit`.
Dates are `yyyy-MM-dd` or `dd/MM/yyyy`; Type is debit, credit, refund or transfer;
amounts are INR. Maximum 2 MB and 5,000 rows. Exported spreadsheet cells escape
formula prefixes. Optional Bank, Account and Reference columns improve matching
against SMS imports. Complete matching bank/account/reference identifiers enable
cross-source duplicate detection; statements without them require review for
overlap with previously imported SMS.

PDF/text statements currently require explicit dated rows with a direction, for
example `20/09/2026 Coffee 120.00 DR`. Scanned PDFs and bank layouts without
unambiguous directions fail with CSV/manual guidance. Mixed unreadable dated
rows are rejected instead of silently importing a partial statement. PDF limits
are 20 MB / 200 pages. Not every bank's PDF layout is supported.

The English SMS parser recognizes sender aliases for SBI, HDFC, ICICI, Axis,
Kotak, PNB, Bank of Baroda, Canara, Union, IDFC First, Yes, IndusInd, AU, Federal
and legacy Paytm Payments Bank alerts. OTPs, personal senders and unsuccessful,
pending or scheduled payments are rejected. Unrecognized financial messages
contribute only a count; users can supply a statement or enter the transaction.
Tests use synthetic templates, not a validated production bank corpus. Neither
97% bank-wide coverage nor 85% categorization accuracy has been demonstrated.

## Release prerequisites and later scope

Google Play approval for READ_SMS/RECEIVE_SMS and the permissions declaration are
required before distributing SMS-enabled builds. Review the disclosure, privacy
policy and store data declarations against the actual local-only data flow.
Background delivery depends on Android permissions, force-stop state and device
power restrictions; a universal 60-second SLA is not claimed.

The broader product brief's cloud restore, Account Aggregator connection,
recurring-payment detection, scheduled budget push alerts, subscription trial,
new spending paywall, couples budgets and freelancer modes are separate work.
This change implements the approved spending and group-sharing feature. It does
not change HiSaab's existing ad-free entitlement or deploy infrastructure.

## Validation

Run `flutter analyze` and `flutter test` from `apps/mobile`. Focused tests cover
encrypted storage, identity boundaries, amount calculations, idempotency,
statement/SMS parsing, sharing payload privacy, account switches, retries and
320dp layouts at 200% text. Native Kotlin parser fixtures run with
`./gradlew :app:testDebugUnitTest` from `apps/mobile/android`; iOS simulator and
Android builds validate their platform channels.
