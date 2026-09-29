package app.hisaab.hisaab

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** One encrypted queue bound to an explicitly consenting, authenticated owner. */
internal class SpendingSmsStore(context: Context) {
    private val preferences = context.getSharedPreferences("spending_capture", Context.MODE_PRIVATE)
    private val keyAlias = "hisaab_spending_sms_v1"
    val owner: String? get() = preferences.getString("owner", null)
    val generation: Long get() = preferences.getLong("generation", 0)
    val enabled: Boolean get() = owner != null && preferences.getBoolean("enabled", false)
    val checkpoint: Long get() = preferences.getLong("checkpoint", 0)
    val checkpointId: Long get() = preferences.getLong("checkpointId", 0)
    fun setOwner(value: String?) = synchronized(lock) {
        if (owner != value) { clear(); check(preferences.edit().putString("owner", value).commit()) }
    }
    fun enable() = synchronized(lock) {
        require(owner != null) { "Sign in before connecting bank SMS." }
        check(preferences.edit().putBoolean("enabled", true).commit())
    }
    fun clear() = synchronized(lock) {
        check(preferences.edit().remove("queue").remove("unknown").remove("checkpoint").remove("checkpointId")
            .putBoolean("enabled", false).putLong("generation", generation + 1).commit())
    }
    fun setCheckpoint(date: Long, id: Long) = synchronized(lock) {
        check(preferences.edit().putLong("checkpoint", date).putLong("checkpointId", id).commit())
    }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val current = store.getKey(keyAlias, null) as? SecretKey
        if (current != null) return current
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }
    private fun readQueue(): JSONArray {
        val encoded = preferences.getString("queue", null) ?: return JSONArray()
        val bytes = Base64.decode(encoded, Base64.NO_WRAP)
        require(bytes.size > 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD((owner ?: "").toByteArray(Charsets.UTF_8))
        return JSONArray(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
    }
    private fun writeQueue(queue: JSONArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD((owner ?: "").toByteArray(Charsets.UTF_8))
        val encrypted = cipher.iv + cipher.doFinal(queue.toString().toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString("queue", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
    }
    fun append(rows: List<Map<String, Any>>, unknownIds: List<String> = emptyList()) = synchronized(lock) {
        if (!enabled) return@synchronized
        val queue = readQueue()
        val known = (0 until queue.length()).map { queue.getJSONObject(it).getString("importId") }.toMutableSet()
        for (row in rows) if (known.add(row["importId"] as String)) {
            check(queue.length() < 5000) { "Finish importing existing transactions before reading more SMS." }
            queue.put(JSONObject(row))
        }
        if (rows.isNotEmpty()) writeQueue(queue)
        // Store hashes only, never the skipped SMS or any content-derived text.
        if (unknownIds.isNotEmpty()) {
            val unknown = (preferences.getStringSet("unknown", emptySet()) ?: emptySet()).toMutableSet()
            unknown.addAll(unknownIds)
            preferences.edit().putStringSet("unknown", unknown.take(5000).toSet()).commit()
        }
    }
    fun result(truncated: Boolean = false): Map<String, Any> = synchronized(lock) {
        val queue = readQueue()
        val rows = (0 until queue.length()).map { index ->
            val json = queue.getJSONObject(index)
            json.keys().asSequence().associateWith { json.get(it) }
        }
        mapOf("transactions" to rows, "unrecognizedCount" to (preferences.getStringSet("unknown", emptySet())?.size ?: 0), "truncated" to truncated)
    }
    fun acknowledge(ids: Set<String>) = synchronized(lock) {
        if (!enabled) return@synchronized
        val queue = readQueue()
        val remaining = JSONArray()
        for (index in 0 until queue.length()) {
            val row = queue.getJSONObject(index)
            if (!ids.contains(row.getString("importId"))) remaining.put(row)
        }
        writeQueue(remaining)
    }
    companion object { val lock = Any() }
}
