import 'dart:io';

/// 用于描述一对图片任务
class ProcessTask {
  final File wmFile;    // 有水印图 (High Res)
  final File origFile;  // 原图 (Low Res)
  File? resultFile;     // 处理后的结果图
  String status;        // waiting, processing, success, failed, no_wm_found
  String? errorMsg;

  ProcessTask({
    required this.wmFile,
    required this.origFile,
    this.status = 'waiting',
  });
}