import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class YoloService {
  YOLO? _yolo;
  // ❗确保文件名正确
  final String modelPath = 'assets/models/best_float16.tflite';

  Future<void> initModel() async {
    if (_yolo != null) return;
    
    // 1. 自检模型
    try {
      final byteData = await rootBundle.load(modelPath);
      if (byteData.lengthInBytes < 1024) throw "模型损坏";
    } catch (e) {
      throw "找不到模型文件 ($modelPath)";
    }

    try {
      _yolo = YOLO(
        modelPath: modelPath,
        task: YOLOTask.detect,
        // 👇 强制 CPU 运行，防止 Platform Error 崩溃
        useGpu: false, 
      );
      await _yolo!.loadModel();
      print("✅ YOLO (CPU模式) 初始化成功");
    } catch (e) {
      throw "引擎初始化失败: $e";
    }
  }

  Future<List<double>?> detectWatermark(String imagePath) async {
    await initModel();
    if (_yolo == null) throw "引擎未启动";

    final imageFile = File(imagePath);
    if (!imageFile.existsSync()) throw "图片文件丢失";
    
    try {
      final imageBytes = await imageFile.readAsBytes();

      // 👇 置信度 0.15
      final result = await _yolo!.predict(
        imageBytes,
        confidenceThreshold: 0.15, 
        iouThreshold: 0.4,
      );

      final boxes = result['boxes'] as List<dynamic>?;

      if (boxes == null || boxes.isEmpty) return null;

      final bestDetection = boxes.first; 
      
      if (bestDetection is Map) {
        if (bestDetection.containsKey('x') && bestDetection.containsKey('width')) {
           // 👇👇👇 修正点：加上 double 声明 👇👇👇
           double cx = (bestDetection['x'] as num).toDouble();
           double cy = (bestDetection['y'] as num).toDouble();
           double w = (bestDetection['width'] as num).toDouble();
           double h = (bestDetection['height'] as num).toDouble();
           
           double x = cx - (w / 2);
           double y = cy - (h / 2);
           return [x, y, w, h];
        }
      }
      return null;

    } catch (e) {
      throw "预测错误: $e";
    }
  }
}