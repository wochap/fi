package com.wochap.fi

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Narrow Android capability adapter. Pairing, routing, and sync policy remain in Rust. */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var pendingSave: PendingSave? = null
    private var pendingPhoto: PendingPhoto? = null
    private var platformChannel: MethodChannel? = null
    private var pendingLocationPermission: MethodChannel.Result? = null
    private var activeLocationListener: LocationListener? = null

    /** An export waiting for the user to pick a destination in the system save dialog. */
    private class PendingSave(val bytes: ByteArray, val result: MethodChannel.Result)

    /** A camera capture waiting for the system camera app to write to [file]. */
    private class PendingPhoto(val file: File, val result: MethodChannel.Result)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        platformChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handlePlatformCall)
        }
    }

    override fun onDestroy() {
        stopLocationUpdates()
        releaseMulticast()
        super.onDestroy()
    }

    override fun onPause() {
        stopLocationUpdates()
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
                "secureStorePreviousDiscoverySecret" -> {
                    val epoch = call.argument<Number>("epoch")?.toLong()
                        ?: throw IllegalArgumentException("previous epoch must be a number")
                    require(epoch >= 1) { "previous epoch must be positive" }
                    val secret = call.argument<ByteArray>("secret")
                        ?: throw IllegalArgumentException("previous discovery secret must be bytes")
                    require(secret.size == SECRET_SIZE) { "previous discovery secret has invalid size" }
                    storePreviousSecret(epoch, secret)
                    result.success(null)
                }
                "secureLoadPreviousDiscoverySecret" -> result.success(loadPreviousSecret())
                "secureRemovePreviousDiscoverySecret" -> {
                    removeSecret(PREVIOUS_SECRET, PREVIOUS_EPOCH)
                    result.success(null)
                }
                "saveDocument" -> saveDocument(call, result)
                "locationStatus" -> result.success(locationStatusMap())
                "requestLocationPermission" -> requestLocationPermission(result)
                "openLocationSettings" -> {
                    startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                    result.success(null)
                }
                "openAppSettings" -> {
                    val intent = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", packageName, null),
                    )
                    startActivity(intent)
                    result.success(null)
                }
                "startLocationFix" -> {
                    startLocationUpdates()
                    result.success(null)
                }
                "stopLocationFix" -> {
                    stopLocationUpdates()
                    result.success(null)
                }
                "openExternalUrl" -> {
                    val url = call.argument<String>("url")
                        ?: throw IllegalArgumentException("url")
                    val chooser = call.argument<Boolean>("chooser") ?: false
                    val base = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    val target = if (chooser) Intent.createChooser(base, null) else base
                    startActivity(target)
                    result.success(null)
                }
                "takePhoto" -> takePhoto(result)
                "openExternalFile" -> openExternalFile(call, result)
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

    /**
     * Launches the system camera app to capture a full-resolution JPEG into app cache.
     * Replies with `{"path": ..., "name": ...}` on capture, or null when cancelled.
     */
    private fun takePhoto(result: MethodChannel.Result) {
        pendingPhoto?.let { prev ->
            prev.file.delete()
            prev.result.success(null)
        }
        val captureDir = File(cacheDir, "camera_captures").apply { mkdirs() }
        // Clean up any leftover captures from previous sessions so cache stays bounded.
        captureDir.listFiles()?.forEach { it.delete() }
        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val photoFile = File(captureDir, "photo_$timestamp.jpg")
        val contentUri = FileProvider.getUriForFile(
            this,
            "$packageName.fi.fileprovider",
            photoFile,
        )
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, contentUri)
            clipData = ClipData.newRawUri("photo", contentUri)
            addFlags(
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        pendingPhoto = PendingPhoto(photoFile, result)
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, TAKE_PHOTO_REQUEST)
        } catch (failure: Exception) {
            pendingPhoto = null
            photoFile.delete()
            throw failure
        }
    }

    private fun openExternalFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: throw IllegalArgumentException("path")
        val file = File(path)
        require(file.exists()) { "file_missing" }
        val uri = FileProvider.getUriForFile(this, "$packageName.fi.fileprovider", file)
        val mime = when (file.extension.lowercase(Locale.US)) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            else -> "image/*"
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        result.success(null)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            SAVE_DOCUMENT_REQUEST -> {
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
            TAKE_PHOTO_REQUEST -> {
                val pending = pendingPhoto ?: return
                pendingPhoto = null
                if (resultCode == Activity.RESULT_OK &&
                    pending.file.exists() &&
                    pending.file.length() > 0
                ) {
                    pending.result.success(
                        mapOf(
                            "path" to pending.file.absolutePath,
                            "name" to pending.file.name,
                        ),
                    )
                } else {
                    pending.file.delete()
                    pending.result.success(null)
                }
            }
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

    private fun loadSecret(kind: String, aadSuffix: String = ""): ByteArray? {
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
        cipher.updateAAD(aad(kind, aadSuffix))
        return cipher.doFinal(sealed.copyOfRange(NONCE_SIZE, sealed.size)).also {
            require(it.size == SECRET_SIZE) { "secret_size_invalid" }
        }
    }

    private fun storeSecret(kind: String, plaintext: ByteArray, aadSuffix: String = "") {
        check(
            getSharedPreferences(SECRET_PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .putString(kind, sealSecret(kind, plaintext, aadSuffix))
                .commit(),
        ) { "secret_persistence_failed" }
    }

    private fun sealSecret(kind: String, plaintext: ByteArray, aadSuffix: String): String {
        require(plaintext.size == SECRET_SIZE) { "secret_size_invalid" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        cipher.updateAAD(aad(kind, aadSuffix))
        val sealed = cipher.iv + cipher.doFinal(plaintext)
        return Base64.encodeToString(sealed, Base64.NO_WRAP).also { sealed.fill(0) }
    }

    /** The epoch is bound into the AAD, so an altered stored epoch fails authentication. */
    private fun storePreviousSecret(epoch: Long, plaintext: ByteArray) {
        check(
            getSharedPreferences(SECRET_PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .putString(PREVIOUS_SECRET, sealSecret(PREVIOUS_SECRET, plaintext, ":$epoch"))
                .putLong(PREVIOUS_EPOCH, epoch)
                .commit(),
        ) { "secret_persistence_failed" }
    }

    private fun loadPreviousSecret(): Map<String, Any>? {
        val preferences = getSharedPreferences(SECRET_PREFERENCES, Context.MODE_PRIVATE)
        if (!preferences.contains(PREVIOUS_SECRET) || !preferences.contains(PREVIOUS_EPOCH)) {
            return null
        }
        val epoch = preferences.getLong(PREVIOUS_EPOCH, 0)
        val secret = loadSecret(PREVIOUS_SECRET, ":$epoch") ?: return null
        return mapOf("epoch" to epoch, "secret" to secret)
    }

    // Absent entry is success: reset must be idempotent.
    private fun removeSecret(vararg keys: String) {
        val editor = getSharedPreferences(SECRET_PREFERENCES, Context.MODE_PRIVATE).edit()
        keys.forEach { editor.remove(it) }
        check(editor.commit()) { "secret_persistence_failed" }
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

    private fun aad(kind: String, suffix: String) = "fi:$kind:v1$suffix".encodeToByteArray()

    private fun safeCategory(failure: Exception): String = when (failure) {
        is SecurityException -> "permission_denied"
        is IllegalArgumentException -> "invalid_input"
        else -> if (Build.VERSION.SDK_INT < 24) "unsupported_android" else "capability_failed"
    }

    private fun hasFineLocation(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasCoarseLocation(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun isLocationServicesEnabled(): Boolean {
        val manager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.isLocationEnabled
        } else {
            @Suppress("DEPRECATION")
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    private fun locationStatusMap(): Map<String, Any> = mapOf(
        "fine" to hasFineLocation(),
        "coarse" to hasCoarseLocation(),
        "servicesEnabled" to isLocationServicesEnabled(),
        "shouldShowRationale" to ActivityCompat.shouldShowRequestPermissionRationale(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ),
    )

    private fun requestLocationPermission(result: MethodChannel.Result) {
        pendingLocationPermission?.success(locationStatusMap())
        pendingLocationPermission = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            LOCATION_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != LOCATION_PERMISSION_REQUEST) return
        val pending = pendingLocationPermission ?: return
        pendingLocationPermission = null
        pending.success(locationStatusMap())
    }

    @Suppress("MissingPermission")
    private fun startLocationUpdates() {
        stopLocationUpdates()
        val fine = hasFineLocation()
        val coarse = hasCoarseLocation()
        if (!fine && !coarse) {
            throw SecurityException("location_permission_denied")
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: error("location_unavailable")
        val approximateOnly = !fine && coarse
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                emitLocationFix(location, approximateOnly)
            }

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }
        activeLocationListener = listener

        val providers = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                manager.allProviders.contains(LocationManager.FUSED_PROVIDER)
            ) {
                add(LocationManager.FUSED_PROVIDER)
            }
            if (fine && manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                add(LocationManager.GPS_PROVIDER)
            }
            if (manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                add(LocationManager.NETWORK_PROVIDER)
            }
        }

        // Emit a recent cached fix immediately if fresh (< 30s) so UI updates quickly.
        var bestLast: Location? = null
        val nowMs = System.currentTimeMillis()
        for (provider in providers) {
            val last = try {
                manager.getLastKnownLocation(provider)
            } catch (_: Exception) {
                null
            } ?: continue
            if (nowMs - last.time <= 30_000L) {
                if (bestLast == null || last.accuracy < bestLast.accuracy) {
                    bestLast = last
                }
            }
        }
        bestLast?.let { emitLocationFix(it, approximateOnly) }

        for (provider in providers) {
            try {
                manager.requestLocationUpdates(
                    provider,
                    500L,
                    0f,
                    listener,
                    Looper.getMainLooper(),
                )
            } catch (_: Exception) {
                // Skip unavailable provider.
            }
        }
    }

    private fun emitLocationFix(location: Location, approximateOnly: Boolean) {
        val payload = mapOf(
            "lat" to location.latitude,
            "lng" to location.longitude,
            "accuracy" to if (location.hasAccuracy()) location.accuracy.toDouble() else 50.0,
            "approximate" to approximateOnly,
        )
        runOnUiThread {
            platformChannel?.invokeMethod("onLocationFix", payload)
        }
    }

    private fun stopLocationUpdates() {
        val listener = activeLocationListener ?: return
        activeLocationListener = null
        val manager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return
        try {
            manager.removeUpdates(listener)
        } catch (_: Exception) {
            // Ignore cleanup errors.
        }
    }

    companion object {
        private const val CHANNEL = "fi/platform"
        private const val SAVE_DOCUMENT_REQUEST = 4101
        private const val LOCATION_PERMISSION_REQUEST = 4102
        private const val TAKE_PHOTO_REQUEST = 4103
        private const val MULTICAST_TAG = "fi-mdns-foreground"
        private const val ANDROID_KEY_STORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "fi.secure-store.wrap.v1"
        private const val SECRET_PREFERENCES = "fi-secure-wrapped-v1"
        private const val PREVIOUS_SECRET = "discovery-secret-previous"
        private const val PREVIOUS_EPOCH = "discovery-secret-previous-epoch"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val SECRET_SIZE = 32
        private const val NONCE_SIZE = 12
        private const val GCM_TAG_BITS = 128
    }
}
