import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class YoloService {
  YOLO? _yolo;
  final String modelPath = 'best_float16.tflite'; // 对应assets里的文件名

  // 初始化模型
  Future<void> init() async {
    if (_yolo != null) return;
    
    // 检查模型文件是否存在
    // 注意：ultralytics_yolo 插件通常需要模型在 assets 中
    try {
      _yolo = YOLO(
        modelPath: 'assets/models/$modelPath', // 这里的路径可能需要根据插件实际要求调整，通常直接写文件名如果放在assets根目录，但最好写全
        task: YOLOTask.detect,
      );
      // 实际上插件加载方式：Android放在assets/models下通常直接传文件名即可，这里为了稳妥
      // 如果云打包后加载失败，请尝试只传 'best_float16' (不带后缀)
    } catch (e) {
      print("模型加载初始化出错: $e");
    }
  }

  // 预测水印位置
  Future<List<Map<String, dynamic>>> detectWatermark(Uint8List imageBytes) async {
    if (_yolo == null) {
      await init();
    }
    
    try {
      // 加载模型（如果尚未加载）
      // 注意：插件文档建议在使用前 load
      await _yolo!.loadModel(); 
      
      final result = await _yolo!.predict(imageBytes, confidenceThreshold: 0.3);
      
      // 提取边界框 boxes
      // 插件返回的结构通常包含 'boxes' 列表
      final boxes = result['boxes'] as List<dynamic>? ?? [];
      
      return boxes.cast<Map<String, dynamic>>();
    } catch (e) {
      print("AI识别失败: $e");
      return [];
    }
  }
  
  void dispose() {
    _yolo?.dispose();
  }
}