package com.example.lofter_fixer

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
    // ⚠️ 必须与你训练时的尺寸一致，通常是 640
    private val INPUT_SIZE = 640 

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 初始化 OpenCV
        if (!OpenCVLoader.initDebug()) {
            println("OpenCV init failed")
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "processImages") {
                val tasks = call.argument<List<Map<String, String>>>("tasks") ?: listOf()
                val confThreshold = call.argument<Double>("confidence")?.toFloat() ?: 0.5f
                
                // 开启后台协程处理，避免卡死界面
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        // 懒加载模型
                        if (tflite == null) {
                            val modelFile = FileUtil.loadMappedFile(context, "best_float16.tflite")
                            val options = Interpreter.Options()
                            tflite = Interpreter(modelFile, options)
                        }
                        
                        var successCount = 0
                        val errorLog = StringBuilder()

                        tasks.forEach { task ->
                            val wmPath = task["wm"]!!
                            val cleanPath = task["clean"]!!
                            val status = processOneImage(wmPath, cleanPath, confThreshold)
                            if (status == "SUCCESS") {
                                successCount++
                            } else {
                                errorLog.append("Fail: ${File(wmPath).name} -> $status\n")
                            }
                        }
                        
                        // 回到主线程返回结果
                        withContext(Dispatchers.Main) {
                            if (successCount == 0 && tasks.isNotEmpty()) {
                                result.error("PROCESS_FAILED", "未修复任何图片:\n$errorLog", null)
                            } else {
                                result.success(successCount)
                            }
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("ERROR", "致命错误: ${e.message}", null)
                        }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun processOneImage(wmPath: String, cleanPath: String, confThreshold: Float): String {
        try {
            val wmBitmap = BitmapFactory.decodeFile(wmPath) ?: return "无法读取水印图"
            val cleanBitmap = BitmapFactory.decodeFile(cleanPath) ?: return "无法读取原图"

            // 1. 预处理 (Resize + Normalize)
            val imageProcessor = ImageProcessor.Builder()
                .add(ResizeOp(INPUT_SIZE, INPUT_SIZE, ResizeOp.ResizeMethod.BILINEAR))
                .add(NormalizeOp(0f, 255f)) // 归一化 [0, 255] -> [0, 1]
                .build()
            
            var tImage = TensorImage.fromBitmap(wmBitmap)
            tImage = imageProcessor.process(tImage)

            // 2. 推理
            val outputTensor = tflite!!.getOutputTensor(0)
            val outputShape = outputTensor.shape() // [1, 5, 8400]
            // 创建输出 buffer
            val outputArray = Array(1) { Array(outputShape[1]) { FloatArray(outputShape[2]) } }
            tflite!!.run(tImage.buffer, outputArray)

            // 3. 解析结果 (假设 output 格式为 xywh + conf)
            // 注意：YOLOv8 输出通常需要转置，这里做个简单兼容判断
            val dim1 = outputShape[1]
            val dim2 = outputShape[2]
            
            val bestBox = if (dim1 > dim2) {
                 // 可能是 [1, 8400, 5] 格式
                 parseOutputTransposed(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height)
            } else {
                 // 可能是 [1, 5, 8400] 格式 (YOLOv8 默认)
                 parseOutputStandard(outputArray[0], confThreshold, wmBitmap.width, wmBitmap.height)
            }

            if (bestBox == null) return "未检测到水印 (置信度 < $confThreshold)"

            // 4. OpenCV 修复
            return if (repairWithOpenCV(wmBitmap, cleanBitmap, bestBox, wmPath)) {
                "SUCCESS"
            } else {
                "修复失败"
            }

        } catch (e: Exception) {
            e.printStackTrace()
            return "异常: ${e.message}"
        }
    }

    // 解析 [5, 8400] 格式
    private fun parseOutputStandard(rows: Array<FloatArray>, confThresh: Float, imgW: Int, imgH: Int): Rect? {
        val numAnchors = rows[0].size 
        var maxConf = 0f
        var bestIdx = -1
        
        // 这里的 4 代表置信度所在的索引 (cx, cy, w, h, conf)
        for (i in 0 until numAnchors) {
            val conf = rows[4][i] 
            if (conf > maxConf) { maxConf = conf; bestIdx = i }
        }

        if (maxConf < confThresh) return null
        return convertToRect(rows[0][bestIdx], rows[1][bestIdx], rows[2][bestIdx], rows[3][bestIdx], imgW, imgH)
    }

    // 解析 [8400, 5] 格式
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
        
        val finalW = (w * scaleX).toInt()
        val finalH = (h * scaleY).toInt()
        val finalX = ((cx - w / 2) * scaleX).toInt()
        val finalY = ((cy - h / 2) * scaleY).toInt()
        
        // 适当扩大修复区域 (Expand 20%)
        val expandW = (finalW * 0.2).toInt()
        val expandH = (finalH * 0.2).toInt()

        return Rect(
            (finalX - expandW).coerceAtLeast(0),
            (finalY - expandH).coerceAtLeast(0),
            (finalW + expandW * 2).coerceAtMost(imgW),
            (finalH + expandH * 2).coerceAtMost(imgH)
        )
    }

    private fun repairWithOpenCV(wmBm: Bitmap, cleanBm: Bitmap, rect: Rect, originalPath: String): Boolean {
        return try {
            val wmMat = Mat()
            val cleanMat = Mat()
            Utils.bitmapToMat(wmBm, wmMat)
            Utils.bitmapToMat(cleanBm, cleanMat)

            // 将无水印图缩放到和有水印图一样大
            Imgproc.resize(cleanMat, cleanMat, wmMat.size(), 0.0, 0.0, Imgproc.INTER_LANCZOS4)
            
            // 安全检查，防止 ROI 超出边界
            val safeRect = Rect(
                rect.x, rect.y,
                rect.width.coerceAtMost(wmMat.cols() - rect.x),
                rect.height.coerceAtMost(wmMat.rows() - rect.y)
            )

            if (safeRect.width <= 0 || safeRect.height <= 0) return false

            // 核心修复：剪切 -> 粘贴
            val patch = cleanMat.submat(safeRect)
            patch.copyTo(wmMat.submat(safeRect))

            // 转换回 Bitmap 并保存
            val resultBm = Bitmap.createBitmap(wmMat.cols(), wmMat.rows(), Bitmap.Config.ARGB_8888)
            Utils.matToBitmap(wmMat, resultBm)
            
            // ✅ 使用 MediaStore 稳妥保存
            saveBitmapToGallery(resultBm, "Fixed_${File(originalPath).name}")
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    // 🔥🔥🔥 核心：解决写入失败的终极方案 🔥🔥🔥
    private fun saveBitmapToGallery(bitmap: Bitmap, fileName: String) {
        val contentValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // 存入 Pictures/LofterFixed 文件夹
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + File.separator + "LofterFixed")
                put(MediaStore.MediaColumns.IS_PENDING, 1) // 标记为正在写入
            }
        }

        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)

        uri?.let {
            resolver.openOutputStream(it).use { out ->
                if (out != null) {
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 98, out)
                }
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentValues.clear()
                contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0) // 写入完成，解除锁定
                resolver.update(it, contentValues, null, null)
            }
        }
    }
}