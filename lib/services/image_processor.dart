import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// 这是一个纯计算类，建议在 compute 中调用
class ImageProcessor {
  
  /// 核心修复逻辑
  /// [wmBytes] 有水印的高清图数据
  /// [origBytes] 无水印的低清图数据
  /// [detectionBoxes] YOLO识别出的水印位置列表
  static Future<Uint8List?> repairImage(
    Uint8List wmBytes, 
    Uint8List origBytes, 
    List<Map<String, dynamic>> detectionBoxes
  ) async {
    // 1. 解码图片
    final wmImage = img.decodeImage(wmBytes);
    final origImage = img.decodeImage(origBytes);

    if (wmImage == null || origImage == null) return null;

    // 2. 将低清原图放大到高清图尺寸 (使用高质量插值)
    // 对应 Python: cv2.resize(..., interpolation=cv2.INTER_LANCZOS4)
    // Dart image 库的 cubic 插值接近 Lanczos
    final resizedOrig = img.copyResize(
      origImage, 
      width: wmImage.width, 
      height: wmImage.height, 
      interpolation: img.Interpolation.cubic
    );

    // 3. 遍历所有检测到的水印框进行覆盖
    for (var box in detectionBoxes) {
      // 插件返回的 box 格式通常包含 x, y, width, height (归一化或像素值，需确认插件返回)
      // 假设 ultralytics_yolo 返回的是像素坐标 (根据文档示例)
      // 如果是归一化(0-1)，需要乘以宽高。这里假设是像素值。
      
      // 安全获取坐标
      int x = (box['x'] as num).toInt();
      int y = (box['y'] as num).toInt();
      int w = (box['width'] as num).toInt();
      int h = (box['height'] as num).toInt();

      // 4. 扩大修复区域 (对应 Python 的 EXPANSION_RATIO)
      double widthExpansion = 0.2;
      double heightExpansion = 0.1;
      
      int marginW = (w * widthExpansion / 2).toInt();
      int marginH = (h * heightExpansion / 2).toInt();
      
      int startX = (x - marginW).clamp(0, wmImage.width);
      int startY = (y - marginH).clamp(0, wmImage.height);
      int endX = (x + w + marginW).clamp(0, wmImage.width);
      int endY = (y + h + marginH).clamp(0, wmImage.height);
      
      int patchW = endX - startX;
      int patchH = endY - startY;

      if (patchW <= 0 || patchH <= 0) continue;

      // 5. 从放大后的原图中裁剪出干净的补丁
      final cleanPatch = img.copyCrop(resizedOrig, x: startX, y: startY, width: patchW, height: patchH);
      
      // 6. 贴回到有水印的图上
      img.compositeImage(wmImage, cleanPatch, dstX: startX, dstY: startY);
    }

    // 7. 编码回 JPG
    return Uint8List.fromList(img.encodeJpg(wmImage, quality: 98));
  }
}