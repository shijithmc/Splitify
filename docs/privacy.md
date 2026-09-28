# Hisaab beta privacy notice

Updated 28 September 2026.

This notice describes the Hisaab TestFlight beta. For privacy questions or help with your data, contact the developer at [shijithmc@icloud.com](mailto:shijithmc@icloud.com).

## Account and shared expenses

Hisaab uses Sign in with Apple or Google. We receive the provider's account identifier, a verified email address when available, and the display name supplied during sign-in. Apple may provide a private relay email address. We use this information to create your Hisaab account, authenticate you, link sign-in methods you choose, and match eligible invitations. Hisaab does not receive your Apple or Google password. Authentication credentials are used to maintain your session; an encrypted Apple refresh credential supports revoking access when you delete your account.

We store the groups, participant names, expenses, amounts, dates, split allocations, balances, recorded payments, invitations, preferences and activity history you create. Optional email addresses or phone numbers entered for invitations are stored separately in encrypted form. Hisaab uses these records to maintain your shared ledger and show changes to group members. It records payments you report; it does not transfer money or require bank login details.

Group members can see the group's shared expense records, participant names, balances and activity. A receipt attached to an expense is also shared with the group. Information that you or another member writes in descriptions or includes in a receipt can therefore be visible to other members.

## Receipts and local storage

Camera and file access let you choose bills to attach to expenses. Images and documents may contain names, addresses, phone numbers or payment details. The app normalizes selected images for upload and removes embedded image metadata. Local receipt drafts and images are encrypted with an account-specific key held in secure device storage. Temporary files used during camera capture or import are separate from these encrypted drafts and are cleaned up after processing; an interrupted app session can leave temporary files for later system cleanup.

Receipt images you submit, manually entered line items and allocations are stored with your account or group. Hisaab no longer provides AI bill scanning or sends receipt images to an AI provider. You enter and review receipt amounts before saving an expense. Previously saved receipts and their reviewed accounting records remain available to authorized group members.

Session credentials and account-specific cached views are kept in secure device storage so you can remain signed in and view previously loaded information. Sign-out clears the app's stored session, personal cache and encrypted receipt drafts on that device.

## Service providers and beta feedback

The beta backend and its account, ledger and uploaded receipt storage run on Amazon Web Services in the Mumbai region. Apple and Google process sign-in requests under their own privacy practices. The backend processes network requests and records operational information such as errors, request correlation identifiers and job outcomes to operate and troubleshoot the service. Database backups can contain earlier copies of stored records.

Advertisements, subscription purchases and push notifications are disabled in this beta. Their controls may still appear in the interface, but these services are unavailable in this build.

Apple operates TestFlight and can provide us with beta usage information, crash reports and feedback you submit, including screenshots. See [Apple's TestFlight privacy information](https://www.apple.com/legal/privacy/data/en/test-flight/). If you email us, we receive your email address and the contents of your message to respond to your request.

## Deleting your account and shared records

Use Settings → Delete account and reauthenticate with a linked sign-in provider. The request disables the account and queues deletion. Processing removes sign-in links, sessions and private account records, revokes the linked Apple authorization, and schedules private receipt drafts and their uploaded media for removal. Deletion and physical media removal run as background work, so they are not necessarily immediate and can be delayed by service failures.

Shared ledger records remain so other members' balances and history stay consistent. Your group participant name becomes “Deleted user,” and shared receipts lose their uploader account reference. Expense descriptions, accounting breakdowns and attached receipt contents can remain in those shared records. Deleting an account does not erase information another member has copied or retained. A minimal deleted-account record is retained to preserve record relationships. Backups can retain earlier data until those backups expire.

Group members can remove shared receipt images from the receipt view. This removes access to the images and schedules physical deletion; the accounting breakdown remains. Contact [shijithmc@icloud.com](mailto:shijithmc@icloud.com) if you cannot access account deletion or need help with information in a shared record.
