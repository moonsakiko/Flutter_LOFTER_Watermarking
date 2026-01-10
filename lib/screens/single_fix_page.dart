import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/yolo_service.dart';
import '../services/image_processor.dart';
import '../utils/cleaner.dart';

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
    // ✅ 进页面时清理一次旧垃圾
    Cleaner.nukeCache();
    // 预加载模型
    _yoloService.initModel();
  }

  Future<void> _pickImage(bool isWm) async {
    // ❌ 删掉这行！不要在这里清理，否则选第二张图时会把第一张删掉！
    // await Cleaner.nukeCache(); 
    
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null) {
      setState(() {
        if (isWm) {
          wmFile = File(result.files.single.path!);
        } else {
          origFile = File(result.files.single.path!);
        }
        // 如果重新选了图，就把上次的结果清空
        resultFile = null;
      });
    }
  }

  Future<void> _startRepair() async {
    if (wmFile == null || origFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先选择两张图片")));
      return;
    }

    // 再次检查文件是否存在 (防止意外被删)
    if (!wmFile!.existsSync() || !origFile!.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("图片文件丢失，请重新选择")));
      return;
    }

    setState(() => isProcessing = true);

    try {
      final box = await _yoloService.detectWatermark(wmFile!.path);
      if (box == null) {
        throw Exception("AI 未能检测到水印，请尝试更清晰的图片");
      }

      final fixedFile = await _imageProcessor.repairImage(wmFile!.path, origFile!.path, box);

      setState(() => resultFile = fixedFile);
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
      // ✅ 任务结束后（无论成功失败），统一清理垃圾
      // 这次为了防止把生成的 resultFile 也删了，我们延时一点点或仅清理 picker 缓存
      // 为了稳妥，我们放在这里清理，因为 resultFile 是存放在 app document 里的，不会被 nukeCache (只删 temp) 误删
      await Cleaner.nukeCache();
      
      if (mounted) {
        setState(() => isProcessing = false);
      }
    }
  }

  Future<void> _saveToGallery() async {
    if (resultFile != null) {
      try {
        await Permission.photos.request();
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