# Hisaab beta privacy notice

Updated 28 September 2026.

This notice describes the Hisaab TestFlight beta. For privacy questions or help with your data, contact the developer at [shijithmc@icloud.com](mailto:shijithmc@icloud.com).

## Account and shared expenses

Hisaab supports Sign in with Apple, Google or a phone number verified by an SMS code when SMS delivery is enabled. For Apple and Google, we receive the provider's account identifier, a verified email address when available, and the display name supplied during sign-in. Apple may provide a private relay email address. We use this information to create your Hisaab account, authenticate you, link sign-in methods you choose, and match eligible invitations. Hisaab does not receive your Apple or Google password. Authentication credentials are used to maintain your session; an encrypted Apple refresh credential supports revoking access when you delete your account.

If you choose phone sign-in, Hisaab processes the number you enter, the verification code and verification results. Our backend sends your number to Twilio Verify to deliver an SMS and submits the code you enter for verification. Verification challenges store the number encrypted and expire after ten minutes; expired records are removed through background database cleanup. Hisaab does not store the SMS code. We retain a keyed phone sign-in identifier to recognize your account when you return. Phone login does not automatically match invitations or merge accounts. You can choose Apple or Google without requesting a phone code.

We store the groups, participant names, expenses, amounts, dates, split allocations, balances, recorded payments, invitations, preferences and activity history you create. Optional email addresses or phone numbers entered for invitations are stored separately in encrypted form. Hisaab uses these records to maintain your shared ledger and show changes to group members. It records payments you report; it does not transfer money or require bank login details.

Group members can see the group's shared expense records, participant names, balances and activity. A receipt attached to an expense is also shared with the group. Information that you or another member writes in descriptions or includes in a receipt can therefore be visible to other members.

## Receipts and local storage

Camera and file access let you choose bills to attach to expenses. Images and documents may contain names, addresses, phone numbers or payment details. The app normalizes selected images for upload and removes embedded image metadata. Local receipt drafts and images are encrypted with an account-specific key held in secure device storage. Temporary files used during camera capture or import are separate from these encrypted drafts and are cleaned up after processing; an interrupted app session can leave temporary files for later system cleanup.

Receipt images you submit, reviewed line items and allocations are stored with your account or group. AI scanning depends on service availability. Before using it, the app asks you to allow Google AI to process bill images to extract items and totals. Manual entry is available without AI processing. If you choose AI scanning, images are sent to Google's Vertex AI service through its Mumbai region. The app requires you to review the result before saving an expense.

Session credentials and account-specific cached views are kept in secure device storage so you can remain signed in and view previously loaded information. Sign-out clears the app's stored session, personal cache and encrypted receipt drafts on that device.

## Service providers and beta feedback

The beta backend and its account, ledger and uploaded receipt storage run on Amazon Web Services in the Mumbai region. Apple and Google process sign-in requests under their own privacy practices. When you request a phone code, Twilio and the mobile carriers involved process your number, verification messages and delivery information to provide SMS verification and prevent abuse. That processing is not limited by the location of Hisaab's AWS storage. See [Twilio's privacy notice](https://www.twilio.com/en-us/legal/privacy). The backend processes network requests and records operational information such as errors, request correlation identifiers and job outcomes to operate and troubleshoot the service. Database backups can contain earlier copies of stored records.

Advertisements, subscription purchases and push notifications are disabled in this beta. Their controls may still appear in the interface, but these services are unavailable in this build.

Apple operates TestFlight and can provide us with beta usage information, crash reports and feedback you submit, including screenshots. See [Apple's TestFlight privacy information](https://www.apple.com/legal/privacy/data/en/test-flight/). If you email us, we receive your email address and the contents of your message to respond to your request.

## Deleting your account and shared records

Use Settings → Delete account and reauthenticate with a linked sign-in method, including a new SMS code for a linked phone number. The request disables the account and queues deletion. Processing removes sign-in links, sessions and private account records, revokes the linked Apple authorization, and schedules private receipt drafts and their uploaded media for removal. Deletion and physical media removal run as background work, so they are not necessarily immediate and can be delayed by service failures. Hisaab account deletion does not itself erase delivery or verification records retained by Twilio or mobile carriers under their own policies.

Shared ledger records remain so other members' balances and history stay consistent. Your group participant name becomes “Deleted user,” and shared receipts lose their uploader account reference. Expense descriptions, accounting breakdowns and attached receipt contents can remain in those shared records. Deleting an account does not erase information another member has copied or retained. A minimal deleted-account record is retained to preserve record relationships. Backups can retain earlier data until those backups expire.

Group members can remove shared receipt images from the receipt view. This removes access to the images and schedules physical deletion; the accounting breakdown remains. Contact [shijithmc@icloud.com](mailto:shijithmc@icloud.com) if you cannot access account deletion or need help with information in a shared record.
