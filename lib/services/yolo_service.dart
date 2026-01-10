import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class YoloService {
  Interpreter? _interpreter;
  final String modelPath = 'assets/models/best_float16.tflite';
  
  // YOLOv8 默认输入尺寸
  static const int INPUT_SIZE = 640; 

  Future<void> initModel() async {
    if (_interpreter != null) return;
    
    try {
      // 1. 配置解释器选项：强制 CPU，不使用 GPU/NNAPI
      final options = InterpreterOptions();
      options.threads = 4; // 使用4个CPU线程
      options.useNnApiForAndroid = false; // ❌ 严禁使用 NNAPI (防崩溃核心)
      // options.addDelegate(GpuDelegateV2()); // ❌ 严禁添加 GPU 代理

      // 2. 加载模型
      _interpreter = await Interpreter.fromAsset(modelPath, options: options);
      print("✅ TFLite (CPU模式) 初始化成功");
      
      // 打印输入输出形状，用于调试
      var inputShape = _interpreter!.getInputTensor(0).shape;
      var outputShape = _interpreter!.getOutputTensor(0).shape;
      print("Input Shape: $inputShape"); // 应该是 [1, 640, 640, 3]
      print("Output Shape: $outputShape"); // 应该是 [1, 5, 8400]
      
    } catch (e) {
      print("❌ 模型加载失败: $e");
      throw "模型加载失败，请检查文件是否被压缩";
    }
  }

  /// [confidenceThreshold] 由 UI 传入
  Future<List<double>?> detectWatermark(String imagePath, double confidenceThreshold) async {
    if (_interpreter == null) await initModel();

    final imageFile = File(imagePath);
    if (!imageFile.existsSync()) throw "图片文件丢失";
    
    // 1. 读取并预处理图片
    img.Image? originalImage = img.decodeImage(await imageFile.readAsBytes());
    if (originalImage == null) throw "无法解码图片";

    // Resize 到 640x640
    img.Image resizedImage = img.copyResize(originalImage, width: INPUT_SIZE, height: INPUT_SIZE);

    // 2. 转换为 Float32 输入数据 [1, 640, 640, 3] 并归一化 (0~1)
    // 注意：TFLite Flutter 需要扁平化的 Float32List 或者多维数组
    // 这里构建输入 tensor
    var input = List.generate(1, (i) => List.generate(INPUT_SIZE, (y) => List.generate(INPUT_SIZE, (x) {
      var pixel = resizedImage.getPixel(x, y);
      return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
    })));

    // 3. 准备输出容器 [1, 5, 8400]
    // 5 代表: [cx, cy, w, h, confidence]
    // 8400 是锚点数量
    var output = List.filled(1 * 5 * 8400, 0.0).reshape([1, 5, 8400]);

    // 4. 运行推理
    try {
      _interpreter!.run(input, output);
    } catch (e) {
      throw "推理运行时崩溃: $e";
    }

    // 5. 后处理 (解析输出)
    // output[0][0][...] 是 x 坐标的所有预测
    // output[0][4][...] 是 置信度 的所有预测
    List<List<double>> rawData = output[0]; // [5, 8400]
    
    double maxConf = 0.0;
    int bestIndex = -1;

    // 遍历 8400 个锚点，找置信度最高的
    for (int i = 0; i < 8400; i++) {
      double conf = rawData[4][i];
      if (conf > maxConf) {
        maxConf = conf;
        bestIndex = i;
      }
    }

    print("🔍 最大置信度: $maxConf (阈值: $confidenceThreshold)");

    if (bestIndex != -1 && maxConf >= confidenceThreshold) {
      // 获取归一化的预测值 (基于 640x640)
      double cx = rawData[0][bestIndex];
      double cy = rawData[1][bestIndex];
      double w = rawData[2][bestIndex];
      double h = rawData[3][bestIndex];

      // 还原到原图尺寸
      double scaleX = originalImage.width / INPUT_SIZE;
      double scaleY = originalImage.height / INPUT_SIZE;

      // 计算左上角坐标 (基于 640)
      double x640 = cx - (w / 2);
      double y640 = cy - (h / 2);

      // 映射回原图
      double x = x640 * scaleX;
      double y = y640 * scaleY;
      double finalW = w * scaleX;
      double finalH = h * scaleY;

      return [x, y, finalW, finalH];
    }

    return null;
  }
}