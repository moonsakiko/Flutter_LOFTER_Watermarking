import 'dart:io';
import 'package:image/image.dart' as img;

class ImageRepairRequest {
  final String wmPath;
  final String origPath;
  final List<int> region; // [x, y, w, h]
  final double expandW;
  final double expandH;

  ImageRepairRequest(this.wmPath, this.origPath, this.region, this.expandW, this.expandH);
}

class ImageProcessor {
  
  /// 执行修复操作
  static Future<List<int>?> repairImage(ImageRepairRequest req) async {
    try {
      // 1. 读取图片
      final wmBytes = await File(req.wmPath).readAsBytes();
      final origBytes = await File(req.origPath).readAsBytes();
      
      var wmImg = img.decodeImage(wmBytes);
      var origImg = img.decodeImage(origBytes);

      if (wmImg == null || origImg == null) return null;

      // 2. 确保无水印图尺寸与原图一致
      // 使用高质量插值算法
      if (origImg.width != wmImg.width || origImg.height != wmImg.height) {
        origImg = img.copyResize(origImg, width: wmImg.width, height: wmImg.height, interpolation: img.Interpolation.cubic);
      }

      // 3. 计算扩大的修复区域
      int x = req.region[0];
      int y = req.region[1];
      int w = req.region[2];
      int h = req.region[3];

      int marginW = (w * req.expandW / 2).toInt();
      int marginH = (h * req.expandH / 2).toInt();

      int finalX = (x - marginW).clamp(0, wmImg.width);
      int finalY = (y - marginH).clamp(0, wmImg.height);
      int finalW = (w + marginW * 2).clamp(0, wmImg.width - finalX);
      int finalH = (h + marginH * 2).clamp(0, wmImg.height - finalY);

      // 4. "移花接木"：从无水印图截取补丁
      final patch = img.copyCrop(origImg, x: finalX, y: finalY, width: finalW, height: finalH);

      // 5. 粘贴到有水印图上
      img.compositeImage(wmImg, patch, dstX: finalX, dstY: finalY);

      // 6. 返回 JPG 数据 (高质量)
      return img.encodeJpg(wmImg, quality: 100);
      
    } catch (e) {
      print("修复错误: $e");
      return null;
    }
  }
}