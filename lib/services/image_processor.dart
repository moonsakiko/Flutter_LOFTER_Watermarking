import 'dart:io';
import 'dart:math';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class ImageProcessor {
  // 配置参数，对应 Python 脚本中的 Expansion Ratio
  static const double widthExpansionRatio = 0.20;
  static const double heightExpansionRatio = 0.10;

  /// 执行修复逻辑
  /// [wmPath] 水印图路径
  /// [origPath] 原图路径
  /// [box] 水印区域 [x, y, w, h]
  Future<File> repairImage(String wmPath, String origPath, List<double> box) async {
    // 1. 解码图片 (这是一个耗时操作，建议放在 compute 中，但为了代码简单直接写异步)
    final wmBytes = await File(wmPath).readAsBytes();
    final origBytes = await File(origPath).readAsBytes();

    img.Image? wmImage = img.decodeImage(wmBytes);
    img.Image? origImage = img.decodeImage(origBytes);

    if (wmImage == null || origImage == null) {
      throw Exception("无法解码图片文件");
    }

    // 2. 计算修复区域 (逻辑复刻 Python)
    int x = box[0].toInt();
    int y = box[1].toInt();
    int w = box[2].toInt();
    int h = box[3].toInt();

    // 扩大选区
    int wMargin = ((w * widthExpansionRatio) / 2).toInt();
    int hMargin = ((h * heightExpansionRatio) / 2).toInt();

    int startX = max(0, x - wMargin);
    int startY = max(0, y - hMargin);
    int endX = min(wmImage.width, x + w + wMargin);
    int endY = min(wmImage.height, y + h + hMargin);

    int patchW = endX - startX;
    int patchH = endY - startY;

    if (patchW <= 0 || patchH <= 0) {
      throw Exception("计算出的修复区域无效");
    }

    // 3. 将低清原图 Resize 到高清图尺寸
    // 使用 cubic 插值模拟 Lanczos4，效果较好
    img.Image resizedOrig = img.copyResize(
      origImage,
      width: wmImage.width,
      height: wmImage.height,
      interpolation: img.Interpolation.cubic,
    );

    // 4. 裁剪补丁 (从放大后的原图中裁剪)
    img.Image cleanPatch = img.copyCrop(
      resizedOrig,
      x: startX,
      y: startY,
      width: patchW,
      height: patchH,
    );

    // 5. 粘贴补丁 (覆盖到高清有水印图上)
    img.compositeImage(
      wmImage,
      cleanPatch,
      dstX: startX,
      dstY: startY,
    );

    // 6. 保存结果
    final appDir = await getApplicationDocumentsDirectory();
    final fileName = 'fixed_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final savePath = path.join(appDir.path, fileName);
    
    // 编码为 JPG，质量 98
    final encoded = img.encodeJpg(wmImage, quality: 98);
    final resultFile = File(savePath);
    await resultFile.writeAsBytes(encoded);

    return resultFile;
  }
}