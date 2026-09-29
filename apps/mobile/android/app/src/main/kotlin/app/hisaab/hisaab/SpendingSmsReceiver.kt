package app.hisaab.hisaab

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

class SpendingSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val store = SpendingSmsStore(context)
        if (!store.enabled) return
        val activeOwner = store.owner
        val activeGeneration = store.generation
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) return
        val sender = messages.first().displayOriginatingAddress ?: return
        if (messages.any { it.displayOriginatingAddress != sender }) return
        if (SpendingSmsParser.bank(sender) == null) return
        // Multipart content exists only in memory for parsing and is never logged.
        val body = SpendingSmsParser.combineMultipart(messages.map { it.displayMessageBody })
        val date = messages.first().timestampMillis
        // With no sent timestamp, wait for the provider's stable receipt date
        // on foreground import; a guessed clock value would create duplicates.
        if (date <= 0) return
        val row = SpendingSmsParser.parse(body, sender, date)
        if (row == null && !SpendingSmsParser.eligible(body, sender)) return
        val pending = goAsync()
        Thread {
            try {
                synchronized(SpendingSmsStore.lock) {
                    if (store.owner == activeOwner && store.generation == activeGeneration && store.enabled) {
                        store.append(if (row == null) emptyList() else listOf(row),
                            if (row == null) listOf(SpendingSmsParser.hash("$sender|$date")) else emptyList())
                    }
                }
            } catch (_: Exception) {
                // Inbox delta import retries on the next foreground launch. No
                // personal data or exception body is written to diagnostics.
            } finally { pending.finish() }
        }.start()
    }
}
