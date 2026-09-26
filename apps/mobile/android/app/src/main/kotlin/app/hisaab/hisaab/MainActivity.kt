package app.hisaab.hisaab

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.hisaab/receipts")
            .setMethodCallHandler { call, result ->
                if (call.method != "rasterize") { result.notImplemented(); return@setMethodCallHandler }
                val path = call.argument<String>("path") ?: ""
                val pdf = call.argument<Boolean>("pdf") ?: false
                Thread {
                    try {
                        val input = File(path)
                        require(input.isFile && input.length() <= 60L * 1024 * 1024) { "Choose a file smaller than 60 MB." }
                        val images = if (pdf) renderPdf(input) else listOf(renderHeic(input))
                        runOnUiThread { result.success(images) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("receipt_decode_failed", error.message ?: "Could not read this file.", null) }
                    }
                }.start()
            }
    }
    private fun jpeg(bitmap: Bitmap): ByteArray {
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, output)
        bitmap.recycle()
        return output.toByteArray()
    }
    private fun renderPdf(file: File): List<ByteArray> {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { pdf ->
                return (0 until min(3, pdf.pageCount)).map { index ->
                    pdf.openPage(index).use { page ->
                        require(page.width > 0 && page.height > 0) { "This PDF has an invalid page." }
                        val scale = 2048.0 / max(page.width, page.height)
                        val bitmap = Bitmap.createBitmap(max(1, (page.width * scale).roundToInt()), max(1, (page.height * scale).roundToInt()), Bitmap.Config.ARGB_8888)
                        bitmap.eraseColor(android.graphics.Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        jpeg(bitmap)
                    }
                }
            }
        }
    }
    private fun renderHeic(file: File): ByteArray {
        if (Build.VERSION.SDK_INT < 28) throw IllegalArgumentException("This Android version cannot decode HEIC. Choose a JPEG or PNG export, or use the camera.")
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            val width = info.size.width
            val height = info.size.height
            require(width > 0 && height > 0 && width.toLong() * height <= 60_000_000L) { "Choose a readable image below 60 megapixels." }
            val scale = min(1.0, 2048.0 / max(width, height))
            decoder.setTargetSize(max(1, (width * scale).roundToInt()), max(1, (height * scale).roundToInt()))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        return jpeg(bitmap)
    }
}
