import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:lofter_repair/services/yolo_service.dart';
import 'package:lofter_repair/services/image_processor.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class BatchModeScreen extends StatefulWidget {
  const BatchModeScreen({super.key});

  @override
  State<BatchModeScreen> createState() => _BatchModeScreenState();
}

class _BatchModeScreenState extends State<BatchModeScreen> {
  List<File> _files = [];
  List<Map<String, File>> _pairs = []; // [{'wm': file, 'orig': file}]
  bool _isProcessing = false;
  String _log = "";
  double _progress = 0.0;
  
  final YoloService _yolo = YoloService();

  @override
  void initState() {
    super.initState();
    _yolo.loadModel();
  }

  Future<void> _pickFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );

    if (result != null) {
      setState(() {
        _files = result.paths.where((p) => p != null).map((p) => File(p!)).toList();
        _matchPairs();
      });
    }
  }

  /// 自动配对逻辑
  void _matchPairs() {
    Map<String, File> wmMap = {};
    Map<String, File> origMap = {};
    
    // 1. 分类
    for (var f in _files) {
      String name = p.basenameWithoutExtension(f.path).toLowerCase();
      if (name.endsWith("-wm") || name.endsWith("_wm")) {
        String key = name.replaceAll(RegExp(r'[-_]wm$'), '');
        wmMap[key] = f;
      } else if (name.endsWith("-orig") || name.endsWith("_orig") || name.endsWith("-raw")) {
        String key = name.replaceAll(RegExp(r'[-_](orig|raw)$'), '');
        origMap[key] = f;
      }
    }

    // 2. 配对
    _pairs.clear();
    wmMap.forEach((key, wmFile) {
      if (origMap.containsKey(key)) {
        _pairs.add({'wm': wmFile, 'orig': origMap[key]!});
      }
    });

    setState(() {});
  }

  Future<void> _runBatch() async {
    if (_pairs.isEmpty) return;
    setState(() {
      _isProcessing = true;
      _log = "开始任务...\n";
      _progress = 0;
    });

    int total = _pairs.length;
    int success = 0;

    for (int i = 0; i < total; i++) {
      var pair = _pairs[i];
      File wmFile = pair['wm']!;
      File origFile = pair['orig']!;
      
      setState(() => _log += "正在处理: ${p.basename(wmFile.path)}...\n");

      try {
        final wmBytes = await wmFile.readAsBytes();
        final wmDecoded = img.decodeImage(wmBytes);
        
        if (wmDecoded != null) {
          final bbox = await _yolo.detectWatermark(wmDecoded, 0.5);
          if (bbox != null) {
            final req = ImageRepairRequest(wmFile.path, origFile.path, bbox, 0.2, 0.1);
            final res = await compute(ImageProcessor.repairImage, req);
            if (res != null) {
              String tempPath = '${wmFile.path}_fixed.jpg';
              await File(tempPath).writeAsBytes(res);
              await Gal.putImage(tempPath);
              success++;
              setState(() => _log += "  -> ✅ 成功\n");
            } else {
              setState(() => _log += "  -> ❌ 修复失败\n");
            }
          } else {
            setState(() => _log += "  -> ⚠️ 未发现水印\n");
          }
        }
      } catch (e) {
        setState(() => _log += "  -> ❌ 错误: $e\n");
      }

      setState(() => _progress = (i + 1) / total);
    }

    setState(() {
      _isProcessing = false;
      _log += "\n任务结束。成功: $success / $total";
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("批量处理工厂")),
      body: Column(
        children: [
          // 顶部操作区
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              children: [
                const Text("规则：必须包含 -wm (水印) 和 -orig (无水印原图) 结尾的文件", style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickFiles,
                        icon: const Icon(Icons.folder_open),
                        label: const Text("选择所有图片"),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (_pairs.isNotEmpty && !_isProcessing) ? _runBatch : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text("开始执行"),
                      ),
                    ),
                  ],
                ),
                if (_pairs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text("✅ 已自动配对 ${_pairs.length} 组图片", style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
          ),
          
          if (_isProcessing)
            LinearProgressIndicator(value: _progress),

          // 日志/列表区
          Expanded(
            child: _files.isEmpty 
              ? const Center(child: Text("请点击左上角选择一堆图片\nAPP会自动按文件名配对", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
              : Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  color: const Color(0xFF222222),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Text(_log.isEmpty ? "等待任务开始..." : _log, style: const TextStyle(color: Colors.greenAccent, fontFamily: "monospace")),
                  ),
                ),
          ),
        ],
      ),
    );
  }
}