package app.hisaab.hisaab

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.pdf.LoadParams
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Telephony
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal class SpendingNative(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val store = SpendingSmsStore(activity)
    private var permissionResult: MethodChannel.Result? = null
    private var permissionOwner: String? = null
    private var permissionGeneration: Long = 0
    @Volatile private var importing = false
    private val permissions = arrayOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS)
    private fun granted() = permissions.all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setOwner" -> {
                val owner = call.argument<String>("owner")
                if (owner != null && !Regex("^[a-f0-9]{64}$").matches(owner)) {
                    result.error("invalid_owner", "Sign in again to connect bank SMS.", null); return
                }
                store.setOwner(owner); result.success(store.generation)
            }
            "smsEnabled" -> result.success(store.enabled && granted())
            "disableSms", "clearImportedData" -> {
                if (!matchesOwner(call)) { result.error("sms_owner_changed", "Your account changed. Try again from your current account.", null); return }
                store.clear(); result.success(store.generation)
            }
            "acknowledgeSms" -> {
                val owner = call.argument<String>("owner")
                if (owner != store.owner || !matchesOwner(call)) { result.success(null); return }
                val ids = call.argument<List<String>>("ids") ?: emptyList()
                try { store.acknowledge(ids.toSet()); result.success(null) }
                catch (_: Exception) { result.error("sms_storage_failed", "Could not finish saving imported transactions. Try again.", null) }
            }
            "importSms" -> {
                if (!matchesOwner(call)) { result.error("sms_owner_changed", "Your account changed. Connect SMS again from your current account.", null); return }
                if (call.argument<Boolean>("requestPermission") == true) {
                    if (store.owner == null) { result.error("sms_sign_in", "Sign in before connecting bank SMS.", null); return }
                    if (permissionResult != null || importing) { result.error("sms_busy", "A bank SMS import is already running.", null); return }
                    if (!granted()) {
                        permissionResult = result; permissionOwner = store.owner; permissionGeneration = store.generation
                        activity.requestPermissions(permissions, REQUEST_SMS)
                    } else { store.enable(); importInbox(result) }
                } else if (!store.enabled || !granted()) {
                    result.success(mapOf("transactions" to emptyList<Any>(), "unrecognizedCount" to 0, "truncated" to false))
                } else { importInbox(result) }
            }
            "pdfText" -> {
                val path = call.argument<String>("path") ?: ""
                val password = call.argument<String>("password")
                Thread {
                    try {
                        val text = readPdf(File(path), password)
                        activity.runOnUiThread { result.success(text) }
                    } catch (_: SecurityException) {
                        activity.runOnUiThread { result.error("pdf_password", "This PDF needs the correct statement password.", null) }
                    } catch (error: UnsupportedOperationException) {
                        activity.runOnUiThread { result.error("pdf_unsupported", error.message, null) }
                    } catch (_: Exception) {
                        activity.runOnUiThread { result.error("pdf_unreadable", "Choose a readable text PDF below 20 MB and 200 pages, or import a CSV statement.", null) }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun matchesOwner(call: MethodCall): Boolean = call.argument<String>("owner") == store.owner &&
        call.argument<Number>("generation")?.toLong() == store.generation

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_SMS) return false
        val result = permissionResult ?: return true
        val sameOwner = permissionOwner != null && permissionOwner == store.owner && permissionGeneration == store.generation
        permissionResult = null; permissionOwner = null
        if (!sameOwner) { result.error("sms_owner_changed", "Your account changed. Connect SMS again from your current account.", null); return true }
        if (!granted()) { result.error("sms_permission_denied", "SMS access was not granted. Import a statement or add spending manually.", null); return true }
        store.enable(); importInbox(result)
        return true
    }

    private fun importInbox(result: MethodChannel.Result) {
        if (importing) { result.error("sms_busy", "A bank SMS import is already running.", null); return }
        importing = true
        val owner = store.owner
        val generation = store.generation
        val checkpoint = store.checkpoint
        val checkpointId = store.checkpointId
        Thread {
            try {
                // Deliver a full queue first so an unread backlog cannot prevent
                // ACK and permanently block subsequent bounded inbox scans.
                val queued = synchronized(SpendingSmsStore.lock) {
                    if (store.owner == owner && store.generation == generation && store.enabled) store.result() else null
                }
                if (queued != null && (queued["transactions"] as List<*>).size >= 1000) {
                    activity.runOnUiThread { importing = false; result.success(queued + ("truncated" to true)) }
                    return@Thread
                }
                val cutoff = maxOf(checkpoint, System.currentTimeMillis() - 90L * 24 * 60 * 60 * 1000)
                val rows = mutableListOf<Map<String, Any>>()
                val unknown = mutableListOf<String>()
                var latest = checkpoint
                var latestId = checkpointId
                var readCount = 0
                var truncated = false
                val capacity = 5000 - ((queued?.get("transactions") as? List<*>)?.size ?: 0)
                activity.contentResolver.query(Telephony.Sms.Inbox.CONTENT_URI,
                    arrayOf("_id", "address", "date", "body", "date_sent"),
                    "date > ? OR (date = ? AND _id > ?)",
                    arrayOf(cutoff.toString(), cutoff.toString(), if (cutoff == checkpoint) checkpointId.toString() else "0"),
                    "date ASC, _id ASC")?.use { cursor ->
                    while (cursor.moveToNext()) {
                        if (readCount++ >= 5000 || rows.size >= capacity) { truncated = true; break }
                        latestId = cursor.getLong(0); latest = cursor.getLong(2)
                        val sender = cursor.getString(1) ?: continue
                        if (SpendingSmsParser.bank(sender) == null) continue
                        val body = cursor.getString(3) ?: continue
                        val sentAt = if (cursor.isNull(4)) null else cursor.getLong(4)
                        val transactionDate = SpendingSmsParser.inboxTimestamp(sentAt, latest)
                        val row = SpendingSmsParser.parse(body, sender, transactionDate)
                        if (row != null) rows.add(row)
                        else if (SpendingSmsParser.eligible(body, sender)) unknown.add(SpendingSmsParser.hash("$sender|$transactionDate"))
                    }
                }
                val response = synchronized(SpendingSmsStore.lock) {
                    check(store.owner == owner && store.generation == generation && store.enabled) { "owner_changed" }
                    store.append(rows, unknown)
                    // Checkpoint advances only after encrypted queue commit succeeds.
                    store.setCheckpoint(latest, latestId)
                    store.result(truncated)
                }
                activity.runOnUiThread { importing = false; result.success(response) }
            } catch (_: SecurityException) {
                activity.runOnUiThread { importing = false; result.error("sms_permission_denied", "Allow SMS access, or use a statement instead.", null) }
            } catch (_: Exception) {
                activity.runOnUiThread { importing = false; result.error("sms_import_failed", "Could not import bank SMS. Your saved transactions are unchanged. Try again or use a statement.", null) }
            }
        }.start()
    }

    private fun readPdf(file: File, password: String?): String {
        if (Build.VERSION.SDK_INT < 35) throw UnsupportedOperationException("PDF text import needs Android 15 or later. On this phone, export a CSV statement or add transactions manually.")
        require(file.isFile && file.length() <= 20L * 1024 * 1024)
        val params = LoadParams.Builder().apply { if (!password.isNullOrEmpty()) setPassword(password) }.build()
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor, params).use { pdf ->
                require(pdf.pageCount in 1..200)
                val text = StringBuilder()
                for (index in 0 until pdf.pageCount) {
                    pdf.openPage(index).use { page ->
                        for (content in page.textContents) {
                            text.append(content.text).append('\n')
                            require(text.length <= 2 * 1024 * 1024)
                        }
                    }
                }
                require(text.isNotBlank())
                return text.toString()
            }
        }
    }
    companion object { const val REQUEST_SMS = 7314 }
}
