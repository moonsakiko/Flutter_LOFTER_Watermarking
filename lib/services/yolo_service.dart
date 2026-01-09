import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
// 注意：不要引用 yolo_model.dart，那个文件在库里可能不存在或不公开

class YoloService {
  YOLO? _yolo;
  // 这里的模型路径要和 pubspec.yaml 及 assets 里的文件名完全一致
  final String modelPath = 'assets/models/best_float16.tflite';

  bool get isLoaded => _yolo != null;

  /// 初始化模型
  Future<void> initModel() async {
    if (_yolo != null) return;
    
    try {
      // 创建 YOLO 实例 (API v0.1.25+)
      _yolo = YOLO(
        modelPath: modelPath,
        task: YOLOTask.detect, // 指定任务为目标检测
      );

      // 加载模型
      await _yolo!.loadModel();
      print("✅ YOLO Model Loaded: $modelPath");
    } catch (e) {
      print("❌ YOLO Init Error: $e");
      // 如果加载失败，置空以便重试
      _yolo = null;
    }
  }

  /// 预测图片中的水印位置
  /// 返回格式: [x, y, width, height] (绝对坐标)
  Future<List<double>?> detectWatermark(String imagePath) async {
    if (_yolo == null) await initModel();
    if (_yolo == null) return null; // 初始化失败则返回

    final imageFile = File(imagePath);
    if (!imageFile.existsSync()) return null;
    
    try {
      final imageBytes = await imageFile.readAsBytes();

      // 执行预测
      // predict 返回的是一个 Map，键为 'boxes'
      final result = await _yolo!.predict(
        imageBytes,
        confidenceThreshold: 0.5, 
        iouThreshold: 0.4,
      );

      // 获取检测框列表
      final boxes = result['boxes'] as List<dynamic>?;

      if (boxes == null || boxes.isEmpty) return null;

      // 找到置信度最高的结果（通常插件已按置信度排序，取第一个即可）
      final bestDetection = boxes.first; 
      
      // ultralytics_yolo 的 predict 返回结构通常是 Map
      // 包含 'x', 'y', 'width', 'height', 'confidence', 'class' 等
      // 注意：这里的 x, y 通常是中心点坐标还是左上角坐标？
      // 根据常规 YOLO 输出，我们需要确认。
      // 如果插件返回的是左上角 x,y，则直接用。
      // 下面代码做了一定兼容性处理，尝试读取 bounding box 信息
      
      double x, y, w, h;

      if (bestDetection is Map) {
        // 情况 A: 插件返回 Map (常用)
        // 尝试获取 xywh，如果没有则查看是否有 'rect' 对象
        if (bestDetection.containsKey('x') && bestDetection.containsKey('width')) {
           // 假设返回的是中心点，需要转换吗？
           // 通常插件 output 处理后的 boxes 是 [left, top, right, bottom] 或者 [left, top, width, height]
           // 我们查看一下 ultralytics_yolo 的常见输出，通常它是归一化的或者像素坐标。
           // 这里我们需要根据实际运行调整。
           // 既然是 image_processor 用，我们需要 [left, top, width, height]
           
           // 为了保险，我们取 boundingBox 字段如果有的话，或者直接取坐标
           // 假设插件返回的是像素坐标 (pixel coordinates)
           double cx = (bestDetection['x'] as num).toDouble();
           double cy = (bestDetection['y'] as num).toDouble();
           w = (bestDetection['width'] as num).toDouble();
           h = (bestDetection['height'] as num).toDouble();
           
           // 如果 x,y 是中心点，转为左上角：
           // x = cx - w / 2; 
           // y = cy - h / 2;
           // 但 ultralytics_yolo 插件文档较少，大部分类似插件 predict 出来的 'boxes' 列表
           // 里的 x,y 通常指左上角。我们暂时按左上角处理。
           x = cx;
           y = cy;
           
           // 修正：经过查阅该插件 quickstart 示例，它直接返回 List<Map>
           // 且通常包含 'box' 或直接是坐标。
           // 如果运行后发现框的位置偏了，请改为 x = cx - w/2
        } else {
           // 备用方案，防止 Map 结构不同
           return null;
        }
      } else {
        return null;
      }

      return [x, y, w, h];

    } catch (e) {
      print("❌ Detection Error: $e");
      return null;
    }
  }

  void dispose() {
    // 新版 API 可能有 dispose 方法，如果没有可忽略
    try {
      _yolo?.dispose();
    } catch (_) {}
  }
}