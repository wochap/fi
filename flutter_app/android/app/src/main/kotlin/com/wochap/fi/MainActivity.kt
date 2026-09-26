package com.wochap.fi

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Narrow Android capability adapter. Pairing, routing, and sync policy remain in Rust. */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var pendingSave: PendingSave? = null

    /** An export waiting for the user to pick a destination in the system save dialog. */
    private class PendingSave(val bytes: ByteArray, val result: MethodChannel.Result)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler(
            ::handlePlatformCall,
        )
    }

    override fun onDestroy() {
        releaseMulticast()
        super.onDestroy()
    }

    override fun onPause() {
        releaseMulticast()
        super.onPause()
    }

    private fun handlePlatformCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setForeground" -> {
                    if (call.arguments == true) acquireMulticast() else releaseMulticast()
                    result.success(null)
                }
                "secureLoadOrCreateDeviceKey" -> result.success(loadOrCreateSecret("device-seed"))
                "secureLoadDiscoverySecret" -> result.success(loadSecret("discovery-secret"))
                "secureStoreDiscoverySecret" -> {
                    val secret = call.arguments as? ByteArray
                        ?: throw IllegalArgumentException("discovery secret must be bytes")
                    require(secret.size == SECRET_SIZE) { "discovery secret has invalid size" }
                    storeSecret("discovery-secret", secret)
                    result.success(null)
                }
                "secureRemoveDiscoverySecret" -> {
                    removeSecret("discovery-secret")
                    result.success(null)
                }
                "saveDocument" -> saveDocument(call, result)
                else -> result.notImplemented()
            }
        } catch (failure: Exception) {
            result.error("android_capability", safeCategory(failure), null)
        }
    }

    /**
     * Opens the Storage Access Framework save dialog. The bytes are written only after the user
     * picks a destination; the reply is the chosen display name, or null when dismissed.
     */
    private fun saveDocument(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name") ?: throw IllegalArgumentException("name")
        val mimeType = call.argument<String>("mimeType") ?: throw IllegalArgumentException("mimeType")
        val bytes = call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("bytes")
        pendingSave?.result?.success(null)
        pendingSave = PendingSave(bytes, result)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, name)
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, SAVE_DOCUMENT_REQUEST)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_DOCUMENT_REQUEST) return
        val pending = pendingSave ?: return
        pendingSave = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.result.success(null)
            return
        }
        try {
            val stream = contentResolver.openOutputStream(uri, "wt")
                ?: error("document_unwritable")
            stream.use { it.write(pending.bytes) }
            pending.result.success(displayName(uri))
        } catch (failure: Exception) {
            pending.result.error("android_capability", safeCategory(failure), null)
        }
    }

    private fun displayName(uri: Uri): String =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
            ?: uri.lastPathSegment
            ?: "document"

    private fun acquireMulticast() {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        check(connectivity.activeNetwork != null) { "network_unavailable" }
        val existing = multicastLock
        if (existing?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: error("multicast_unavailable")
        multicastLock = wifi.createMulticastLock(MULTICAST_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticast() {
        multicastLock?.let { lock -> if (lock.isHeld) lock.release() }
        multicastLock = null
    }

    private fun loadOrCreateSecret(kind: String): ByteArray {
        val preferences = getSharedPreferences(SECRET_PREFERENCES, Context.MODE_PRIVATE)
        if (preferences.contains(kind)) return loadSecret(kind) ?: error("secret_missing")
        return ByteArray(SECRET_SIZE).also {
            SecureRandom().nextBytes(it)
            storeSecret(kind, it)
        }
    }

    private fun loadSecret(kind: String): ByteArray? {
        val encoded = getSharedPreferences(SECRET_PREFERENCES, Context.MODE_PRIVATE)
            .getString(kind, null) ?: return null
        val sealed = Base64.decode(encoded, Base64.NO_WRAP)
        require(sealed.size > NONCE_SIZE) { "wrapped_secret_malformed" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            wrappingKey(),
            GCMParameterSpec(GCM_TAG_BITS, sealed.copyOfRange(0, NONCE_SIZE)),
        )
        cipher.updateAAD(aad(kind))
        return cipher.doFinal(sealed.copyOfRange(NONCE_SIZE, sealed.size)).also {
            require(it.size == SECRET_SIZE) { "secret_size_invalid" }
        }
    }

    private fun storeSecret(kind: String, plaintext: ByteArray) {
        require(plaintext.size == SECRET_SIZE) { "secret_size_invalid" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        cipher.updateAAD(aad(kind))
        val sealed = cipher.iv + cipher.doFinal(plaintext)
        check(
            getSharedPreferences(SECRET_PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .putString(kind, Base64.encodeToString(sealed, Base64.NO_WRAP))
                .commit(),
        ) { "secret_persistence_failed" }
        sealed.fill(0)
    }

    // Absent entry is success: reset must be idempotent.
    private fun removeSecret(kind: String) {
        check(
            getSharedPreferences(SECRET_PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .remove(kind)
                .commit(),
        ) { "secret_persistence_failed" }
    }

    private fun wrappingKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun aad(kind: String) = "fi:$kind:v1".encodeToByteArray()

    private fun safeCategory(failure: Exception): String = when (failure) {
        is SecurityException -> "permission_denied"
        is IllegalArgumentException -> "invalid_input"
        else -> if (Build.VERSION.SDK_INT < 24) "unsupported_android" else "capability_failed"
    }

    companion object {
        private const val CHANNEL = "fi/platform"
        private const val SAVE_DOCUMENT_REQUEST = 4101
        private const val MULTICAST_TAG = "fi-mdns-foreground"
        private const val ANDROID_KEY_STORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "fi.secure-store.wrap.v1"
        private const val SECRET_PREFERENCES = "fi-secure-wrapped-v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val SECRET_SIZE = 32
        private const val NONCE_SIZE = 12
        private const val GCM_TAG_BITS = 128
    }
}
