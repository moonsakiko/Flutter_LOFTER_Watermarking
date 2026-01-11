package com.example.lofter_fixer

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.support.common.FileUtil
import org.tensorflow.lite.support.common.ops.NormalizeOp
import org.tensorflow.lite.support.image.ImageProcessor
import org.tensorflow.lite.support.image.TensorImage
import org.tensorflow.lite.support.image.ops.ResizeOp
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.lofter_fixer/processor"
    private var tflite: Interpreter? = null
    private val INPUT_SIZE = 640 

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // OpenCV 仅用于加载库防止报错（如果你的项目里还有其他依赖），但本文件已不再使用 OpenCV 逻辑
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "processImages") {
                val tasks = call.argument<List<Map<String, String>>>("tasks") ?: listOf()
                val confThreshold = call.argument<Double>("confidence")?.toFloat() ?: 0.5f
                val paddingRatio = call.argument<Double>("padding")?.toFloat() ?: 0.2f
                val isDebug = call.argument<Boolean>("debug") ?: false // 🆕 接收调试标志
                
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        if (tflite == null) {
                            val modelFile = FileUtil.loadMappedFile(context, "best_float16.tflite")
                            tflite = Interpreter(modelFile)
                        }
                        
                        var successCount = 0
                        val debugLogs = StringBuilder()
                        var firstSuccessPath: String? = null

                        tasks.forEach { task ->
                            val wmPath = task["wm"]!!
                            val cleanPath = task["clean"]!!
                            try {
                                val resultMsg = processOneImage(wmPath, cleanPath, confThreshold, paddingRatio, isDebug)
                                if (resultMsg.startsWith("SUCCESS")) {
                                    successCount++
                                    if (firstSuccessPath == null) firstSuccessPath = resultMsg.removePrefix("SUCCESS: ")
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
                                result.success(mapOf("count" to successCount, "firstPath" to firstSuccessPath))
                            }
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) { result.error("ERR", "系统严重错误: ${e.message}", null) }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun processOneImage(wmPath: String, cleanPath: String, confThreshold: Float, paddingRatio: Float, isDebug: Boolean): String {
        // 1. 读取 Bitmap (确保是可变的，因为我们要画图)
        val wmBitmapSrc = BitmapFactory.decodeFile(wmPath) ?: return "无法读取水印图"
        // 复制一份 Mutable Bitmap 用于绘图
        val wmBitmap = wmBitmapSrc.copy(Bitmap.Config.ARGB_8888, true)
        
        val cleanBitmap = BitmapFactory.decodeFile(cleanPath) ?: return "无法读取原图"

        // 2. TFLite 推理
        val imageProcessor = ImageProcessor.Builder()
            .add(ResizeOp(INPUT_SIZE, INPUT_SIZE, ResizeOp.ResizeMethod.BILINEAR))
            .add(NormalizeOp(0f, 255f))
            .build()
        var tImage = TensorImage.fromBitmap(wmBitmap)
        tImage = imageProcessor.process(tImage)

        val outputTensor = tflite!!.getOutputTensor(0)
        val outputShape = outputTensor.shape() 
        val dim1 = outputShape[1]
        val dim2 = outputShape[2]
        val outputArray = Array(1) { Array(dim1) { FloatArray(dim2) } }
        tflite!!.run(tImage.buffer, outputArray)

        // 3. 解析坐标
        val bestBox = if (dim1 > dim2) {
             parseOutputTransposed(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height, paddingRatio)
        } else {
             parseOutputStandard(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height, paddingRatio)
        }

        if (bestBox != null) {
            // 4. ✅ 核心修改：使用 Canvas 进行绘图/修复
            try {
                // 确保 rect 在图片范围内 (Clamping)
                val imgW = wmBitmap.width
                val imgH = wmBitmap.height
                val safeRect = Rect(
                    bestBox.left.coerceIn(0, imgW),
                    bestBox.top.coerceIn(0, imgH),
                    bestBox.right.coerceIn(0, imgW),
                    bestBox.bottom.coerceIn(0, imgH)
                )

                // 如果计算出的区域有效
                if (safeRect.width() > 0 && safeRect.height() > 0) {
                    val canvas = Canvas(wmBitmap)
                    
                    if (isDebug) {
                        // 🛠️ 调试模式：画红框
                        val paint = Paint().apply {
                            color = Color.RED
                            style = Paint.Style.STROKE
                            strokeWidth = 10f
                        }
                        canvas.drawRect(safeRect, paint)
                    } else {
                        // ✨ 修复模式：从原图截取对应区域覆盖过去
                        // 绘制逻辑：将 cleanBitmap 的 safeRect 区域，画到 wmBitmap 的 safeRect 区域
                        val srcRect = safeRect // 源区域 = 目标区域
                        canvas.drawBitmap(cleanBitmap, srcRect, safeRect, null)
                    }
                    
                    return saveBitmap(wmBitmap, wmPath)
                } else {
                    return "计算出的修复区域无效"
                }
            } catch (e: Exception) {
                return "绘图异常: ${e.message}"
            }
        } else {
            return "置信度过低"
        }
    }

    // --- 坐标解析 (保留逻辑，改用 Android Rect) ---
    private fun parseOutputStandard(rows: Array<FloatArray>, confThresh: Float, imgW: Int, imgH: Int, pad: Float): Rect? {
        val numAnchors = rows[0].size 
        var maxConf = 0f
        var bestIdx = -1
        for (i in 0 until numAnchors) {
            val conf = rows[4][i] 
            if (conf > maxConf) { maxConf = conf; bestIdx = i }
        }
        if (maxConf < confThresh) return null
        return convertToRect(rows[0][bestIdx], rows[1][bestIdx], rows[2][bestIdx], rows[3][bestIdx], imgW, imgH, pad)
    }

    private fun parseOutputTransposed(rows: Array<FloatArray>, confThresh: Float, imgW: Int, imgH: Int, pad: Float): Rect? {
        var maxConf = 0f
        var bestIdx = -1
        for (i in rows.indices) {
            val conf = rows[i][4] 
            if (conf > maxConf) { maxConf = conf; bestIdx = i }
        }
        if (maxConf < confThresh) return null
        return convertToRect(rows[bestIdx][0], rows[bestIdx][1], rows[bestIdx][2], rows[bestIdx][3], imgW, imgH, pad)
    }

    private fun convertToRect(cx: Float, cy: Float, w: Float, h: Float, imgW: Int, imgH: Int, paddingRatio: Float): Rect {
        val scaleX = imgW.toFloat() / INPUT_SIZE
        val scaleY = imgH.toFloat() / INPUT_SIZE
        
        val width = w * scaleX
        val height = h * scaleY
        val x = (cx - w / 2) * scaleX
        val y = (cy - h / 2) * scaleY

        val paddingW = width * paddingRatio
        val paddingH = height * paddingRatio

        return Rect(
            (x - paddingW).roundToInt(),
            (y - paddingH).roundToInt(),
            (x + width + paddingW).roundToInt(),
            (y + height + paddingH).roundToInt()
        )
    }

    // --- 保存逻辑 (保持之前的稳固版) ---
    private fun saveBitmap(bm: Bitmap, originalPath: String): String {
        val fileName = "Fixed_${File(originalPath).name}"
        val relativePath = Environment.DIRECTORY_PICTURES + File.separator + "LofterFixed"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)
                ?: throw Exception("MediaStore 插入失败")

            resolver.openOutputStream(uri).use { out ->
                if (out == null) throw Exception("无法打开输出流")
                bm.compress(Bitmap.CompressFormat.JPEG, 98, out)
            }
            return "/storage/emulated/0/Pictures/LofterFixed/$fileName"
        } else {
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "LofterFixed")
            if (!dir.exists()) dir.mkdirs()
            val file = File(dir, fileName)
            FileOutputStream(file).use { out ->
                bm.compress(Bitmap.CompressFormat.JPEG, 98, out)
            }
            MediaScannerConnection.scanFile(context, arrayOf(file.toString()), arrayOf("image/jpeg"), null)
            return file.absolutePath
        }
    }
}