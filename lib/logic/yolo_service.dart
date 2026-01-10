import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class YoloService {
  Interpreter? _interpreter;
  static const int INPUT_SIZE = 640; // YOLOv8 默认尺寸

  Future<void> loadModel() async {
    try {
      // 加载 assets 中的模型
      _interpreter = await Interpreter.fromAsset('assets/models/best_float16.tflite');
      print("✅ 模型加载成功");
    } catch (e) {
      print("❌ 模型加载失败: $e");
    }
  }

  /// 核心推理函数
  /// 返回格式: List of [x, y, w, h] (绝对坐标)
  Future<List<List<int>>> detect(File imageFile, double confThreshold) async {
    if (_interpreter == null) return [];

    // 1. 读取并预处理图片
    final rawImage = await imageFile.readAsBytes();
    final decodedImage = img.decodeImage(rawImage);
    if (decodedImage == null) return [];

    final originalW = decodedImage.width;
    final originalH = decodedImage.height;

    // 2. 缩放到 640x640 并归一化 (0~255 -> 0.0~1.0)
    final resized = img.copyResize(decodedImage, width: INPUT_SIZE, height: INPUT_SIZE);
    
    // 构建输入 Tensor [1, 640, 640, 3]
    var input = List.generate(
      1, 
      (i) => List.generate(
        INPUT_SIZE, 
        (y) => List.generate(
          INPUT_SIZE, 
          (x) {
            final pixel = resized.getPixel(x, y);
            return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
          }
        )
      )
    );

    // 3. 运行推理
    // YOLOv8 输出通常是 [1, 5, 8400] (xywh + conf) 或者是 [1, 8400, 5] 取决于导出方式
    // 这里假设输出需要转置处理
    var outputShape = _interpreter!.getOutputTensor(0).shape; 
    // 创建输出 buffer
    var output = List.filled(outputShape.reduce((a, b) => a * b), 0.0).reshape(outputShape);

    _interpreter!.run(input, output);

    // 4. 后处理 (解析坐标 + NMS)
    return _parseOutput(output, confThreshold, originalW, originalH);
  }

  List<List<int>> _parseOutput(List<dynamic> output, double threshold, int imgW, int imgH) {
    // YOLOv8 TFLite 输出通常是 [1, 5, 8400] -> 需要转置读取
    // 0: x_center, 1: y_center, 2: width, 3: height, 4: confidence
    
    // 注意：不同导出方式维度可能不同，这里按标准 [1, 5, 8400] 处理
    List<List<double>> boxes = [];
    
    // 假设 output[0] 是数据，维度 5 是特征，维度 8400 是锚点
    // 我们需要遍历 8400 个锚点
    int features = output[0].length; // 5 或 84+
    int anchors = output[0][0].length; // 8400

    for (int i = 0; i < anchors; i++) {
      double conf = output[0][4][i]; // 置信度
      
      if (conf > threshold) {
        double xCenter = output[0][0][i];
        double yCenter = output[0][1][i];
        double width = output[0][2][i];
        double height = output[0][3][i];

        // 转回 640 坐标系左上角
        double x = (xCenter - width / 2);
        double y = (yCenter - height / 2);

        boxes.add([x, y, width, height, conf]);
      }
    }

    // NMS (非极大值抑制) - 简单版：取置信度最高的几个
    boxes.sort((a, b) => b[4].compareTo(a[4]));
    if (boxes.isEmpty) return [];

    // 这里简化处理：直接返回置信度最高的那个框（通常去水印只需要一个框）
    // 如果需要多个水印，需要实现完整的 IoU 过滤
    var bestBox = boxes.first;

    // 5. 坐标映射回原图尺寸
    double scaleX = imgW / INPUT_SIZE;
    double scaleY = imgH / INPUT_SIZE;

    int finalX = (bestBox[0] * scaleX).toInt();
    int finalY = (bestBox[1] * scaleY).toInt();
    int finalW = (bestBox[2] * scaleX).toInt();
    int finalH = (bestBox[3] * scaleY).toInt();

    // 确保不越界
    finalX = max(0, finalX);
    finalY = max(0, finalY);
    
    return [[finalX, finalY, finalW, finalH]];
  }
}