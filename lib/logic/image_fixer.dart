import 'dart:io';
import 'dart:math';
import 'package:image/image.dart' as img;

class ImageFixer {
  /// 执行修复
  /// [watermarkFile] 有水印图
  /// [cleanFile] 无水印图 (原图)
  /// [box] 水印区域 [x, y, w, h]
  /// [expandRatio] 扩大比例
  static Future<File?> fixImage({
    required File watermarkFile,
    required File cleanFile,
    required List<int> box,
    double expandW = 0.2,
    double expandH = 0.1,
    required String outputPath,
  }) async {
    try {
      // 1. 解码两张图片
      final wmImg = img.decodeImage(await watermarkFile.readAsBytes());
      final cleanImg = img.decodeImage(await cleanFile.readAsBytes());

      if (wmImg == null || cleanImg == null) return null;

      // 2. 确保无水印图尺寸与有水印图一致 (OpenCV resize logic)
      img.Image cleanResized;
      if (cleanImg.width != wmImg.width || cleanImg.height != wmImg.height) {
        cleanResized = img.copyResize(cleanImg, width: wmImg.width, height: wmImg.height, interpolation: img.Interpolation.cubic);
      } else {
        cleanResized = cleanImg;
      }

      // 3. 计算扩大的裁剪区域
      int x = box[0];
      int y = box[1];
      int w = box[2];
      int h = box[3];

      int wMargin = (w * expandW / 2).toInt();
      int hMargin = (h * expandH / 2).toInt();

      int finalX = max(0, x - wMargin);
      int finalY = max(0, y - hMargin);
      int finalXX = min(wmImg.width, x + w + wMargin);
      int finalYY = min(wmImg.height, y + h + hMargin);
      
      int patchW = finalXX - finalX;
      int patchH = finalYY - finalY;

      if (patchW <= 0 || patchH <= 0) return null;

      // 4. 从无水印图抠图 (Crop)
      final patch = img.copyCrop(cleanResized, x: finalX, y: finalY, width: patchW, height: patchH);

      // 5. 贴到有水印图上 (Paste)
      img.compositeImage(wmImg, patch, dstX: finalX, dstY: finalY);

      // 6. 保存
      final resultFile = File(outputPath);
      await resultFile.writeAsBytes(img.encodeJpg(wmImg, quality: 100));
      
      return resultFile;
    } catch (e) {
      print("修复出错: $e");
      return null;
    }
  }
}