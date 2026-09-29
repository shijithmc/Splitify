package app.hisaab.hisaab

import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Deliberately conservative English templates. Never returns the source body. */
internal object SpendingSmsParser {
    // The receiver gets the SMSC timestamp; inbox DATE_SENT carries that same
    // value. DATE is receipt time and must remain only the scan checkpoint.
    fun inboxTimestamp(sentAt: Long?, receivedAt: Long): Long =
        sentAt?.takeIf { it > 0 } ?: receivedAt

    // Match the default Android messaging provider's PDU-body normalization.
    // Do not insert a separator: multipart PDUs can split one word in half.
    fun combineMultipart(parts: List<String?>): String =
        parts.joinToString("") { it ?: "" }.replace('\u000C', '\n')

    private val banks = linkedMapOf(
        "SBI" to listOf("SBI", "SBIINB"), "HDFC" to listOf("HDFC", "HDFCBK"),
        "ICICI" to listOf("ICICI", "ICICIB"), "Axis" to listOf("AXIS", "AXISBK"),
        "Kotak" to listOf("KOTAK", "KOTAKB"), "PNB" to listOf("PNB", "PNBSMS"),
        "Bank of Baroda" to listOf("BOB", "BOBTXN", "BARODA"), "Canara" to listOf("CANARA", "CANBNK"),
        "Union Bank" to listOf("UNION", "UBI", "UNIONB"), "IDFC First" to listOf("IDFC", "IDFCFB"),
        "Yes Bank" to listOf("YESBNK", "YESBANK"), "IndusInd" to listOf("INDUSB", "INDUSIND"),
        "AU Bank" to listOf("AUBANK", "AUSFBL"), "Federal" to listOf("FEDERAL", "FEDBNK"),
        "Paytm Payments Bank" to listOf("PAYTMB", "PYTMBK")
    )
    private fun regex(pattern: String) = Regex(pattern, RegexOption.IGNORE_CASE)
    private val rejected = regex("\\b(otp|one[ -]?time|verification code|failed|declined|pending|unsuccessful|request|requested|due|minimum due|will be debited|scheduled)\\b")
    private val money = regex("(?:INR|Rs\\.?|₹)\\s*([0-9][0-9,]*(?:\\.[0-9]{1,2})?)(?![0-9]|\\.[0-9])")
    private val debit = regex("\\b(debited|spent|paid|withdrawn|transferred|purchase(?:d)?)\\b")
    private val credit = regex("\\b(credited|received|deposited)\\b")
    private val refund = regex("\\b(refund(?:ed)?|revers(?:ed|al))\\b")
    private val account = regex("(?:a/c|ac(?:ct)?|account|card)\\s*(?:no\\.?\\s*)?[:.*\\sXx-]*([0-9]{4,18})\\b")
    private val reference = regex("(?:UPI\\s*(?:Ref(?:erence)?\\s*(?:No\\.?)?|Ref)|Ref(?:erence)?\\s*(?:No\\.?)?|UTR|RRN)\\s*[:.#-]?\\s*([A-Za-z0-9]{6,30})\\b")
    private val merchant = regex("\\b(?:at|to|from)\\s+(?!(?:a/c|ac(?:ct)?|account|card)(?=[\\sXx*\\d.:_-]|$)|your\\b)([A-Za-z][A-Za-z0-9 &._@/-]{1,80}?)(?=\\s+(?:on|via|using|UPI|Ref|Avl|Bal|a/c|account|card|for)\\b|[.;]|$)")
    fun bank(sender: String): String? {
        val parts = sender.uppercase(Locale.ROOT).split('-')
        val id = if (parts.size > 1 && Regex("^[PSTG]$").matches(parts.last())) parts[parts.size - 2] else parts.last()
        return banks.entries.firstOrNull { it.value.contains(id) }?.key
    }
    fun eligible(body: String, sender: String): Boolean = bank(sender) != null && body.length <= 4000 &&
        !rejected.containsMatchIn(body) && money.containsMatchIn(body) &&
        (debit.containsMatchIn(body) || credit.containsMatchIn(body) || refund.containsMatchIn(body) || regex("\\b(dr|cr|transaction)\\b").containsMatchIn(body))
    private fun category(title: String): String = when {
        regex("swiggy|zomato|restaurant|cafe|coffee|pizza|food").containsMatchIn(title) -> "Food & cafés"
        regex("bigbasket|blinkit|zepto|grocery|groceries|supermarket").containsMatchIn(title) -> "Groceries"
        regex("uber|ola\\b|metro|irctc|petrol|fuel|rapido").containsMatchIn(title) -> "Travel"
        regex("netflix|spotify|prime video|hotstar|youtube").containsMatchIn(title) -> "Bills"
        regex("jio\\b|airtel|electric|broadband|utility|water bill").containsMatchIn(title) -> "Bills"
        regex("amazon|flipkart|myntra|shopping").containsMatchIn(title) -> "Shopping"
        regex("pharmacy|hospital|medical|clinic|apollo").containsMatchIn(title) -> "Health"
        regex("\\brent\\b").containsMatchIn(title) -> "Bills"
        else -> "Other"
    }
    private fun safeTitle(title: String): String {
        val text = title.replace(Regex("[\\x00-\\x1f\\x7f]"), " ")
            .replace(Regex("\\d{8,}"), "••••").replace(Regex("\\s+"), " ").trim().take(80)
        return if (Regex("^[=+@-]").containsMatchIn(text)) "'$text" else text
    }
    fun parse(body: String, sender: String, timestamp: Long): Map<String, Any>? {
        val bank = bank(sender) ?: return null
        if (!eligible(body, sender)) return null
        val isDebit = debit.containsMatchIn(body)
        val isCredit = credit.containsMatchIn(body)
        val isRefund = refund.containsMatchIn(body)
        if ((!isDebit && !isCredit && !isRefund) || (isDebit && isCredit && !isRefund)) return null
        val amountMatch = money.find(body) ?: return null
        if (regex("(?:bal(?:ance)?|available|limit)\\s*[:.-]?\\s*$").containsMatchIn(body.substring(0, amountMatch.range.first))) return null
        val amountText = amountMatch.groupValues[1].replace(",", "")
        val pieces = amountText.split('.')
        val rupees = pieces[0].toLongOrNull() ?: return null
        if (rupees > 10_000_000) return null
        val amount = rupees * 100 + if (pieces.size > 1) pieces[1].padEnd(2, '0').toLong() else 0L
        if (amount <= 0 || amount > 1_000_000_000) return null
        val last4 = account.find(body)?.groupValues?.get(1)?.takeLast(4)
        val ref = reference.find(body)?.groupValues?.get(1)
        val name = merchant.find(body)?.groupValues?.get(1)?.trim()
        var kind = if (isRefund) "refund" else if (isCredit) "credit" else "debit"
        val own = regex("\\b(?:self transfer|own account|cash withdrawal|ATM)\\b").containsMatchIn(body)
        val p2p = isDebit && name != null && category(name) == "Other" && regex("\\bUPI\\b").containsMatchIn(body) && regex("\\b(?:transferred|P2P|person.to.person)\\b").containsMatchIn(body)
        if (!isRefund && own) kind = "transfer"
        val title = safeTitle(if (name == null) { if (isRefund) "Refund" else if (isCredit) "Money received" else "Bank payment" }
            else if (p2p && !own) "Transfer to $name" else name)
        val key = title.lowercase(Locale.ROOT).replace(Regex("[^a-z0-9]+"), " ").trim()
        val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        dateFormat.timeZone = TimeZone.getTimeZone("UTC")
        val date = dateFormat.format(Date(timestamp))
        val identity = if (ref != null) "$bank|$last4|$ref|$amount|$kind" else "$date|$last4|$amount|$kind|$key"
        return mutableMapOf<String, Any>("title" to title, "amountPaise" to amount, "date" to date, "kind" to kind,
            "source" to "SMS", "bank" to bank, "category" to (if (kind == "transfer" || kind == "credit") "Other" else category(title)),
            "merchantKey" to key, "importId" to hash(identity)).apply {
            if (last4 != null) put("accountLast4", last4)
            if (ref != null) put("reference", ref)
        }
    }
    fun hash(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}
