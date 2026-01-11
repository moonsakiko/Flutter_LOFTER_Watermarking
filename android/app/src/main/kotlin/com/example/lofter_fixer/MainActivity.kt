FILE: android/app/src/main/kotlin/com/example/lofter_fixer/MainActivity.kt
package com.example.lofter_fixer

import android.content.ContentValues
import android.content.Context
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
import java.io.InputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.lofter_fixer/processor"
    private var tflite: Interpreter? = null
    // YOLOv8 默认输入尺寸，如果你的模型不同请修改
    private val INPUT_SIZE = 640 

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // 初始化 OpenCV
        if (!OpenCVLoader.initDebug()) {
            println("OpenCV init failed!")
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "processImages") {
                val tasks = call.argument<List<Map<String, String>>>("tasks") ?: listOf()
                val confThreshold = call.argument<Double>("confidence")?.toFloat() ?: 0.5f
                
                // 开启后台协程处理，防止卡死 UI
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        // 1. 懒加载模型 (首次运行时加载)
                        if (tflite == null) {
                            // 注意：模型文件必须放在 flutter assets 中，
                            // 但原生读取需要一点技巧，这里简单起见，假设你已经在 Flutter 端
                            // 把 assets 里的 model 拷贝到了 Cache 目录。
                            // 如果没拷贝，下面会报错。
                            // *更稳妥的做法*：Flutter 启动时把 asset 复制到 getApplicationDocumentsDirectory
                            // 然后传路径给这里。这里为了简化，我们假设传进来的是路径，或者直接用 asset 名字
                            
                            // 这里我们使用 Flutter 的 asset 机制读取
                            val assetManager = context.assets
                            val modelDescriptor = assetManager.openFd("flutter_assets/assets/best_float16.tflite")
                            val inputStream = modelDescriptor.createInputStream()
                            val modelBytes = inputStream.readBytes()
                            val buffer = java.nio.ByteBuffer.allocateDirect(modelBytes.size)
                            buffer.order(java.nio.ByteOrder.nativeOrder())
                            buffer.put(modelBytes)
                            tflite = Interpreter(buffer)
                        }
                        
                        var successCount = 0
                        val logBuilder = StringBuilder()

                        tasks.forEach { task ->
                            val wmPath = task["wm"]!!
                            val cleanPath = task["clean"]!!
                            val processResult = processSingleImage(wmPath, cleanPath, confThreshold)
                            if (processResult.startsWith("SUCCESS")) {
                                successCount++
                            } else {
                                logBuilder.append("Fail: ${File(wmPath).name} -> $processResult\n")
                            }
                        }

                        withContext(Dispatchers.Main) {
                            if (successCount == 0 && tasks.isNotEmpty()) {
                                result.error("FAIL", "所有图片修复失败:\n$logBuilder", null)
                            } else {
                                result.success(successCount)
                            }
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                        withContext(Dispatchers.Main) {
                            result.error("ERROR", "处理异常: ${e.message}", null)
                        }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun processSingleImage(wmPath: String, cleanPath: String, conf: Float): String {
        try {
            val wmBitmap = BitmapFactory.decodeFile(wmPath) ?: return "无法读取水印图"
            val cleanBitmap = BitmapFactory.decodeFile(cleanPath) ?: return "无法读取无水印图"

            // 1. 预处理 (Resize & Normalize)
            val imageProcessor = ImageProcessor.Builder()
                .add(ResizeOp(INPUT_SIZE, INPUT_SIZE, ResizeOp.ResizeMethod.BILINEAR))
                .add(NormalizeOp(0f, 255f)) // 归一化 [0, 1]
                .build()
            
            var tImage = TensorImage.fromBitmap(wmBitmap)
            tImage = imageProcessor.process(tImage)

            // 2. 推理
            val outputTensor = tflite!!.getOutputTensor(0)
            val outputShape = outputTensor.shape() // [1, 5, 8400] or similar
            // 假设 YOLO 输出格式为 [1, 5, N] (xywh + conf)
            val rows = outputShape[1] 
            val cols = outputShape[2]
            
            val outputBuffer = Array(1) { Array(rows) { FloatArray(cols) } }
            tflite!!.run(tImage.buffer, outputBuffer)

            // 3. 解析结果 (简化版：只找置信度最高的框)
            // 注意：YOLOv8 输出通常需要转置，这里需要根据你的模型实际输出来看
            // 如果 outputShape 是 [1, 84, 8400] (class+box combined)，处理逻辑会很复杂
            // 这里假设你的模型只有 1 个类 (watermark)，输出类似 [1, 5, 8400]
            
            // 为了稳妥，我们寻找 outputBuffer[0] 中置信度(index 4)最高的那一列
            // 提示：大部分 TFLite 转换后的 YOLO 是 [1, 8400, 5] 或 [1, 5, 8400]
            // 这里我们需要动态判断哪个维度是框的数量
            
            val output = outputBuffer[0]
            var bestBox: Rect? = null
            var maxScore = 0f
            
            // 简单 heuristic: 哪个维度大，哪个就是 anchor 数量
            val isTransposed = rows < cols 
            val numAnchors = if (isTransposed) cols else rows
            
            for (i in 0 until numAnchors) {
                // 读取 conf
                val score = if (isTransposed) output[4][i] else output[i][4]
                if (score > maxScore) {
                    maxScore = score
                    if (score > conf) {
                        val cx = if (isTransposed) output[0][i] else output[i][0]
                        val cy = if (isTransposed) output[1][i] else output[i][1]
                        val w  = if (isTransposed) output[2][i] else output[i][2]
                        val h  = if (isTransposed) output[3][i] else output[i][3]
                        
                        // 坐标转换回原图
                        val x = (cx - w/2) * (wmBitmap.width.toFloat() / INPUT_SIZE)
                        val y = (cy - h/2) * (wmBitmap.height.toFloat() / INPUT_SIZE)
                        val bw = w * (wmBitmap.width.toFloat() / INPUT_SIZE)
                        val bh = h * (wmBitmap.height.toFloat() / INPUT_SIZE)
                        
                        bestBox = Rect(x.toInt(), y.toInt(), bw.toInt(), bh.toInt())
                    }
                }
            }

            if (bestBox == null) return "未检测到水印 (MaxConf: $maxScore)"

            // 4. 修复 (OpenCV 复制粘贴)
            val wmMat = Mat()
            val cleanMat = Mat()
            Utils.bitmapToMat(wmBitmap, wmMat)
            Utils.bitmapToMat(cleanBitmap, cleanMat)
            
            // 确保尺寸一致
            Imgproc.resize(cleanMat, cleanMat, wmMat.size())

            // 扩大一点范围防止边缘残留
            val padW = (bestBox.width * 0.1).toInt()
            val padH = (bestBox.height * 0.1).toInt()
            
            val safeX = (bestBox.x - padW).coerceAtLeast(0)
            val safeY = (bestBox.y - padH).coerceAtLeast(0)
            val safeW = (bestBox.width + padW * 2).coerceAtMost(wmMat.cols() - safeX)
            val safeH = (bestBox.height + padH * 2).coerceAtMost(wmMat.rows() - safeY)
            
            val roi = Rect(safeX, safeY, safeW, safeH)
            
            // 核心修复动作：直接覆盖
            val patch = cleanMat.submat(roi)
            patch.copyTo(wmMat.submat(roi))
            
            val resultBitmap = Bitmap.createBitmap(wmBitmap.width, wmBitmap.height, Bitmap.Config.ARGB_8888)
            Utils.matToBitmap(wmMat, resultBitmap)

            // 5. 保存到相册 (Android 11+ Safe Way)
            return saveToGallery(resultBitmap, "Fixed_${File(wmPath).name}")

        } catch (e: Exception) {
            return "Error: ${e.message}"
        }
    }

    // ⭐⭐ 关键：最稳妥的保存方法 ⭐⭐
    private fun saveToGallery(bitmap: Bitmap, fileName: String): String {
        val resolver = context.contentResolver
        val contentValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            // 存到 Pictures/LofterFixed 文件夹
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/LofterFixed")
                put(MediaStore.MediaColumns.IS_PENDING, 1) // 标记为正在写入
            }
        }

        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)
            ?: return "无法创建 MediaStore 条目"

        return try {
            resolver.openOutputStream(uri)?.use { stream ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 95, stream)
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentValues.clear()
                contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0) // 写入完成，解除锁定
                resolver.update(uri, contentValues, null, null)
            }
            "SUCCESS"
        } catch (e: Exception) {
            "保存失败: ${e.message}"
        }
    }
}