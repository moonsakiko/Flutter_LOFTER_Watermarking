import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../services/yolo_service.dart';
import '../services/repair_service.dart';

class BatchModePage extends StatefulWidget {
  const BatchModePage({super.key});

  @override
  State<BatchModePage> createState() => _BatchModePageState();
}

class _BatchModePageState extends State<BatchModePage> {
  String? selectedDir;
  List<Map<String, String>> tasks = []; // {wm: path, orig: path}
  List<String> logs = [];
  bool isRunning = false;
  int successCount = 0;
  int failCount = 0;

  Future<void> _pickFolder() async {
    // 申请存储权限
    var status = await Permission.storage.request();
    // Android 13+ 需要特殊的 photos 权限，这里简化处理，假设是旧版或文件权限
    if (await Permission.manageExternalStorage.isDenied) {
        // 简单请求管理全文件权限 (仅用于个人工具)
        // await Permission.manageExternalStorage.request();
    }

    String? result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      setState(() {
        selectedDir = result;
        _scanFolder(result);
      });
    }
  }

  void _scanFolder(String dirPath) {
    final dir = Directory(dirPath);
    final files = dir.listSync();
    
    // 正则匹配：-wm.jpg 和对应的 -orig
    // 你的规则：image_A-wm.jpg -> image_A-orig.jpg
    Map<String, String> wmMap = {};
    Map<String, String> origMap = {};

    for (var entity in files) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      
      if (name.contains('-wm.')) {
        String key = name.split('-wm.')[0]; // image_A
        wmMap[key] = entity.path;
      } else if (name.contains('-orig')) {
        // 简单假设包含 -orig 并且前缀匹配
        // 这里的逻辑可以根据实际文件名微调
        String key = name.split('-orig')[0]; 
        origMap[key] = entity.path;
      }
    }

    List<Map<String, String>> newTasks = [];
    wmMap.forEach((key, wmPath) {
      if (origMap.containsKey(key)) {
        newTasks.add({'wm': wmPath, 'orig': origMap[key]!});
      }
    });

    setState(() {
      tasks = newTasks;
      logs = ["扫描完成，发现 ${tasks.length} 对图片"];
      successCount = 0;
      failCount = 0;
    });
  }

  Future<void> _runBatch() async {
    if (tasks.isEmpty) return;

    setState(() => isRunning = true);
    final yolo = Provider.of<YoloService>(context, listen: false);

    // 创建输出目录
    final outputDir = Directory(p.join(selectedDir!, "已修复图片"));
    if (!outputDir.existsSync()) outputDir.createSync();

    for (int i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      final wmPath = task['wm']!;
      final origPath = task['orig']!;
      final name = p.basename(wmPath);

      setState(() => logs.add("[$i/${tasks.length}] 处理: $name ..."));

      try {
        final boxes = await yolo.detect(wmPath);
        if (boxes == null || boxes.isEmpty) {
          setState(() {
            logs.add("  ❌ 失败: 未检测到水印");
            failCount++;
          });
          continue;
        }

        final resultFile = await RepairService.processImage(wmPath, origPath, boxes);
        
        // 移动/复制结果到输出目录
        if (resultFile != null) {
           final savePath = p.join(outputDir.path, name);
           await resultFile.copy(savePath);
           setState(() {
             logs.add("  ✅ 成功");
             successCount++;
           });
        }
      } catch (e) {
        setState(() {
          logs.add("  ❌ 异常: $e");
          failCount++;
        });
      }
      
      // 稍微延时让UI刷新
      await Future.delayed(const Duration(milliseconds: 50));
    }

    setState(() {
      isRunning = false;
      logs.add("--- 任务结束: 成功 $successCount, 失败 $failCount ---");
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("批量文件夹处理")),
      body: Column(
        children: [
          ListTile(
            title: Text(selectedDir ?? "请选择包含图片的文件夹"),
            subtitle: Text("需要包含 xxx-wm.jpg 和 xxx-orig.jpg"),
            leading: const Icon(Icons.folder, size: 40, color: Colors.orange),
            trailing: FilledButton(
              onPressed: isRunning ? null : _pickFolder,
              child: const Text("选择"),
            ),
          ),
          const Divider(),
          if (tasks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text("待处理任务: ${tasks.length} 对"),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: isRunning ? null : _runBatch,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(isRunning ? "处理中..." : "开始批量修复"),
                    style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  )
                ],
              ),
            ),
          const Divider(),
          Expanded(
            child: Container(
              color: Colors.black87,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              child: ListView.builder(
                itemCount: logs.length,
                itemBuilder: (ctx, i) => Text(
                  logs[i], 
                  style: TextStyle(
                    color: logs[i].contains("✅") ? Colors.greenAccent : 
                           logs[i].contains("❌") ? Colors.redAccent : Colors.white,
                    fontFamily: 'monospace'
                  ),
                ),
              ),
            ),
          )
        ],
      ),
    );
  }
}