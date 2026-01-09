import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'; // for compute
import 'package:fluttertoast/fluttertoast.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:path_provider/path_provider.dart';

import '../services/yolo_service.dart';
import '../services/image_processor.dart';

class SingleModeScreen extends StatefulWidget {
  const SingleModeScreen({super.key});

  @override
  State<SingleModeScreen> createState() => _SingleModeScreenState();
}

class _SingleModeScreenState extends State<SingleModeScreen> {
  File? _wmFile;   // 有水印图
  File? _origFile; // 原图
  Uint8List? _resultBytes; // 结果
  bool _isProcessing = false;
  final YoloService _yoloService = YoloService();

  @override
  void initState() {
    super.initState();
    _yoloService.init(); // 预热模型
  }

  // 选择图片
  Future<void> _pickImage(bool isWm) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null) {
      setState(() {
        if (isWm) {
          _wmFile = File(result.files.single.path!);
          _resultBytes = null; // 重置结果
        } else {
          _origFile = File(result.files.single.path!);
        }
      });
    }
  }

  // 开始修复
  Future<void> _startRepair() async {
    if (_wmFile == null || _origFile == null) {
      Fluttertoast.showToast(msg: "请先选择两张图片！");
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final wmBytes = await _wmFile!.readAsBytes();
      final origBytes = await _origFile!.readAsBytes();

      // 1. 检测水印 (在主线程调用插件，因为插件可能有原生通道限制)
      final boxes = await _yoloService.detectWatermark(wmBytes);

      if (boxes.isEmpty) {
        Fluttertoast.showToast(msg: "未检测到水印，可能无需修复");
        setState(() => _isProcessing = false);
        return;
      }

      // 2. 执行修复 (在后台线程计算)
      // compute 只能传递静态方法或顶级函数，所以 ImageProcessor 里的方法必须是 static
      final result = await compute(
        _isolateRepairTask, 
        _RepairArgs(wmBytes, origBytes, boxes)
      );

      setState(() {
        _resultBytes = result;
      });
      
      if (result != null) {
        Fluttertoast.showToast(msg: "修复完成！");
      } else {
        Fluttertoast.showToast(msg: "修复失败，图片解码错误");
      }

    } catch (e) {
      Fluttertoast.showToast(msg: "发生错误: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // 保存结果
  Future<void> _saveImage() async {
    if (_resultBytes == null) return;
    try {
      final tempDir = await getTemporaryDirectory();
      final file = await File('${tempDir.path}/repaired_${DateTime.now().millisecondsSinceEpoch}.jpg').create();
      await file.writeAsBytes(_resultBytes!);
      
      await GallerySaver.saveImage(file.path, albumName: "LOFTER修复");
      Fluttertoast.showToast(msg: "已保存到相册");
    } catch (e) {
      Fluttertoast.showToast(msg: "保存失败: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("单图精修模式")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 图片选择区
            Row(
              children: [
                _buildImagePicker("有水印图 (大)", _wmFile, () => _pickImage(true)),
                const SizedBox(width: 10),
                _buildImagePicker("无水印原图 (小)", _origFile, () => _pickImage(false)),
              ],
            ),
            const SizedBox(height: 20),
            
            // 按钮区
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: _isProcessing ? null : _startRepair,
                icon: _isProcessing 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                  : const Icon(Icons.auto_fix_high),
                label: Text(_isProcessing ? "正在施法..." : "开始修复"),
              ),
            ),
            const SizedBox(height: 20),

            // 结果展示区
            if (_resultBytes != null) ...[
              const Text("修复结果预览:", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(_resultBytes!),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _saveImage,
                icon: const Icon(Icons.save_alt),
                label: const Text("保存到相册"),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildImagePicker(String label, File? file, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 150,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.withOpacity(0.3)),
            image: file != null 
              ? DecorationImage(image: FileImage(file), fit: BoxFit.cover) 
              : null,
          ),
          child: file == null 
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_photo_alternate, size: 40, color: Colors.grey),
                  const SizedBox(height: 8),
                  Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              )
            : null,
        ),
      ),
    );
  }
}

// 辅助类用于 Isolate 传参
class _RepairArgs {
  final Uint8List wm;
  final Uint8List orig;
  final List<Map<String, dynamic>> boxes;
  _RepairArgs(this.wm, this.orig, this.boxes);
}

// 顶级函数用于 compute
Future<Uint8List?> _isolateRepairTask(_RepairArgs args) async {
  return await ImageProcessor.repairImage(args.wm, args.orig, args.boxes);
}