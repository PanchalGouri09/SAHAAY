package com.example.sahaay

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Saves a generated acknowledgment/receipt PDF into the shared Downloads
 * collection so the user can open it from a file manager, the Downloads app or
 * a PDF reader — not just inside the app's private storage.
 *
 * Channel: `sahaay/files`
 *   savePdf({ bytes: ByteArray, fileName: String }) -> "Downloads/<fileName>"
 *
 * On Android 10+ (API 29) the file is written through MediaStore.Downloads,
 * which needs no storage permission. On older releases it falls back to the
 * public Downloads directory. The returned string is only produced after the
 * write succeeded, so the Dart side never reports a save that did not happen.
 */
class PdfSaverChannel(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val appContext: Context = context.applicationContext

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_SAVE_PDF -> handleSavePdf(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleSavePdf(call: MethodCall, result: MethodChannel.Result) {
        val bytes: ByteArray? = call.argument(ARG_BYTES)
        val fileName = sanitizeFileName(call.argument<String>(ARG_FILE_NAME))
        if (bytes == null || bytes.isEmpty()) {
            result.error(ERROR_SAVE_FAILED, "The PDF was empty.", null)
            return
        }
        try {
            val location = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveViaMediaStore(fileName, bytes)
            } else {
                saveToPublicDownloads(fileName, bytes)
            }
            result.success(location)
        } catch (error: Throwable) {
            result.error(
                ERROR_SAVE_FAILED,
                error.message ?: "Could not save the PDF. Please try again.",
                null,
            )
        }
    }

    private fun saveViaMediaStore(fileName: String, bytes: ByteArray): String {
        val resolver = appContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, MIME_PDF)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Downloads is unavailable on this device.")
        resolver.openOutputStream(uri)?.use { output -> output.write(bytes) }
            ?: throw IllegalStateException("Could not open the saved file.")
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return "Downloads/$fileName"
    }

    private fun saveToPublicDownloads(fileName: String, bytes: ByteArray): String {
        val dir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, fileName)
        file.writeBytes(bytes)
        return "Downloads/$fileName"
    }

    private fun sanitizeFileName(raw: String?): String {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return "sahaay_acknowledgment.pdf"
        return trimmed.replace(Regex("[^A-Za-z0-9._-]"), "_")
    }

    companion object {
        const val CHANNEL_NAME = "sahaay/files"

        private const val METHOD_SAVE_PDF = "savePdf"
        private const val ARG_BYTES = "bytes"
        private const val ARG_FILE_NAME = "fileName"
        private const val MIME_PDF = "application/pdf"
        const val ERROR_SAVE_FAILED = "pdf_save_failed"
    }
}
