import 'dart:io';
import 'dart:math';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class RepairService {
  // Python 中的配置常量
  static const double WIDTH_EXPANSION_RATIO = 0.20;
  static const double HEIGHT_EXPANSION_RATIO = 0.10;
  
  /// 核心修复逻辑
  /// [wmPath]: 水印图路径
  /// [origPath]: 原图路径
  /// [boxes]: YOLO 识别出的所有框
  /// 返回: 修复后的图片文件对象
  static Future<File?> processImage(
      String wmPath, String origPath, List<Map<String, double>> boxes) async {
    
    // 1. 读取图片 (耗时操作，放这里)
    final wmBytes = await File(wmPath).readAsBytes();
    final origBytes = await File(origPath).readAsBytes();
    
    img.Image? wmImage = img.decodeImage(wmBytes);
    img.Image? origImage = img.decodeImage(origBytes);

    if (wmImage == null || origImage == null) return null;

    // 2. 计算包围所有水印的大框 (Python 逻辑复刻)
    if (boxes.isEmpty) return null; // 没识别到水印

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (var box in boxes) {
      minX = min(minX, box['x']!);
      minY = min(minY, box['y']!);
      maxX = max(maxX, box['x']! + box['w']!);
      maxY = max(maxY, box['y']! + box['h']!);
    }

    // 3. 扩大修复区域 (Expansion)
    double width = maxX - minX;
    double height = maxY - minY;
    
    double widthMargin = (width * WIDTH_EXPANSION_RATIO) / 2;
    double heightMargin = (height * HEIGHT_EXPANSION_RATIO) / 2;

    int finalX = max(0, (minX - widthMargin).toInt());
    int finalY = max(0, (minY - heightMargin).toInt());
    int finalW = min(wmImage.width - finalX, (width + widthMargin * 2).toInt());
    int finalH = min(wmImage.height - finalY, (height + heightMargin * 2).toInt());

    // 4. 处理原图 (Resize)
    // 必须把原图缩放到和水印图一样大，才能对齐坐标
    img.Image resizedOrig = img.copyResize(
      origImage, 
      width: wmImage.width, 
      height: wmImage.height,
      interpolation: img.Interpolation.cubic // 相当于 cv2.INTER_LANCZOS4
    );

    // 5. 裁剪补丁 (Crop)
    // 从缩放后的原图中，切下“干净”的一块
    img.Image cleanPatch = img.copyCrop(
      resizedOrig, 
      x: finalX, 
      y: finalY, 
      width: finalW, 
      height: finalH
    );

    // 6. 粘贴修复 (Paste)
    // 将干净补丁覆盖到水印图上
    img.compositeImage(
      wmImage, 
      cleanPatch, 
      dstX: finalX, 
      dstY: finalY
    );

    // 7. 保存结果到临时文件
    final tempDir = Directory.systemTemp;
    final fileName = 'repaired_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final resultFile = File(p.join(tempDir.path, fileName));
    
    await resultFile.writeAsBytes(img.encodeJpg(wmImage, quality: 98));
    
    return resultFile;
  }
}