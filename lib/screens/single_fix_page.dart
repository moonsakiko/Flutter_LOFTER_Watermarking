import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart'; // 👈 改用 gal
import '../services/yolo_service.dart';
import '../services/image_processor.dart';
import 'package:permission_handler/permission_handler.dart';

class SingleFixPage extends StatefulWidget {
  const SingleFixPage({super.key});

  @override
  State<SingleFixPage> createState() => _SingleFixPageState();
}

class _SingleFixPageState extends State<SingleFixPage> {
  File? wmFile;
  File? origFile;
  File? resultFile;
  bool isProcessing = false;
  
  final YoloService _yoloService = YoloService();
  final ImageProcessor _imageProcessor = ImageProcessor();

  @override
  void initState() {
    super.initState();
    _yoloService.initModel();
  }

  Future<void> _pickImage(bool isWm) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null) {
      setState(() {
        if (isWm) {
          wmFile = File(result.files.single.path!);
        } else {
          origFile = File(result.files.single.path!);
        }
        resultFile = null;
      });
    }
  }

  Future<void> _startRepair() async {
    if (wmFile == null || origFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先选择两张图片")));
      return;
    }

    setState(() => isProcessing = true);

    try {
      final box = await _yoloService.detectWatermark(wmFile!.path);
      if (box == null) {
        throw Exception("AI 未能在图片中检测到水印");
      }

      final fixedFile = await _imageProcessor.repairImage(wmFile!.path, origFile!.path, box);

      setState(() {
        resultFile = fixedFile;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("修复成功！")));

    } catch (e) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("处理失败"),
          content: Text(e.toString()),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("确定"))],
        ),
      );
    } finally {
      setState(() => isProcessing = false);
    }
  }

  Future<void> _saveToGallery() async {
    if (resultFile != null) {
      try {
        // 请求权限 (Gal 通常会自动处理，但为了保险)
        await Permission.photos.request();
        
        // 👇 使用 Gal 保存
        await Gal.putImage(resultFile!.path);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ 已保存到相册")));
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("保存失败: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("单图精修")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: _buildSelector(wmFile, "选择水印图", true)),
                const SizedBox(width: 10),
                Expanded(child: _buildSelector(origFile, "选择原图", false)),
              ],
            ),
            
            const SizedBox(height: 20),
            
            FilledButton.icon(
              onPressed: isProcessing ? null : _startRepair,
              icon: isProcessing 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                  : const Icon(Icons.build),
              label: Text(isProcessing ? "AI 正在修复..." : "开始修复"),
              style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
            ),

            const SizedBox(height: 20),

            if (resultFile != null) ...[
              const Divider(),
              const Text("修复结果", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(resultFile!),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _saveToGallery,
                icon: const Icon(Icons.save_alt),
                label: const Text("保存到手机相册"),
              )
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildSelector(File? file, String text, bool isWm) {
    return InkWell(
      onTap: () => _pickImage(isWm),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade400),
          image: file != null ? DecorationImage(image: FileImage(file), fit: BoxFit.cover) : null,
        ),
        child: file == null 
            ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_a_photo, color: Colors.grey), Text(text)]) 
            : null,
      ),
    );
  }
}