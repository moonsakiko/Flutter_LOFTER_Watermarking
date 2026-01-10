import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import '../services/yolo_service.dart';
import '../services/image_logic.dart';

class BatchFixPage extends StatefulWidget {
  const BatchFixPage({super.key});

  @override
  State<BatchFixPage> createState() => _BatchFixPageState();
}

class _BatchFixPageState extends State<BatchFixPage> {
  String? selectedDir;
  List<Map<String, File>> tasks = []; // [{'wm': file, 'clean': file}]
  List<String> logs = [];
  bool isProcessing = false;
  double progress = 0.0;
  
  final YoloService _yolo = YoloService();

  @override
  void initState() {
    super.initState();
    _yolo.loadModel();
  }

  Future<void> _pickFolder() async {
    // 请求管理权限 (批量读写必须)
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      await Permission.manageExternalStorage.request();
    }

    String? path = await FilePicker.platform.getDirectoryPath();
    if (path != null) {
      setState(() {
        selectedDir = path;
        logs.clear();
        _scanFiles(path);
      });
    }
  }

  void _scanFiles(String dirPath) {
    final dir = Directory(dirPath);
    List<FileSystemEntity> files = dir.listSync();
    
    tasks.clear();
    Map<String, File> wmMap = {};
    Map<String, File> cleanMap = {};

    // 1. 分类
    for (var entity in files) {
      if (entity is File) {
        String name = p.basenameWithoutExtension(entity.path).toLowerCase();
        if (name.endsWith("-wm")) {
          String key = name.replaceAll("-wm", "");
          wmMap[key] = entity;
        } else if (name.endsWith("-orig")) { // 这里兼容你的Python脚本命名规则
          String key = name.replaceAll("-orig", "");
          cleanMap[key] = entity;
        }
      }
    }

    // 2. 配对
    wmMap.forEach((key, wmFile) {
      if (cleanMap.containsKey(key)) {
        tasks.add({'wm': wmFile, 'clean': cleanMap[key]!});
      }
    });

    setState(() {
      logs.add("扫描完成: 找到 ${tasks.length} 对图片");
    });
  }

  Future<void> _startBatch() async {
    if (tasks.isEmpty) return;
    setState(() { isProcessing = true; progress = 0; });

    // 创建输出目录
    String outPath = p.join(selectedDir!, "已修复图片");
    await Directory(outPath).create(recursive: true);

    int success = 0;
    for (int i = 0; i < tasks.length; i++) {
      var task = tasks[i];
      File wm = task['wm']!;
      File clean = task['clean']!;
      String name = p.basename(wm.path);

      setState(() { logs.add("正在处理: $name ..."); });

      try {
        // 侦测
        var box = await _yolo.detect(wm, confThreshold: 0.5);
        if (box != null) {
          // 修复
          var bytes = await ImageLogic.repairImage(wmFile: wm, cleanFile: clean, box: box);
          if (bytes != null) {
            File outFile = File(p.join(outPath, name));
            await outFile.writeAsBytes(bytes);
            success++;
            setState(() { logs.add("✅ 成功"); });
          } else {
            setState(() { logs.add("❌ 修复失败"); });
          }
        } else {
          setState(() { logs.add("⚠️ 未检测到水印"); });
        }
      } catch (e) {
        setState(() { logs.add("❌ 异常: $e"); });
      }

      setState(() {
        progress = (i + 1) / tasks.length;
      });
      // 给 UI 喘息时间
      await Future.delayed(const Duration(milliseconds: 50));
    }

    setState(() {
      isProcessing = false;
      logs.add("🎉 处理结束! 成功: $success / ${tasks.length}");
      logs.add("文件已保存至: $outPath");
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("批量模式")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: isProcessing ? null : _pickFolder,
              icon: const Icon(Icons.folder_open),
              label: Text(selectedDir ?? "选择文件夹"),
            ),
            const SizedBox(height: 10),
            if (tasks.isNotEmpty) 
              Text("待处理: ${tasks.length} 对", style: const TextStyle(fontWeight: FontWeight.bold)),
            
            const Divider(),
            Expanded(
              child: Container(
                color: Colors.black12,
                child: ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (c, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(logs[i], style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (isProcessing) LinearProgressIndicator(value: progress),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (isProcessing || tasks.isEmpty) ? null : _startBatch,
                child: const Text("全部开始"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}