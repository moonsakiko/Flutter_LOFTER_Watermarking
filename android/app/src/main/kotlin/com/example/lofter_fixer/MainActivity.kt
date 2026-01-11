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

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.lofter_fixer/processor"
    private var tflite: Interpreter? = null
    // ⚠️ 核心参数：保持 640 不变，绝对不动！
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

    // --- 🚫 识别核心区 (严禁修改) ---
    // 这里的逻辑和你之前成功那个版本一模一样
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
                // 这里捕捉到的就是你截图里的错误，现在修复了 repairWithOpenCV，应该不会再报了
                "保存失败: ${e.message}"
            }
        } else {
            "置信度过低"
        }
    }

    // --- 辅助解析函数 (保持不变) ---
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

    // --- ✅ 修正点 1: 坐标转换 ---
    // 这里的修改是去掉了之前多余的 clamp，把所有边界检查留给 repairWithOpenCV 做
    private fun convertToRect(cx: Float, cy: Float, w: Float, h: Float, imgW: Int, imgH: Int): Rect {
        val scaleX = imgW.toFloat() / INPUT_SIZE
        val scaleY = imgH.toFloat() / INPUT_SIZE
        
        val finalX = ((cx - w / 2) * scaleX).toInt()
        val finalY = ((cy - h / 2) * scaleY).toInt()
        val finalW = (w * scaleX).toInt()
        val finalH = (h * scaleY).toInt()

        // 稍微扩大范围 (Padding)
        val paddingW = (finalW * 0.2).toInt()
        val paddingH = (finalH * 0.1).toInt()

        // 这里只负责算出带 Padding 的理论坐标，允许稍微越界，下一步再修剪
        return Rect(
            finalX - paddingW,
            finalY - paddingH,
            finalW + paddingW * 2,
            finalH + paddingH * 2
        )
    }

    // --- ✅✅✅ 修正点 2: 稳健的 OpenCV 区域计算 (求交集) ---
    private fun repairWithOpenCV(wmBm: Bitmap, cleanBm: Bitmap, rect: Rect, originalPath: String): String {
        val wmMat = Mat()
        val cleanMat = Mat()
        Utils.bitmapToMat(wmBm, wmMat)
        Utils.bitmapToMat(cleanBm, cleanMat)
        
        // 确保原图和水印图尺寸一致
        Imgproc.resize(cleanMat, cleanMat, wmMat.size(), 0.0, 0.0, Imgproc.INTER_LANCZOS4)
        
        val imgWidth = wmMat.cols()
        val imgHeight = wmMat.rows()

        // 📐 数学修复：计算 [识别框] 和 [图片本身] 的交集
        // 无论 rect 怎么越界，这一步算出来的 start/end 永远在图片内部
        val x1 = max(0, rect.x)
        val y1 = max(0, rect.y)
        val x2 = min(imgWidth, rect.x + rect.width)
        val y2 = min(imgHeight, rect.y + rect.height)

        val safeWidth = x2 - x1
        val safeHeight = y2 - y1

        // 只有当交集有效时才修复
        if (safeWidth > 0 && safeHeight > 0) {
            val safeRect = Rect(x1, y1, safeWidth, safeHeight)
            
            // 执行覆盖
            val patch = cleanMat.submat(safeRect)
            patch.copyTo(wmMat.submat(safeRect))
            
            val resultBm = Bitmap.createBitmap(imgWidth, imgHeight, Bitmap.Config.ARGB_8888)
            Utils.matToBitmap(wmMat, resultBm)
            
            // 保存
            return saveBitmap(resultBm, originalPath)
        } else {
            // 只有当水印完全在图片外面时才会触发这个，几乎不可能
            throw Exception("水印区域完全越界，无法修复")
        }
    }

    // --- 稳固的保存逻辑 (Pictures/LofterFixed) ---
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