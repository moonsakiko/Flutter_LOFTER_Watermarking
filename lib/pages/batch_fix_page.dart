import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../logic/yolo_service.dart';

class BatchFixPage extends StatefulWidget {
  const BatchFixPage({super.key});

  @override
  State<BatchFixPage> createState() => _BatchFixPageState();
}

class _BatchFixPageState extends State<BatchFixPage> {
  List<File> _selectedFiles = [];
  List<String> _logs = [];
  bool _isProcessing = false;
  final YoloService _yoloService = YoloService();

  Future<void> _pickFiles() async {
    // 请求存储权限
    await Permission.storage.request();
    
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );

    if (result != null) {
      setState(() {
        _selectedFiles = result.paths.where((path) => path != null).map((path) => File(path!)).toList();
        _logs = ["已选择 ${_selectedFiles.length} 个文件，准备处理..."];
      });
    }
  }

  Future<void> _startBatchProcess() async {
    if (_selectedFiles.isEmpty) return;
    
    setState(() {
      _isProcessing = true;
      _logs.add("🚀 开始批量任务...");
    });

    // 加载配置
    final prefs = await SharedPreferences.getInstance();
    _yoloService.confidenceThreshold = prefs.getDouble('confidence') ?? 0.5;

    // 自动配对逻辑
    // 假设命名规则： xxx-wm.jpg (水印) 和 xxx-orig.jpg (原图/无水印)
    
    // 1. 寻找水印图
    var wmFiles = _selectedFiles.where((f) => p.basename(f.path).contains("wm")).toList();
    
    for (var wmFile in wmFiles) {
      String baseName = p.basename(wmFile.path).replaceAll("-wm", "").replaceAll("wm", ""); 
      // 尝试找对应的原图
      File? noWmFile;
      try {
        noWmFile = _selectedFiles.firstWhere(
          (f) => f.path != wmFile.path && p.basename(f.path).contains(baseName)
        );
      } catch (e) {
        noWmFile = null;
      }

      if (noWmFile != null) {
        _addLog("正在处理: ${p.basename(wmFile.path)}...");
        try {
          var result = await _yoloService.repairImage(wmFile.path, noWmFile.path);
          if (result != null) {
            // 保存到同一目录，加前缀 repaired_
            String newPath = p.join(p.dirname(wmFile.path), "repaired_${p.basename(wmFile.path)}");
            await File(newPath).writeAsBytes(result);
            _addLog("✅ 成功! 已保存至: repaired_${p.basename(wmFile.path)}");
          } else {
             _addLog("⚠️ 未检测到水印: ${p.basename(wmFile.path)}");
          }
        } catch (e) {
          _addLog("❌ 出错: $e");
        }
      } else {
        _addLog("⚠️ 跳过: 找不到 ${p.basename(wmFile.path)} 的对应原图");
      }
    }

    setState(() {
      _isProcessing = false;
      _logs.add("🏁 任务完成!");
    });
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("批量处理")),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            // 👈 关键修复：改为 surfaceVariant 以兼容旧版 Flutter
            color: Theme.of(context).colorScheme.surfaceVariant, 
            child: Column(
              children: [
                const Text("使用说明：请同时选择“水印图”和“无水印图”。\n系统将根据文件名自动配对 (如 A-wm.jpg 和 A-orig.jpg)"),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isProcessing ? null : _pickFiles,
                        icon: const Icon(Icons.folder_open),
                        label: const Text("选择多张图片"),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (_isProcessing || _selectedFiles.isEmpty) ? null : _startBatchProcess,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text("开始执行"),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                return Text(_logs[index], style: const TextStyle(fontSize: 12));
              },
            ),
          ),
        ],
      ),
    );
  }
}