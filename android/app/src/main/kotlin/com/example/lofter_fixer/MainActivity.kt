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
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.imgproc.Imgproc
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.support.common.FileUtil
import org.tensorflow.lite.support.common.ops.NormalizeOp
import org.tensorflow.lite.support.image.ImageProcessor
import org.tensorflow.lite.support.image.TensorImage
import org.tensorflow.lite.support.image.ops.ResizeOp
import java.io.File
import java.io.FileOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.lofter_fixer/processor"
    private var tflite: Interpreter? = null
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
                val paddingRatio = call.argument<Double>("padding")?.toFloat() ?: 0.2f
                
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
                                val resultMsg = processOneImage(wmPath, cleanPath, confThreshold, paddingRatio)
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
                                result.error("NO_DETECTION", "结果:\n$debugLogs", null)
                            } else {
                                result.success(mapOf("count" to successCount, "firstPath" to firstSuccessPath))
                            }
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) { result.error("ERR", "严重错误: ${e.message}", null) }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun processOneImage(wmPath: String, cleanPath: String, confThreshold: Float, paddingRatio: Float): String {
        // 1. 读取图片
        val wmBitmap = BitmapFactory.decodeFile(wmPath) ?: return "无法读取水印图"
        val cleanBitmap = BitmapFactory.decodeFile(cleanPath) ?: return "无法读取原图"

        // 2. 预处理
        val imageProcessor = ImageProcessor.Builder()
            .add(ResizeOp(INPUT_SIZE, INPUT_SIZE, ResizeOp.ResizeMethod.BILINEAR))
            .add(NormalizeOp(0f, 255f))
            .build()
        var tImage = TensorImage.fromBitmap(wmBitmap)
        tImage = imageProcessor.process(tImage)

        // 3. 推理
        val outputTensor = tflite!!.getOutputTensor(0)
        val outputShape = outputTensor.shape() 
        val dim1 = outputShape[1]
        val dim2 = outputShape[2]
        val outputArray = Array(1) { Array(dim1) { FloatArray(dim2) } }
        
        tflite!!.run(tImage.buffer, outputArray)

        // 4. 解析
        val bestBox = if (dim1 > dim2) {
             parseOutputTransposed(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height, paddingRatio)
        } else {
             parseOutputStandard(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height, paddingRatio)
        }

        // 5. 修复与保存
        return if (bestBox != null) {
            try {
                // 打印调试信息，让你知道到底修复了哪里
                Log.d("Fixer", "Fixing Rect: $bestBox on image ${wmBitmap.width}x${wmBitmap.height}")
                val savedPath = repairWithOpenCV(wmBitmap, cleanBitmap, bestBox, wmPath)
                "SUCCESS: $savedPath"
            } catch (e: Exception) {
                "保存异常: ${e.message}"
            }
        } else {
            "置信度过低"
        }
    }

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

    // --- ✅ 关键修复：自适应坐标归一化检测 ---
    private fun convertToRect(cx: Float, cy: Float, w: Float, h: Float, imgW: Int, imgH: Int, paddingRatio: Float): Rect {
        // 检测是否为归一化坐标 (0.0 - 1.0)
        // 如果 w 小于 1.0，说明是归一化的，需要乘以 INPUT_SIZE 还原回 640 尺度
        val isNormalized = w < 1.0f 
        
        val normCx = if (isNormalized) cx * INPUT_SIZE else cx
        val normCy = if (isNormalized) cy * INPUT_SIZE else cy
        val normW = if (isNormalized) w * INPUT_SIZE else w
        val normH = if (isNormalized) h * INPUT_SIZE else h

        val scaleX = imgW.toFloat() / INPUT_SIZE
        val scaleY = imgH.toFloat() / INPUT_SIZE
        
        val x = (normCx - normW / 2) * scaleX
        val y = (normCy - normH / 2) * scaleY
        val width = normW * scaleX
        val height = normH * scaleY

        val paddingW = width * paddingRatio
        val paddingH = height * paddingRatio

        return Rect(
            (x - paddingW).roundToInt(),
            (y - paddingH).roundToInt(),
            (width + paddingW * 2).roundToInt(),
            (height + paddingH * 2).roundToInt()
        )
    }

    // --- ✅ 关键修复：格式对齐 + 调试绿框 ---
    private fun repairWithOpenCV(wmBm: Bitmap, cleanBm: Bitmap, rect: Rect, originalPath: String): String {
        val wmMat = Mat()
        val cleanMat = Mat()
        
        // 1. 转为 Mat
        Utils.bitmapToMat(wmBm, wmMat)
        Utils.bitmapToMat(cleanBm, cleanMat)
        
        // 2. ⚠️ 强制统一为 RGBA 4通道 (解决 copyTo 静默失败的核心) ⚠️
        Imgproc.cvtColor(wmMat, wmMat, Imgproc.COLOR_BGR2RGBA)
        Imgproc.cvtColor(cleanMat, cleanMat, Imgproc.COLOR_BGR2RGBA)
        
        // 3. 尺寸对齐
        Imgproc.resize(cleanMat, cleanMat, wmMat.size(), 0.0, 0.0, Imgproc.INTER_LANCZOS4)
        
        val imgWidth = wmMat.cols()
        val imgHeight = wmMat.rows()

        // 4. 计算安全区域
        var x1 = rect.x.coerceIn(0, imgWidth - 1)
        var y1 = rect.y.coerceIn(0, imgHeight - 1)
        var x2 = (rect.x + rect.width).coerceIn(x1 + 1, imgWidth)
        var y2 = (rect.y + rect.height).coerceIn(y1 + 1, imgHeight)
        
        val safeRect = Rect(x1, y1, x2 - x1, y2 - y1)

        // 5. 执行修复
        val patch = cleanMat.submat(safeRect)
        patch.copyTo(wmMat.submat(safeRect))
        
        // 6. 🟢 [调试功能] 画一个绿框，证明代码修改了图片 🟢
        // 如果你看到绿框但没修复，说明原图有问题；如果你连绿框都看不到，说明没执行到这里
        Imgproc.rectangle(wmMat, safeRect, Scalar(0.0, 255.0, 0.0, 255.0), 2) 

        // 7. 保存
        val resultBm = Bitmap.createBitmap(imgWidth, imgHeight, Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(wmMat, resultBm)
        
        return saveBitmap(resultBm, originalPath)
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