import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class YoloService {
  Interpreter? _interpreter;
  // 模型输入尺寸 (YOLOv8 默认通常是 640，请确认你的模型训练尺寸)
  static const int INPUT_SIZE = 640; 

  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions();
      // 如果是真机，可以尝试开启 GPU 代理 (视情况而定，暂不开启以保兼容)
      // options.addDelegate(GpuDelegateV2()); 
      
      _interpreter = await Interpreter.fromAsset(
        'assets/models/best_float16.tflite',
        options: options,
      );
      print("✅ 模型加载成功");
    } catch (e) {
      print("❌ 模型加载失败: $e");
    }
  }

  /// 执行推理
  /// 返回: [x, y, w, h] (绝对坐标) 或 null
  Future<List<int>?> detect(File imageFile, {double confThreshold = 0.5}) async {
    if (_interpreter == null) return null;

    // 1. 预处理图片
    final rawBytes = await imageFile.readAsBytes();
    final image = img.decodeImage(rawBytes);
    if (image == null) return null;

    int originalW = image.width;
    int originalH = image.height;

    // 缩放至 640x640
    final inputImage = img.copyResize(image, width: INPUT_SIZE, height: INPUT_SIZE);
    
    // 归一化 (0~255 -> 0.0~1.0) 并转为 Float32List
    // shape: [1, 640, 640, 3]
    var input = List.generate(1, (i) => List.generate(INPUT_SIZE, (y) => List.generate(INPUT_SIZE, (x) => List.filled(3, 0.0))));
    
    for (int y = 0; y < INPUT_SIZE; y++) {
      for (int x = 0; x < INPUT_SIZE; x++) {
        var pixel = inputImage.getPixel(x, y);
        input[0][y][x][0] = pixel.r / 255.0;
        input[0][y][x][1] = pixel.g / 255.0;
        input[0][y][x][2] = pixel.b / 255.0;
      }
    }

    // 2. 运行推理
    // Output shape depends on export. Typically [1, 5, 8400] for 1 class YOLOv8
    // 4 box coords + 1 confidence
    var outputShape = _interpreter!.getOutputTensor(0).shape; 
    // 例如 [1, 5, 8400]
    var outputBuffer = List.filled(outputShape.reduce((a, b) => a * b), 0.0).reshape(outputShape);

    _interpreter!.run(input, outputBuffer);

    // 3. 后处理 (解析输出)
    // YOLOv8 TFLite 输出通常需要转置: [1, features, anchors] -> 我们要遍历 anchors
    List<List<double>> predictions = [];
    int features = outputShape[1]; // e.g., 5 (cx, cy, w, h, conf)
    int anchors = outputShape[2];  // e.g., 8400

    for (int i = 0; i < anchors; i++) {
      double conf = outputBuffer[0][4][i]; // 第5个是置信度
      if (conf > confThreshold) {
        double cx = outputBuffer[0][0][i];
        double cy = outputBuffer[0][1][i];
        double w = outputBuffer[0][2][i];
        double h = outputBuffer[0][3][i];
        predictions.add([cx, cy, w, h, conf]);
      }
    }

    if (predictions.isEmpty) return null;

    // 4. 选出置信度最高的一个 (简化版 NMS)
    // 对于去除水印，通常只有一个目标，取最高分最稳
    predictions.sort((a, b) => b[4].compareTo(a[4]));
    var best = predictions.first;

    // 5. 坐标还原 (从 640x640 映射回原图尺寸)
    double scaleX = originalW / INPUT_SIZE;
    double scaleY = originalH / INPUT_SIZE;

    double cx = best[0] * scaleX;
    double cy = best[1] * scaleY;
    double w = best[2] * scaleX;
    double h = best[3] * scaleY;

    // 转为左上角坐标 x, y
    int x = (cx - w / 2).toInt();
    int y = (cy - h / 2).toInt();
    
    return [x, y, w.toInt(), h.toInt()];
  }
}