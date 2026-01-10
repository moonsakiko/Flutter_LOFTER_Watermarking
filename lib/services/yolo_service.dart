import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class YoloService {
  Interpreter? _interpreter;
  
  // 模型输入尺寸 (YOLOv8 默认通常是 640，如果是其他的请修改这里)
  static const int INPUT_SIZE = 640;

  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions();
      // 在 Android 上尝试使用 GPU 加速 (可选)
      // options.addDelegate(GpuDelegateV2()); 
      _interpreter = await Interpreter.fromAsset('assets/models/best_float16.tflite', options: options);
      print('✅ 模型加载成功');
    } catch (e) {
      print('❌ 模型加载失败: $e');
    }
  }

  /// 预测水印位置
  /// 返回: [x, y, w, h] (绝对坐标)
  Future<List<int>?> detectWatermark(img.Image image, double confThreshold) async {
    if (_interpreter == null) return null;

    // 1. 预处理图片 (Resize & Normalize)
    final inputTensor = _preprocess(image);

    // 2. 推理
    // YOLOv8 输出通常是 [1, 4+nc, 8400] -> [1, 5, 8400] (假设只有1个类别)
    // 我们需要查询 Output Shape
    final outputShape = _interpreter!.getOutputTensor(0).shape; // e.g., [1, 5, 8400]
    final outputBuffer = List.generate(
      outputShape[0] * outputShape[1] * outputShape[2], 
      (index) => 0.0
    ).reshape(outputShape);

    _interpreter!.run(inputTensor, outputBuffer);

    // 3. 后处理 (解析输出 + NMS)
    return _postprocess(outputBuffer[0], image.width, image.height, confThreshold);
  }

  List<List<List<double>>> _preprocess(img.Image image) {
    // 缩放并转为 Float32 [1, 640, 640, 3]
    final resized = img.copyResize(image, width: INPUT_SIZE, height: INPUT_SIZE);
    final input = List.generate(1, (i) => List.generate(INPUT_SIZE, (y) => List.generate(INPUT_SIZE, (x) {
      final pixel = resized.getPixel(x, y);
      // 归一化 0-255 -> 0.0-1.0
      return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
    })));
    return input;
  }

  List<int>? _postprocess(List<dynamic> output, int imgW, int imgH, double confThreshold) {
    // output shape: [5, 8400] (cx, cy, w, h, conf)
    // 注意：有些模型导出时维度可能是转置的 [8400, 5]，这里假设是 [5, 8400]
    
    int numAnchors = output[0].length; // 8400
    
    List<List<double>> candidates = [];

    for (int i = 0; i < numAnchors; i++) {
      double conf = output[4][i]; // 置信度
      if (conf > confThreshold) {
        double cx = output[0][i];
        double cy = output[1][i];
        double w = output[2][i];
        double h = output[3][i];
        candidates.add([cx, cy, w, h, conf]);
      }
    }

    if (candidates.isEmpty) return null;

    // 简单的 NMS: 取置信度最高的一个 (因为我们假设通常只有1个水印，或者我们需要最明显的一个)
    // 如果有多个水印，这里需要完整的 NMS 算法，但针对 LOFTER 场景通常取 Conf 最大的即可
    candidates.sort((a, b) => b[4].compareTo(a[4]));
    final best = candidates[0];

    // 将相对坐标 (0-640) 映射回原图坐标
    double scaleX = imgW / INPUT_SIZE;
    double scaleY = imgH / INPUT_SIZE;

    // x,y 是中心点，转为左上角
    int x = ((best[0] - best[2] / 2) * scaleX).toInt();
    int y = ((best[1] - best[3] / 2) * scaleY).toInt();
    int w = (best[2] * scaleX).toInt();
    int h = (best[3] * scaleY).toInt();

    // 边界检查
    x = max(0, x);
    y = max(0, y);
    w = min(imgW - x, w);
    h = min(imgH - y, h);

    return [x, y, w, h];
  }
}