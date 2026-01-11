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
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.lofter_fixer/processor"
    private var tflite: Interpreter? = null
    // ⚠️ 核心参数：保持 640 不变
    private val INPUT_SIZE = 640 

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                        var firstSuccessPath: String? = null

                        tasks.forEach { task ->
                            val wmPath = task["wm"]!!
                            val cleanPath = task["clean"]!!
                            try {
                                val resultMsg = processOneImage(wmPath, cleanPath, confThreshold)
                                if (resultMsg.startsWith("SUCCESS")) {
                                    successCount++
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

    // --- 🚫 识别核心区 ---
    private fun processOneImage(wmPath: String, cleanPath: String, confThreshold: Float): String {
        val wmBitmap = BitmapFactory.decodeFile(wmPath) ?: return "无法读取水印图"
        val cleanBitmap = BitmapFactory.decodeFile(cleanPath) ?: return "无法读取原图"

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

        val bestBox = if (dim1 > dim2) {
             parseOutputTransposed(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height)
        } else {
             parseOutputStandard(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height)
        }

        return if (bestBox != null) {
            try {
                val savedPath = repairWithOpenCV(wmBitmap, cleanBitmap, bestBox, wmPath)
                "SUCCESS: $savedPath"
            } catch (e: Exception) {
                // 这里会捕获详细的坐标错误信息
                "保存异常: ${e.message}"
            }
        } else {
            "置信度过低"
        }
    }

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

    // --- ✅ 修正点 1: 坐标计算不进行任何裁切，保留原始计算值 ---
    private fun convertToRect(cx: Float, cy: Float, w: Float, h: Float, imgW: Int, imgH: Int): Rect {
        val scaleX = imgW.toFloat() / INPUT_SIZE
        val scaleY = imgH.toFloat() / INPUT_SIZE
        
        // 计算左上角坐标 (不做 toInt 截断，保留精度到最后)
        val x = (cx - w / 2) * scaleX
        val y = (cy - h / 2) * scaleY
        val width = w * scaleX
        val height = h * scaleY

        // 稍微扩大范围 (Padding)
        val paddingW = width * 0.2
        val paddingH = height * 0.1

        // 返回包含 Padding 的 Rect，允许负数，允许越界，交给 repairWithOpenCV 处理
        return Rect(
            (x - paddingW).roundToInt(),
            (y - paddingH).roundToInt(),
            (width + paddingW * 2).roundToInt(),
            (height + paddingH * 2).roundToInt()
        )
    }

    // --- ✅✅✅ 修正点 2: 强力归位 (Clamping) ---
    private fun repairWithOpenCV(wmBm: Bitmap, cleanBm: Bitmap, rect: Rect, originalPath: String): String {
        val wmMat = Mat()
        val cleanMat = Mat()
        Utils.bitmapToMat(wmBm, wmMat)
        Utils.bitmapToMat(cleanBm, cleanMat)
        
        Imgproc.resize(cleanMat, cleanMat, wmMat.size(), 0.0, 0.0, Imgproc.INTER_LANCZOS4)
        
        val imgWidth = wmMat.cols()
        val imgHeight = wmMat.rows()

        // 诊断信息：如果出错，这个信息会非常有用
        val diagInfo = "Image: ${imgWidth}x${imgHeight}, Rect: [${rect.x}, ${rect.y}, ${rect.width}, ${rect.height}]"

        // 🔥 强制归位算法 🔥
        // 1. 强制 Left/Top 至少为 0，至多为边界
        var x1 = rect.x.coerceIn(0, imgWidth - 1)
        var y1 = rect.y.coerceIn(0, imgHeight - 1)
        
        // 2. 计算 Right/Bottom，强制不超出图片
        // 注意：rect.x 可能为负数，rect.x + rect.width 才是右边界
        val rawX2 = rect.x + rect.width
        val rawY2 = rect.y + rect.height
        
        var x2 = rawX2.coerceIn(x1 + 1, imgWidth) // 确保 x2 > x1
        var y2 = rawY2.coerceIn(y1 + 1, imgHeight) // 确保 y2 > y1

        // 3. 计算最终安全的宽高
        var safeWidth = x2 - x1
        var safeHeight = y2 - y1

        // 4. 双重保险：如果计算出来还是无效（极小概率），尝试去掉 padding 再算一次
        if (safeWidth <= 0 || safeHeight <= 0) {
             // 回退逻辑：如果加上 padding 后飞出去了，我们尝试只取中心点那 1 个像素
             // 这样虽然修不好，但至少不报错，能保存下来图片让你分析
             x1 = (rect.x + rect.width / 2).coerceIn(0, imgWidth - 1)
             y1 = (rect.y + rect.height / 2).coerceIn(0, imgHeight - 1)
             safeWidth = 1
             safeHeight = 1
        }

        // 再次检查 (理论上不可能进这里了)
        if (safeWidth <= 0 || safeHeight <= 0) {
            throw Exception("边界计算严重错误 (无法修复): $diagInfo")
        }

        val safeRect = Rect(x1, y1, safeWidth, safeHeight)
        
        try {
            val patch = cleanMat.submat(safeRect)
            patch.copyTo(wmMat.submat(safeRect))
            
            val resultBm = Bitmap.createBitmap(imgWidth, imgHeight, Bitmap.Config.ARGB_8888)
            Utils.matToBitmap(wmMat, resultBm)
            
            return saveBitmap(resultBm, originalPath)
        } catch (e: Exception) {
            throw Exception("OpenCV 覆盖失败: ${e.message} | $diagInfo")
        }
    }

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