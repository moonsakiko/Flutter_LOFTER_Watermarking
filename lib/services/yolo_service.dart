import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class YoloService {
  YOLO? _yolo;
  // ❗确保这个文件名和 assets/models/ 下的一模一样
  final String modelPath = 'assets/models/best_float16.tflite';

  Future<void> initModel() async {
    if (_yolo != null) return;
    
    // 🔍 自检：检查模型文件是否被打包进去了
    try {
      final byteData = await rootBundle.load(modelPath);
      print("✅ 模型文件存在，大小: ${byteData.lengthInBytes} bytes");
      if (byteData.lengthInBytes < 1024) {
        throw "模型文件异常过小，可能已损坏";
      }
    } catch (e) {
      print("❌ 致命错误：无法读取模型文件。请检查 pubspec.yaml 和 assets 路径。");
      throw "致命错误：找不到模型文件 ($modelPath)";
    }

    try {
      _yolo = YOLO(
        modelPath: modelPath,
        task: YOLOTask.detect,
      );
      // 注意：部分插件版本 loadModel 可能不是必须的，但为了稳妥加上
      await _yolo!.loadModel();
      print("✅ YOLO 引擎初始化成功");
    } catch (e) {
      throw "YOLO 引擎初始化失败: $e";
    }
  }

  Future<List<double>?> detectWatermark(String imagePath) async {
    // 确保初始化
    await initModel();
    if (_yolo == null) throw "AI 引擎未启动";

    final imageFile = File(imagePath);
    if (!imageFile.existsSync()) throw "找不到图片文件";
    
    try {
      final imageBytes = await imageFile.readAsBytes();

      // 👇👇👇 降级置信度到 0.15，宁可错杀不可放过 👇👇👇
      final result = await _yolo!.predict(
        imageBytes,
        confidenceThreshold: 0.15, 
        iouThreshold: 0.4,
      );

      final boxes = result['boxes'] as List<dynamic>?;

      if (boxes == null || boxes.isEmpty) {
        // 返回 null 代表没找到，界面会提示
        return null;
      }

      final bestDetection = boxes.first; 
      
      if (bestDetection is Map) {
        double x, y, w, h;
        // 兼容不同的返回格式 (API 变动太快，做个防御性编程)
        if (bestDetection.containsKey('x') && bestDetection.containsKey('width')) {
           // 假设是中心点，尝试转换
           double cx = (bestDetection['x'] as num).toDouble();
           double cy = (bestDetection['y'] as num).toDouble();
           w = (bestDetection['width'] as num).toDouble();
           h = (bestDetection['height'] as num).toDouble();
           x = cx - (w / 2);
           y = cy - (h / 2);
           return [x, y, w, h];
        }
      }
      return null;

    } catch (e) {
      throw "预测过程出错: $e";
    }
  }
}