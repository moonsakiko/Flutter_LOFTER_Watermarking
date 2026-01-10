import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:path_provider/path_provider.dart';
import '../logic/yolo_service.dart';
import '../logic/image_fixer.dart';

class BatchModeScreen extends StatefulWidget {
  const BatchModeScreen({super.key});

  @override
  State<BatchModeScreen> createState() => _BatchModeScreenState();
}

class _BatchModeScreenState extends State<BatchModeScreen> {
  List<File> _allFiles = [];
  List<Map<String, File>> _pairs = []; // [{'wm': file, 'clean': file}]
  bool _isProcessing = false;
  String _log = "请选择包含成对图片的文件夹或多个文件";
  double _confThreshold = 0.5;
  final YoloService _yoloService = YoloService();

  @override
  void initState() {
    super.initState();
    _yoloService.loadModel();
  }

  Future<void> _pickFiles() async {
    // 允许用户多选文件
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );

    if (result != null) {
      setState(() {
        _allFiles = result.paths.map((path) => File(path!)).toList();
        _autoMatchPairs();
      });
    }
  }

  void _autoMatchPairs() {
    _pairs.clear();
    // 简单的匹配逻辑：寻找 *-wm.jpg 和 *-orig.jpg (或者包含 wm/orig 关键字)
    // 这里的逻辑对应你Python脚本里的正则
    
    // 1. 找所有水印图
    var wmFiles = _allFiles.where((f) => f.path.toLowerCase().contains("-wm.") || f.path.toLowerCase().contains("wm")).toList();
    
    for (var wmFile in wmFiles) {
      String wmPath = wmFile.path;
      // 尝试构造原图路径规则：把 -wm 替换成 -orig
      // 简单起见，我们查找同目录下名字相似但不含 wm 且含 orig 的
      // 或者：假设文件名是 name-wm.jpg -> name-orig.jpg
      
      String cleanNameGuess = wmPath.replaceAll("-wm", "-orig").replaceAll("wm", "orig");
      
      try {
        var cleanFile = _allFiles.firstWhere(
          (f) => f.path == cleanNameGuess || 
                 (f.parent.path == wmFile.parent.path && f.path.contains("-orig") && wmPath.startsWith(f.path.replaceAll("-orig", "").split('.').first))
          // 这里的匹配逻辑比较简陋，实际使用建议严格命名
        );
        _pairs.add({'wm': wmFile, 'clean': cleanFile});
      } catch (e) {
        // 没找到配对
      }
    }
    
    setState(() {
      _log = "已加载 ${_allFiles.length} 个文件\n自动匹配到 ${_pairs.length} 对图片";
    });
  }

  Future<void> _startBatchProcess() async {
    if (_pairs.isEmpty) return;
    setState(() => _isProcessing = true);
    
    int success = 0;
    int fail = 0;
    final tempDir = await getTemporaryDirectory();

    for (int i = 0; i < _pairs.length; i++) {
      var pair = _pairs[i];
      setState(() => _log = "正在处理 (${i+1}/${_pairs.length})...");
      
      try {
        // 侦测
        final boxes = await _yoloService.detect(pair['wm']!, _confThreshold);
        if (boxes.isNotEmpty) {
           final savePath = "${tempDir.path}/batch_fixed_${i}_${DateTime.now().millisecondsSinceEpoch}.jpg";
           final result = await ImageFixer.fixImage(
            watermarkFile: pair['wm']!,
            cleanFile: pair['clean']!,
            box: boxes.first,
            outputPath: savePath,
          );
          
          if (result != null) {
            await GallerySaver.saveImage(result.path);
            success++;
          } else {
            fail++;
          }
        } else {
          fail++; // 没测到水印
        }
      } catch (e) {
        fail++;
      }
    }

    setState(() {
      _isProcessing = false;
      _log = "处理完成！\n成功: $success 张\n失败: $fail 张\n结果已保存到相册";
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          ElevatedButton.icon(
            onPressed: _pickFiles,
            icon: const Icon(Icons.folder_open),
            label: const Text("选择多张图片 (包含 -wm 和 -orig)"),
            style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!)
              ),
              child: SingleChildScrollView(child: Text(_log)),
            ),
          ),
          const SizedBox(height: 10),
          Text("置信度: ${_confThreshold.toStringAsFixed(2)}"),
          Slider(value: _confThreshold, min: 0.1, max: 0.9, onChanged: (v)=>setState(()=>_confThreshold=v)),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: (_pairs.isNotEmpty && !_isProcessing) ? _startBatchProcess : null,
            child: Text(_isProcessing ? "处理中..." : "开始批量处理 (${_pairs.length}对)"),
            style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
          ),
        ],
      ),
    );
  }
}