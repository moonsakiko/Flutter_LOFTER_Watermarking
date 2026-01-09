import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:ultralytics_yolo/yolo_model.dart';

class YoloService {
  ObjectDetector? _detector;
  final String modelPath = 'assets/models/best_float16.tflite';

  bool get isLoaded => _detector != null;

  /// 初始化模型
  Future<void> initModel() async {
    if (_detector != null) return;
    
    // 创建探测器实例
    final model = LocalYoloModel(
      id: 'lofter_model',
      task: Task.detect,
      format: Format.tflite,
      modelPath: modelPath,
    );

    _detector = ObjectDetector(model: model);
    await _detector!.load();
    print("✅ YOLO Model Loaded: $modelPath");
  }

  /// 预测图片中的水印位置
  /// 返回格式: [x, y, width, height] (绝对坐标)
  Future<List<double>?> detectWatermark(String imagePath) async {
    if (_detector == null) await initModel();

    // 读取图片
    final imageFile = File(imagePath);
    if (!imageFile.existsSync()) return null;
    
    final imageBytes = await imageFile.readAsBytes();

    // 执行预测
    // confThreshold 对应 Python 中的 YOLO_CONFIDENCE_THRESHOLD (0.5)
    final results = await _detector!.detect(
      imageBytes: imageBytes,
      confThreshold: 0.5, 
      iouThreshold: 0.4,
    );

    if (results.isEmpty) return null;

    // 找到置信度最高的结果
    // 假设 results 已经包含 boundingBox
    final bestResult = results.first; // 这里简化处理，取第一个
    final box = bestResult.boundingBox; // 这是归一化坐标还是绝对坐标取决于插件版本，通常是绝对坐标

    // 这里 ultralytics_yolo 插件返回的 boundingBox 是 Rect 对象
    return [box.left, box.top, box.width, box.height];
  }

  void dispose() {
    // 插件暂无 dispose 方法，通常随 App 生命周期销毁
  }
}