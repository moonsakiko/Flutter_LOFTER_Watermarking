import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageLogic {
  /// 核心修复函数
  /// [wmFile]: 有水印图 (High Res)
  /// [cleanFile]: 无水印图 (Low Res)
  /// [box]: YOLO 识别出的区域 [x, y, w, h] (绝对坐标)
  /// 返回修复后的图片数据
  static Future<Uint8List?> repairImage({
    required File wmFile,
    required File cleanFile,
    required List<int> box, // [x, y, w, h]
    double widthExpansion = 0.2,
    double heightExpansion = 0.1,
  }) async {
    try {
      // 1. 读取图片
      final wmBytes = await wmFile.readAsBytes();
      final cleanBytes = await cleanFile.readAsBytes();
      
      var wmImage = img.decodeImage(wmBytes);
      var cleanImage = img.decodeImage(cleanBytes);

      if (wmImage == null || cleanImage == null) return null;

      // 2. 自动修正方向 (处理手机拍照旋转问题)
      wmImage = img.bakeOrientation(wmImage);
      cleanImage = img.bakeOrientation(cleanImage);

      int wHigh = wmImage.width;
      int hHigh = wmImage.height;

      // 3. 解析 YOLO 坐标并扩大范围
      int x = box[0];
      int y = box[1];
      int w = box[2];
      int h = box[3];

      int wMargin = (w * widthExpansion ~/ 2);
      int hMargin = (h * heightExpansion ~/ 2);

      int xStart = (x - wMargin).clamp(0, wHigh);
      int yStart = (y - hMargin).clamp(0, hHigh);
      int xEnd = (x + w + wMargin).clamp(0, wHigh);
      int yEnd = (y + h + hMargin).clamp(0, hHigh);

      int patchW = xEnd - xStart;
      int patchH = yEnd - yStart;

      if (patchW <= 0 || patchH <= 0) return null;

      // 4. 将无水印图缩放到有水印图的大小 (模拟 Lanczos4，Dart用Cubic)
      // 注意：为了性能，我们不一定要缩放整张大图，但为了对齐准确，缩放整图最稳
      var cleanResized = img.copyResize(
        cleanImage,
        width: wHigh,
        height: hHigh,
        interpolation: img.Interpolation.cubic, // 高质量缩放
      );

      // 5. 裁剪补丁 (从无水印图切下来)
      var cleanPatch = img.copyCrop(
        cleanResized,
        x: xStart,
        y: yStart,
        width: patchW,
        height: patchH,
      );

      // 6. 粘贴补丁 (贴到有水印图上)
      // copyInto 将 src 绘制到 dst 上
      img.compositeImage(
        wmImage,
        cleanPatch,
        dstX: xStart,
        dstY: yStart,
      );

      // 7. 编码为 JPG
      return img.encodeJpg(wmImage, quality: 98);
    } catch (e) {
      print("修复错误: $e");
      return null;
    }
  }
}