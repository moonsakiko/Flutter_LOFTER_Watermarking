import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;

import '../services/yolo_service.dart';
import '../services/image_processor.dart';

class BatchModeScreen extends StatefulWidget {
  const BatchModeScreen({super.key});

  @override
  State<BatchModeScreen> createState() => _BatchModeScreenState();
}

class _BatchModeScreenState extends State<BatchModeScreen> {
  String? _selectedDirectory;
  List<Map<String, File>> _tasks = []; // {'wm': File, 'orig': File}
  final YoloService _yoloService = YoloService();
  
  bool _isScanning = false;
  bool _isProcessing = false;
  int _processedCount = 0;
  List<String> _logs = [];

  // 选择文件夹
  Future<void> _pickFolder() async {
    // Android 11+ 对文件夹权限限制很严，这里使用 FilePicker 选取目录
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    
    if (selectedDirectory != null) {
      setState(() {
        _selectedDirectory = selectedDirectory;
        _tasks.clear();
        _logs.clear();
      });
      _scanFolder();
    }
  }

  // 扫描并配对 (规则：xx-wm.jpg 和 xx-orig.jpg)
  Future<void> _scanFolder() async {
    setState(() => _isScanning = true);
    final dir = Directory(_selectedDirectory!);
    List<FileSystemEntity> files = dir.listSync();
    
    // 简单的正则匹配
    final wmRegex = RegExp(r'(.+)-wm\.(jpg|jpeg|png)$', caseSensitive: false);
    
    Map<String, File> wmFiles = {};
    List<File> allFiles = [];

    for (var entity in files) {
      if (entity is File) {
        allFiles.add(entity);
        final name = p.basename(entity.path);
        final match = wmRegex.firstMatch(name);
        if (match != null) {
          String baseKey = match.group(1)!; // 文件名去掉了 -wm.后缀
          wmFiles[baseKey] = entity;
        }
      }
    }

    List<Map<String, File>> pairs = [];
    
    for (var entry in wmFiles.entries) {
      // 寻找对应的 orig 文件 (不区分大小写)
      try {
        File? origFile = allFiles.firstWhere((f) {
          final fname = p.basename(f.path).toLowerCase();
          return fname.startsWith("${entry.key.toLowerCase()}-orig");
        });
        pairs.add({'wm': entry.value, 'orig': origFile});
        _addLog("✅ 匹配成功: ${p.basename(entry.value.path)}");
      } catch (e) {
        _addLog("⚠️ 未找到原图: ${p.basename(entry.value.path)}");
      }
    }

    setState(() {
      _tasks = pairs;
      _isScanning = false;
    });
  }

  void _addLog(String log) {
    setState(() {
      _logs.insert(0, log);
    });
  }

  // 开始批量处理
  Future<void> _startBatchProcess() async {
    if (_tasks.isEmpty) return;
    setState(() {
      _isProcessing = true;
      _processedCount = 0;
    });

    // 创建输出文件夹
    final outputDir = Directory(p.join(_selectedDirectory!, "Repaired_Output"));
    if (!await outputDir.exists()) {
      await outputDir.create();
    }

    for (var task in _tasks) {
      File wm = task['wm']!;
      File orig = task['orig']!;
      
      try {
        final wmBytes = await wm.readAsBytes();
        final origBytes = await orig.readAsBytes();

        final boxes = await _yoloService.detectWatermark(wmBytes);
        
        if (boxes.isNotEmpty) {
          final result = await ImageProcessor.repairImage(wmBytes, origBytes, boxes);
          if (result != null) {
             final savePath = p.join(outputDir.path, p.basename(wm.path));
             await File(savePath).writeAsBytes(result);
             _addLog("✨ 修复完成: ${p.basename(wm.path)}");
          } else {
             _addLog("❌ 修复失败(解码误): ${p.basename(wm.path)}");
          }
        } else {
          _addLog("⚪ 无水印跳过: ${p.basename(wm.path)}");
        }
      } catch (e) {
        _addLog("❌ 错误: ${p.basename(wm.path)} - $e");
      }

      setState(() {
        _processedCount++;
      });
    }

    setState(() => _isProcessing = false);
    Fluttertoast.showToast(msg: "批量处理完成！请查看 Repaired_Output 文件夹");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("批量自动处理")),
      body: Column(
        children: [
          ListTile(
            tileColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            title: Text(_selectedDirectory ?? "点击选择包含图片的文件夹"),
            subtitle: const Text("需包含 *-wm.jpg 和 *-orig.jpg 文件"),
            trailing: const Icon(Icons.folder_open),
            onTap: _isProcessing ? null : _pickFolder,
          ),
          
          if (_isScanning) const LinearProgressIndicator(),
          if (_isProcessing) 
            LinearProgressIndicator(value: _tasks.isEmpty ? 0 : _processedCount / _tasks.length),

          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("匹配任务: ${_tasks.length} 对"),
                FilledButton(
                  onPressed: (_tasks.isEmpty || _isProcessing) ? null : _startBatchProcess,
                  child: Text(_isProcessing ? "处理中 ($_processedCount/${_tasks.length})" : "开始批量修复"),
                )
              ],
            ),
          ),

          Expanded(
            child: Container(
              color: Colors.black87,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (context, index) => Text(
                  _logs[index], 
                  style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          )
        ],
      ),
    );
  }
}