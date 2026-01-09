import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:path/path.dart' as path;
import '../services/yolo_service.dart';
import '../services/image_processor.dart';
import '../models/process_task.dart';

class BatchFixPage extends StatefulWidget {
  const BatchFixPage({super.key});

  @override
  State<BatchFixPage> createState() => _BatchFixPageState();
}

class _BatchFixPageState extends State<BatchFixPage> {
  List<ProcessTask> tasks = [];
  bool isProcessing = false;
  int successCount = 0;
  
  final YoloService _yoloService = YoloService();
  final ImageProcessor _imageProcessor = ImageProcessor();

  @override
  void initState() {
    super.initState();
    _yoloService.initModel();
  }

  Future<void> _pickFolder() async {
    // Android 上选择文件夹限制较多，这里简化为多选图片
    // 实际操作中，让用户全选文件夹里的图片即可
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );

    if (result != null) {
      final files = result.paths.map((p) => File(p!)).toList();
      _matchPairs(files);
    }
  }

  // 匹配逻辑：找 xxx-wm.jpg 和 xxx-orig.jpg
  void _matchPairs(List<File> files) {
    List<ProcessTask> newTasks = [];
    Map<String, File> wmMap = {};
    Map<String, File> origMap = {};

    // 1. 分类
    for (var f in files) {
      String name = path.basenameWithoutExtension(f.path);
      if (name.endsWith('-wm')) {
        String base = name.substring(0, name.length - 3);
        wmMap[base] = f;
      } else if (name.endsWith('-orig')) {
        String base = name.substring(0, name.length - 5);
        origMap[base] = f;
      }
    }

    // 2. 配对
    wmMap.forEach((base, wmFile) {
      if (origMap.containsKey(base)) {
        newTasks.add(ProcessTask(wmFile: wmFile, origFile: origMap[base]!));
      }
    });

    setState(() {
      tasks = newTasks;
      successCount = 0;
    });
    
    if (newTasks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("未找到符合命名规则的图片对 (-wm, -orig)")));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("成功匹配 ${newTasks.length} 对图片")));
    }
  }

  Future<void> _startBatchProcess() async {
    setState(() {
      isProcessing = true;
      successCount = 0;
    });

    for (int i = 0; i < tasks.length; i++) {
      var task = tasks[i];
      setState(() => task.status = 'processing');

      try {
        final box = await _yoloService.detectWatermark(task.wmFile.path);
        if (box == null) {
          setState(() {
            task.status = 'failed';
            task.errorMsg = '未检测到水印';
          });
          continue;
        }

        final fixedFile = await _imageProcessor.repairImage(task.wmFile.path, task.origFile.path, box);
        // 自动保存到相册
        await GallerySaver.saveImage(fixedFile.path);

        setState(() {
          task.status = 'success';
          task.resultFile = fixedFile;
          successCount++;
        });

      } catch (e) {
        setState(() {
          task.status = 'failed';
          task.errorMsg = e.toString();
        });
      }
    }

    setState(() => isProcessing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("批处理完成，成功 $successCount 张")));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("批量处理模式")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isProcessing ? null : _pickFolder,
                    icon: const Icon(Icons.add_photo_alternate),
                    label: const Text("选择多张图片"),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (isProcessing || tasks.isEmpty) ? null : _startBatchProcess,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(isProcessing ? "处理中..." : "开始批处理"),
                  ),
                ),
              ],
            ),
          ),
          
          if (tasks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text("任务列表 (${tasks.length}) - 成功: $successCount", style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),

          Expanded(
            child: ListView.builder(
              itemCount: tasks.length,
              itemBuilder: (context, index) {
                final task = tasks[index];
                return ListTile(
                  leading: Image.file(task.wmFile, width: 50, height: 50, fit: BoxFit.cover),
                  title: Text(path.basename(task.wmFile.path)),
                  subtitle: Text(
                    task.status == 'waiting' ? '等待处理' :
                    task.status == 'processing' ? '正在处理...' :
                    task.status == 'success' ? '✅ 修复成功' :
                    '❌ 失败: ${task.errorMsg}',
                    style: TextStyle(
                      color: task.status == 'success' ? Colors.green : 
                             task.status == 'failed' ? Colors.red : Colors.grey,
                    ),
                  ),
                  trailing: task.status == 'processing' 
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) 
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}