import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/yolo_service.dart';
import '../services/image_logic.dart';

class SingleFixPage extends StatefulWidget {
  const SingleFixPage({super.key});

  @override
  State<SingleFixPage> createState() => _SingleFixPageState();
}

class _SingleFixPageState extends State<SingleFixPage> {
  File? wmFile;
  File? cleanFile;
  Uint8List? resultBytes;
  
  double confidence = 0.50;
  bool isProcessing = false;
  String statusMsg = "";
  
  final YoloService _yolo = YoloService();

  @override
  void initState() {
    super.initState();
    _initModel();
  }

  Future<void> _initModel() async {
    await _yolo.loadModel();
  }

  Future<void> _pickImage(bool isWm) async {
    // 简单的图片选择
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null) {
      setState(() {
        if (isWm) wmFile = File(result.files.single.path!);
        else cleanFile = File(result.files.single.path!);
        resultBytes = null; // 重置结果
      });
    }
  }

  Future<void> _process() async {
    if (wmFile == null || cleanFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请先选择两张图片")));
      return;
    }

    setState(() { isProcessing = true; statusMsg = "正在分析水印位置..."; });

    try {
      // 1. 侦测
      final box = await _yolo.detect(wmFile!, confThreshold: confidence);
      
      if (box == null) {
        setState(() { statusMsg = "未检测到水印 (请尝试降低置信度)"; isProcessing = false; });
        return;
      }

      setState(() { statusMsg = "定位成功，正在修复..."; });

      // 2. 修复
      final result = await ImageLogic.repairImage(
        wmFile: wmFile!,
        cleanFile: cleanFile!,
        box: box,
      );

      if (result != null) {
        setState(() { resultBytes = result; statusMsg = "修复完成！"; });
      } else {
        setState(() { statusMsg = "修复过程出错"; });
      }

    } catch (e) {
      setState(() { statusMsg = "发生错误: $e"; });
    } finally {
      setState(() { isProcessing = false; });
    }
  }

  Future<void> _saveImage() async {
    if (resultBytes == null) return;
    
    // 申请权限
    if (await Permission.storage.request().isGranted || 
        await Permission.manageExternalStorage.request().isGranted ||
        await Permission.photos.request().isGranted) {
      
      final dir = await getExternalStorageDirectory(); // App私有目录，或者尝试存入相册
      // 为了简单演示，我们存到 Download 文件夹 (需要特定逻辑) 或者 App 文档
      // 这里为了兼容性，建议使用 share_plus 插件分享出去，或者 file_picker 的 saveFile
      
      // 简易版：存到临时目录并提示路径
      final String fileName = "fixed_${DateTime.now().millisecondsSinceEpoch}.jpg";
      // 这里的路径管理在Android上比较复杂，最稳妥是用 share_plus 分享给用户保存
      // 但为了不引入新库，我们暂时存到应用目录
      // TODO: 实际项目中建议引入 share_plus: ^7.2.2 并使用 Share.shareXFiles
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("单张精修")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 图片选择区
            Row(
              children: [
                Expanded(child: _buildImageSelector("有水印图", wmFile, () => _pickImage(true))),
                const SizedBox(width: 12),
                Expanded(child: _buildImageSelector("无水印图", cleanFile, () => _pickImage(false))),
              ],
            ),
            const SizedBox(height: 20),
            
            // 结果展示区
            Container(
              height: 300,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!)
              ),
              child: isProcessing 
                ? const Center(child: CircularProgressIndicator())
                : resultBytes != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(resultBytes!, fit: BoxFit.contain)
                    )
                  : const Center(child: Text("等待处理...", style: TextStyle(color: Colors.grey))),
            ),
            const SizedBox(height: 10),
            Text(statusMsg, style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
            
            const SizedBox(height: 20),
            
            // 控制区
            const Align(alignment: Alignment.centerLeft, child: Text("侦测置信度 (Confidence)")),
            Slider(
              value: confidence,
              min: 0.1,
              max: 0.9,
              divisions: 8,
              label: confidence.toString(),
              onChanged: (v) => setState(() => confidence = v),
            ),
            
            const SizedBox(height: 20),
            
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: isProcessing ? null : _process,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text("开始修复"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSelector(String label, File? file, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: file == null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_photo_alternate, size: 40, color: Colors.grey),
                  const SizedBox(height: 8),
                  Text(label, style: const TextStyle(color: Colors.grey)),
                ],
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(file, fit: BoxFit.cover),
                    Container(
                      color: Colors.black38,
                      child: Center(child: Text(label, style: const TextStyle(color: Colors.white))),
                    )
                  ],
                ),
              ),
      ),
    );
  }
}