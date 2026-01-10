import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

class Cleaner {
  /// 核弹级清理：直接删除缓存文件夹里的所有文件
  static Future<void> nukeCache() async {
    try {
      // 1. 先礼：调用插件自带清理
      await FilePicker.platform.clearTemporaryFiles();

      // 2. 后兵：手动遍历缓存目录并删除
      final cacheDir = await getTemporaryDirectory();
      if (cacheDir.existsSync()) {
        cacheDir.listSync().forEach((FileSystemEntity entity) {
          try {
            if (entity is File) {
              // 这里的逻辑是：删除 file_picker 开头的文件，或者是 jpg/png 图片
              // 为了防止误删重要数据，我们只删 file_picker 缓存
              if (entity.path.contains('file_picker')) {
                entity.deleteSync();
              }
            } else if (entity is Directory) {
              if (entity.path.contains('file_picker')) {
                entity.deleteSync(recursive: true);
              }
            }
          } catch (e) {
            // 忽略个别无法删除的文件
          }
        });
      }
      print("🧹 强力清理完成");
    } catch (e) {
      print("清理失败: $e");
    }
  }
}