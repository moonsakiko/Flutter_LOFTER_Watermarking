import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class YoloService {
  ObjectDetector? _detector;
  bool isLoaded = false;

  // 初始化模型
  Future<void> initModel() async {
    if (isLoaded) return;

    try {
      // 这里的 modelPath 对应 assets/models/yolo_model.tflite
      _detector = ObjectDetector(modelPath: 'assets/models/yolo_model.tflite');
      
      // 加载模型
      await _detector!.load();
      isLoaded = true;
      print("✅ YOLO 模型加载成功");
    } catch (e) {
      print("❌ 模型加载失败: $e");
      throw Exception("无法加载模型，请检查 assets 目录");
    }
  }

  // 执行侦察
  // 返回检测到的对象列表
  Future<List<Map<String, double>>?> detect(String imagePath) async {
    if (!isLoaded) await initModel();

    // 读取图片并传给插件
    // 插件通常需要文件路径或二进制流，这里简化为路径调用
    // 注意：具体API可能随插件版本更新，这里基于通用逻辑编写
    try {
      final results = await _detector!.detect(imagePath: imagePath);
      
      // 转换结果为简单的坐标 Map 列表 [x, y, w, h]
      List<Map<String, double>> boxes = [];
      for (var result in results!) {
        // 过滤置信度 (Confidence Threshold)
        if ((result.confidence ?? 0) < 0.5) continue;
        
        final box = result.boundingBox;
        boxes.add({
          'x': box.left,
          'y': box.top,
          'w': box.width,
          'h': box.height,
          'conf': result.confidence ?? 0.0,
        });
      }
      return boxes;
    } catch (e) {
      print("推理出错: $e");
      return [];
    }
  }
  
  void dispose() {
    // 插件暂无明确 dispose，保留接口
  }
}