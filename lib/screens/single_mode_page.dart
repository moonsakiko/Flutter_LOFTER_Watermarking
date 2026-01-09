import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:lofter_repair_app/services/yolo_service.dart';
import 'package:lofter_repair_app/services/repair_service.dart';
import 'package:gallery_saver/gallery_saver.dart'; // 需要添加库，或使用简单的 share_plus

class SingleModePage extends StatefulWidget {
  const SingleModePage({super.key});

  @override
  State<SingleModePage> createState() => _SingleModePageState();
}

class _SingleModePageState extends State<SingleModePage> {
  File? wmFile;
  File? origFile;
  File? resultFile;
  bool isProcessing = false;
  String statusMsg = "";

  final ImagePicker _picker = ImagePicker();

  Future<void> _pickImage(bool isWm) async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        if (isWm) wmFile = File(image.path);
        else origFile = File(image.path);
        resultFile = null; // 重置结果
      });
    }
  }

  Future<void> _startRepair() async {
    if (wmFile == null || origFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("请先选择两张图片！")),
      );
      return;
    }

    setState(() {
      isProcessing = true;
      statusMsg = "正在侦察水印...";
    });

    try {
      final yolo = Provider.of<YoloService>(context, listen: false);
      
      // 1. YOLO 识别
      final boxes = await yolo.detect(wmFile!.path);
      
      if (boxes == null || boxes.isEmpty) {
        throw Exception("未检测到水印 (置信度不足)");
      }

      setState(() => statusMsg = "正在执行像素修复...");

      // 2. 图像处理
      final result = await RepairService.processImage(
        wmFile!.path, 
        origFile!.path, 
        boxes
      );

      setState(() {
        resultFile = result;
        statusMsg = "修复完成！";
      });

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("错误: $e"), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("单图精准修复")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 图片选择区
            Row(
              children: [
                _buildPickerCard("水印图", wmFile, () => _pickImage(true)),
                const SizedBox(width: 12),
                _buildPickerCard("原图", origFile, () => _pickImage(false)),
              ],
            ),
            
            const SizedBox(height: 24),
            
            // 操作按钮
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: isProcessing ? null : _startRepair,
                icon: isProcessing 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.auto_fix_high),
                label: Text(isProcessing ? statusMsg : "开始修复"),
              ),
            ),

            const SizedBox(height: 24),

            // 结果展示区
            if (resultFile != null) ...[
              const Text("修复结果", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(resultFile!),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  // 保存到相册简单实现 (需配合 permission_handler)
                  // 这里简单打印路径，建议集成 gallery_saver
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("图片已保存至临时目录: ${resultFile!.path}"))
                  );
                },
                icon: const Icon(Icons.save_alt),
                label: const Text("保存到相册"),
              )
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildPickerCard(String title, File? file, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 150,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.withOpacity(0.2)),
            image: file != null 
              ? DecorationImage(image: FileImage(file), fit: BoxFit.cover)
              : null
          ),
          child: file == null 
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.add_photo_alternate, size: 32, color: Colors.grey),
                    const SizedBox(height: 8),
                    Text(title, style: const TextStyle(color: Colors.grey)),
                  ],
                ) 
              : null,
        ),
      ),
    );
  }
}