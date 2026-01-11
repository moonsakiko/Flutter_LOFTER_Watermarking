package com.example.lofter_fixer

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Mat
import org.opencv.core.Rect
import org.opencv.imgproc.Imgproc
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.support.common.FileUtil
import org.tensorflow.lite.support.common.ops.NormalizeOp
import org.tensorflow.lite.support.image.ImageProcessor
import org.tensorflow.lite.support.image.TensorImage
import org.tensorflow.lite.support.image.ops.ResizeOp
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.lofter_fixer/processor"
    private var tflite: Interpreter? = null
    // ⚠️ 核心参数：保持 640 不变
    private val INPUT_SIZE = 640 

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 初始化 OpenCV
        if (!OpenCVLoader.initDebug()) {
            Log.e("LofterFixer", "OpenCV initialization failed!")
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "processImages") {
                val tasks = call.argument<List<Map<String, String>>>("tasks") ?: listOf()
                val confThreshold = call.argument<Double>("confidence")?.toFloat() ?: 0.5f
                
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        if (tflite == null) {
                            val modelFile = FileUtil.loadMappedFile(context, "best_float16.tflite")
                            tflite = Interpreter(modelFile)
                        }
                        
                        var successCount = 0
                        val debugLogs = StringBuilder()
                        // 用于存储第一张成功的图片路径返回给 Flutter
                        var firstSuccessPath: String? = null

                        tasks.forEach { task ->
                            val wmPath = task["wm"]!!
                            val cleanPath = task["clean"]!!
                            try {
                                val resultMsg = processOneImage(wmPath, cleanPath, confThreshold)
                                if (resultMsg.startsWith("SUCCESS")) {
                                    successCount++
                                    // SUCCESS: /storage/.../Fixed_xxx.jpg
                                    if (firstSuccessPath == null) {
                                        firstSuccessPath = resultMsg.removePrefix("SUCCESS: ")
                                    }
                                } else {
                                    debugLogs.append("${File(wmPath).name} -> $resultMsg\n")
                                }
                            } catch (e: Exception) {
                                debugLogs.append("${File(wmPath).name} -> 异常: ${e.message}\n")
                            }
                        }
                        
                        withContext(Dispatchers.Main) {
                            if (successCount == 0 && tasks.isNotEmpty()) {
                                result.error("NO_DETECTION", "未检测到或保存失败:\n$debugLogs", null)
                            } else {
                                // 成功时，返回 {count: int, firstPath: string}
                                result.success(mapOf(
                                    "count" to successCount,
                                    "firstPath" to firstSuccessPath
                                ))
                            }
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("ERR", "系统严重错误: ${e.message}", null)
                        }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    // --- 🚫 识别核心区 (严禁修改) ---
    private fun processOneImage(wmPath: String, cleanPath: String, confThreshold: Float): String {
        val wmBitmap = BitmapFactory.decodeFile(wmPath) ?: return "无法读取水印图"
        val cleanBitmap = BitmapFactory.decodeFile(cleanPath) ?: return "无法读取原图"

        val imageProcessor = ImageProcessor.Builder()
            .add(ResizeOp(INPUT_SIZE, INPUT_SIZE, ResizeOp.ResizeMethod.BILINEAR))
            .add(NormalizeOp(0f, 255f)) // 👈 归一化
            .build()
        var tImage = TensorImage.fromBitmap(wmBitmap)
        tImage = imageProcessor.process(tImage)

        val outputTensor = tflite!!.getOutputTensor(0)
        val outputShape = outputTensor.shape() 
        val dim1 = outputShape[1]
        val dim2 = outputShape[2]
        val outputArray = Array(1) { Array(dim1) { FloatArray(dim2) } }
        
        tflite!!.run(tImage.buffer, outputArray)

        val bestBox = if (dim1 > dim2) {
             parseOutputTransposed(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height)
        } else {
             parseOutputStandard(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height)
        }

        return if (bestBox != null) {
            // 如果识别成功，尝试保存
            try {
                val savedPath = repairWithOpenCV(wmBitmap, cleanBitmap, bestBox, wmPath)
                "SUCCESS: $savedPath"
            } catch (e: Exception) {
                "保存失败: ${e.message}"
            }
        } else {
            "置信度过低"
        }
    }

    // ... (parseOutputStandard, parseOutputTransposed, convertToRect 保持完全不变) ...
    // 为了代码简洁，这里省略这三个辅助函数，请务必保留你原来的代码！
    // ⬇️⬇️ 请确保以下三个函数在你的文件中存在且未修改 ⬇️⬇️
    
    private fun parseOutputStandard(rows: Array<FloatArray>, confThresh: Float, imgW: Int, imgH: Int): Rect? {
        val numAnchors = rows[0].size 
        var maxConf = 0f
        var bestIdx = -1
        for (i in 0 until numAnchors) {
            val conf = rows[4][i] 
            if (conf > maxConf) { maxConf = conf; bestIdx = i }
        }
        if (maxConf < confThresh) return null
        return convertToRect(rows[0][bestIdx], rows[1][bestIdx], rows[2][bestIdx], rows[3][bestIdx], imgW, imgH)
    }

    private fun parseOutputTransposed(rows: Array<FloatArray>, confThresh: Float, imgW: Int, imgH: Int): Rect? {
        var maxConf = 0f
        var bestIdx = -1
        for (i in rows.indices) {
            val conf = rows[i][4] 
            if (conf > maxConf) { maxConf = conf; bestIdx = i }
        }
        if (maxConf < confThresh) return null
        return convertToRect(rows[bestIdx][0], rows[bestIdx][1], rows[bestIdx][2], rows[bestIdx][3], imgW, imgH)
    }

    private fun convertToRect(cx: Float, cy: Float, w: Float, h: Float, imgW: Int, imgH: Int): Rect {
        val scaleX = imgW.toFloat() / INPUT_SIZE
        val scaleY = imgH.toFloat() / INPUT_SIZE
        val finalX = ((cx - w / 2) * scaleX).toInt()
        val finalY = ((cy - h / 2) * scaleY).toInt()
        val finalW = (w * scaleX).toInt()
        val finalH = (h * scaleY).toInt()
        val paddingW = (finalW * 0.2).toInt()
        val paddingH = (finalH * 0.1).toInt()
        return Rect(
            (finalX - paddingW).coerceAtLeast(0),
            (finalY - paddingH).coerceAtLeast(0),
            (finalW + paddingW * 2).coerceAtMost(imgW),
            (finalH + paddingH * 2).coerceAtMost(imgH)
        )
    }

    // --- 修复并调用保存 ---
    private fun repairWithOpenCV(wmBm: Bitmap, cleanBm: Bitmap, rect: Rect, originalPath: String): String {
        val wmMat = Mat(); val cleanMat = Mat()
        Utils.bitmapToMat(wmBm, wmMat); Utils.bitmapToMat(cleanBm, cleanMat)
        Imgproc.resize(cleanMat, cleanMat, wmMat.size(), 0.0, 0.0, Imgproc.INTER_LANCZOS4)
        
        val safeRect = Rect(
            rect.x.coerceIn(0, wmMat.cols()), rect.y.coerceIn(0, wmMat.rows()),
            rect.width.coerceAtMost(wmMat.cols() - rect.x), rect.height.coerceAtMost(wmMat.rows() - rect.y)
        )

        if (safeRect.width > 0 && safeRect.height > 0) {
            val patch = cleanMat.submat(safeRect)
            patch.copyTo(wmMat.submat(safeRect))
            val resultBm = Bitmap.createBitmap(wmMat.cols(), wmMat.rows(), Bitmap.Config.ARGB_8888)
            Utils.matToBitmap(wmMat, resultBm)
            
            // 调用新的保存逻辑，并返回路径
            return saveBitmap(resultBm, originalPath)
        } else {
            throw Exception("计算出的修复区域无效")
        }
    }

    // --- ✅ 终极稳固保存逻辑 (Target: Pictures/LofterFixed) ---
    private fun saveBitmap(bm: Bitmap, originalPath: String): String {
        val fileName = "Fixed_${File(originalPath).name}"
        // 1. 优先尝试：Pictures/LofterFixed (系统推荐的图片目录)
        val relativePath = Environment.DIRECTORY_PICTURES + File.separator + "LofterFixed"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ 使用 MediaStore
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            }

            val resolver = context.contentResolver
            // 注意：这里可能会抛出异常，如果抛出，会被上层捕获并显示在 flutter 日志里
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw Exception("MediaStore 插入失败 (Uri is null)")

            resolver.openOutputStream(uri).use { out ->
                if (out == null) throw Exception("无法打开输出流")
                if (!bm.compress(Bitmap.CompressFormat.JPEG, 98, out)) {
                    throw Exception("图片压缩写入失败")
                }
            }
            
            // 尝试返回一个可读路径 (虽在 Android 10+ 只有 Uri 有意义，但为了兼容显示)
            return "/storage/emulated/0/Pictures/LofterFixed/$fileName"
        } else {
            // Android 9 及以下：使用 File API
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "LofterFixed")
            if (!dir.exists()) {
                if (!dir.mkdirs()) throw Exception("无法创建文件夹: ${dir.absolutePath}")
            }
            val file = File(dir, fileName)
            
            FileOutputStream(file).use { out ->
                bm.compress(Bitmap.CompressFormat.JPEG, 98, out)
            }
            // 广播通知相册
            MediaScannerConnection.scanFile(context, arrayOf(file.toString()), arrayOf("image/jpeg"), null)
            return file.absolutePath
        }
    }
}