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
    private val INPUT_SIZE = 640

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        OpenCVLoader.initDebug()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "processOneImage") {
                val wmPath = call.argument<String>("wm")
                val cleanPath = call.argument<String>("clean")
                val confThreshold = call.argument<Double>("confidence")?.toFloat() ?: 0.5f

                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        if (tflite == null) {
                            val modelFile = FileUtil.loadMappedFile(context, "flutter_assets/assets/best_float16.tflite")
                            tflite = Interpreter(modelFile)
                        }

                        // 1. 处理图片
                        val fixedBitmap = processImage(wmPath!!, cleanPath!!, confThreshold)
                        
                        if (fixedBitmap != null) {
                            // 2. ✅ 核心修改：在 Kotlin 这一层直接保存到相册
                            val savedPath = saveToGallery(fixedBitmap, File(wmPath).name)
                            withContext(Dispatchers.Main) {
                                if (savedPath != null) {
                                    result.success(savedPath) // 返回保存路径
                                } else {
                                    result.error("SAVE_ERR", "保存到相册失败", null)
                                }
                            }
                        } else {
                            withContext(Dispatchers.Main) { result.success(null) } // 没识别到
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                        withContext(Dispatchers.Main) { result.error("ERR", e.message, null) }
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    // ... (保留之前的 processImage, parseOutput, convertToRect, repairWithOpenCV 方法) ...
    // 为节省篇幅，这里假设你保留了之前的算法逻辑，只要把 saveToGallery 加进去即可
    
    private fun processImage(wmPath: String, cleanPath: String, confThreshold: Float): Bitmap? {
        val wmBitmap = BitmapFactory.decodeFile(wmPath) ?: return null
        val cleanBitmap = BitmapFactory.decodeFile(cleanPath) ?: return null

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

        if (bestBox == null) return null
        return repairWithOpenCV(wmBitmap, cleanBitmap, bestBox)
    }

    // 👇👇👇 核心：原生保存逻辑 (彻底替代 gal 插件) 👇👇👇
    private fun saveToGallery(bitmap: Bitmap, originalName: String): String? {
        val filename = "Fixed_${System.currentTimeMillis()}_$originalName"
        var fos: OutputStream? = null
        var savePath: String? = null

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ 使用 MediaStore (无需权限)
                val resolver = context.contentResolver
                val contentValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
                    put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/LofterFixed")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val imageUri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)
                fos = imageUri?.let { resolver.openOutputStream(it) }
                savePath = imageUri?.toString()
                
                fos?.use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }
                
                contentValues.clear()
                contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
                imageUri?.let { resolver.update(it, contentValues, null, null) }
            } else {
                // Android 9- 使用传统文件 (需权限，Flutter端已申请)
                val imagesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES).toString() + File.separator + "LofterFixed"
                val file = File(imagesDir)
                if (!file.exists()) file.mkdirs()
                val image = File(imagesDir, "$filename.jpg")
                fos = FileOutputStream(image)
                fos.use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }
                savePath = image.absolutePath
            }
        } catch (e: Exception) {
            e.printStackTrace()
            return null
        }
        return savePath
    }
    
    // ... (请确保 parseOutputStandard, parseOutputTransposed, convertToRect, repairWithOpenCV 都在类里面) ...
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

    private fun repairWithOpenCV(wmBm: Bitmap, cleanBm: Bitmap, rect: Rect): Bitmap {
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
        }
        val resultBm = Bitmap.createBitmap(wmMat.cols(), wmMat.rows(), Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(wmMat, resultBm)
        return resultBm
    }
}