import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img; // 纯Dart图像库
import 'package:tflite_flutter/tflite_flutter.dart';
import 'nms_utils.dart';

class YoloService {
  Interpreter? _interpreter;
  static const int inputSize = 640; // YOLO通常是640x640

  // 配置参数
  double confidenceThreshold = 0.5;
  double expansionRatioW = 0.2; // 宽度外扩 20%
  double expansionRatioH = 0.1; // 高度外扩 10%

  /// 加载模型
  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/models/best_float16.tflite');
      print("✅ 模型加载成功");
    } catch (e) {
      print("❌ 模型加载失败: $e");
    }
  }

  /// 核心修复函数
  Future<Uint8List?> repairImage(String wmPath, String noWmPath) async {
    if (_interpreter == null) await loadModel();

    // 1. 读取图片
    final wmBytes = await File(wmPath).readAsBytes();
    final noWmBytes = await File(noWmPath).readAsBytes();
    
    img.Image? wmImage = img.decodeImage(wmBytes);
    img.Image? noWmImage = img.decodeImage(noWmBytes);

    if (wmImage == null || noWmImage == null) return null;

    // 2. 关键步骤：将无水印图 Resize 到和 有水印图 一样大 (Python逻辑复刻)
    if (noWmImage.width != wmImage.width || noWmImage.height != wmImage.height) {
      noWmImage = img.copyResize(noWmImage, width: wmImage.width, height: wmImage.height, interpolation: img.Interpolation.cubic);
    }

    // 3. 预处理 (Resize + Normalize)
    // YOLO 需要 640x640，且归一化到 0~1
    img.Image resizedForModel = img.copyResize(wmImage, width: inputSize, height: inputSize);
    var inputTensor = _imageToFloat32List(resizedForModel);

    // 4. 推理
    // Output shape: [1, 4 + classes, 8400] -> [1, 5, 8400] (假设1个类别)
    var outputTensor = List.filled(1 * 5 * 8400, 0.0).reshape([1, 5, 8400]);
    _interpreter!.run(inputTensor.reshape([1, inputSize, inputSize, 3]), outputTensor);

    // 5. 解析输出并 NMS
    List<Detection> detections = _processOutput(outputTensor[0], wmImage.width, wmImage.height);
    
    if (detections.isEmpty) {
      print("⚠️ 未检测到水印");
      return null; // 没检测到，返回空或原图
    }

    // 6. 修复 (Patching)
    for (var det in detections) {
      // 计算修复区域 (包含外扩)
      int x = det.box.left.toInt();
      int y = det.box.top.toInt();
      int w = det.box.width.toInt();
      int h = det.box.height.toInt();

      // 应用外扩
      int wMargin = (w * expansionRatioW / 2).round();
      int hMargin = (h * expansionRatioH / 2).round();
      
      int xStart = max(0, x - wMargin);
      int yStart = max(0, y - hMargin);
      int xEnd = min(wmImage.width, x + w + wMargin);
      int yEnd = min(wmImage.height, y + h + hMargin);
      
      int patchW = xEnd - xStart;
      int patchH = yEnd - yStart;

      // 从无水印图中“抠”一块肉
      img.Image patch = img.copyCrop(noWmImage, x: xStart, y: yStart, width: patchW, height: patchH);
      
      // “贴”到有水印图上
      img.compositeImage(wmImage, patch, dstX: xStart, dstY: yStart);
    }

    // 7. 返回结果
    return Uint8List.fromList(img.encodeJpg(wmImage, quality: 100));
  }

  /// 辅助：图片转 Float32List (0-255 -> 0.0-1.0)
  Float32List _imageToFloat32List(img.Image image) {
    var convertedBytes = Float32List(1 * inputSize * inputSize * 3);
    var buffer = Float32List.view(convertedBytes.buffer);
    int pixelIndex = 0;
    for (var i = 0; i < inputSize; ++i) {
      for (var j = 0; j < inputSize; ++j) {
        var pixel = image.getPixel(j, i);
        buffer[pixelIndex++] = pixel.r / 255.0;
        buffer[pixelIndex++] = pixel.g / 255.0;
        buffer[pixelIndex++] = pixel.b / 255.0;
      }
    }
    return convertedBytes;
  }

  /// 辅助：解析模型输出
  List<Detection> _processOutput(List<dynamic> rawOutput, int imgW, int imgH) {
    List<Detection> results = [];
    // rawOutput: [5, 8400] -> 5 rows (xc, yc, w, h, score), 8400 cols
    // 需要转置或者直接按索引读取
    
    for (int i = 0; i < 8400; i++) {
      double score = rawOutput[4][i]; // 假设第4行是置信度
      if (score > confidenceThreshold) {
        double xCenter = rawOutput[0][i];
        double yCenter = rawOutput[1][i];
        double width = rawOutput[2][i];
        double height = rawOutput[3][i];

        // 反归一化坐标 -> 实际像素
        double x = (xCenter - width / 2) / inputSize * imgW;
        double y = (yCenter - height / 2) / inputSize * imgH;
        double w = width / inputSize * imgW;
        double h = height / inputSize * imgH;

        results.add(Detection(Rect.fromLTWH(x, y, w, h), score, 0));
      }
    }
    return nonMaxSuppression(results, 0.45); // IoU 阈值
  }
}