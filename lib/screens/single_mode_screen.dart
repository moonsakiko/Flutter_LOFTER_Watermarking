import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'; // for compute
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lofter_repair/services/yolo_service.dart';
import 'package:lofter_repair/services/image_processor.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;

class SingleModeScreen extends StatefulWidget {
  const SingleModeScreen({super.key});

  @override
  State<SingleModeScreen> createState() => _SingleModeScreenState();
}

class _SingleModeScreenState extends State<SingleModeScreen> {
  XFile? _wmImage;
  XFile? _origImage;
  double _confidence = 0.5;
  bool _isProcessing = false;
  
  final YoloService _yolo = YoloService();

  @override
  void initState() {
    super.initState();
    _yolo.loadModel();
  }

  Future<void> _pickImage(bool isWm) async {
    final picker = ImagePicker();
    final img = await picker.pickImage(source: ImageSource.gallery);
    if (img != null) {
      setState(() {
        if (isWm) _wmImage = img;
        else _origImage = img;
      });
    }
  }

  Future<void> _process() async {
    if (_wmImage == null || _origImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先选择两张图片')));
      return;
    }

    setState(() => _isProcessing = true);

    try {
      // 1. 解码用于侦测的水印图
      final wmBytes = await File(_wmImage!.path).readAsBytes();
      final wmDecoded = img.decodeImage(wmBytes);

      if (wmDecoded == null) throw "图片解码失败";

      // 2. 侦测水印区域
      final bbox = await _yolo.detectWatermark(wmDecoded, _confidence);
      
      if (bbox == null) {
        throw "未检测到水印 (请尝试调低置信度)";
      }

      print("检测到水印: $bbox");

      // 3. 后台线程执行修复
      final request = ImageRepairRequest(
        _wmImage!.path, 
        _origImage!.path, 
        bbox, 
        0.2, // 宽度扩大 20%
        0.1  // 高度扩大 10%
      );
      
      final resultBytes = await compute(ImageProcessor.repairImage, request);

      if (resultBytes != null) {
        // 4. 保存结果
        final tempPath = '${_wmImage!.path}_repaired.jpg';
        await File(tempPath).writeAsBytes(resultBytes);
        
        // 保存到相册
        await Gal.putImage(tempPath);
        
        _showSuccessDialog();
      } else {
        throw "图像处理失败";
      }

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误: $e')));
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context, 
      builder: (ctx) => AlertDialog(
        title: const Text("修复成功 🎉"),
        content: const Text("图片已保存到系统相册。"),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("好"))],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("单张精修模式")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _buildImagePicker("有水印图 (LOFTER)", _wmImage, true),
            const SizedBox(height: 16),
            _buildImagePicker("无水印图 (原图)", _origImage, false),
            const SizedBox(height: 24),
            
            // 置信度滑块
            Card(
              elevation: 0,
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("🤖 AI 自信度阈值", style: TextStyle(fontWeight: FontWeight.bold)),
                        Text("${(_confidence * 100).toInt()}%", style: TextStyle(color: Theme.of(context).primaryColor, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: _confidence,
                      min: 0.1,
                      max: 0.9,
                      divisions: 8,
                      label: "${(_confidence * 100).toInt()}%",
                      onChanged: (v) => setState(() => _confidence = v),
                    ),
                    const Text("越低越容易识别，但也可能识别错物体。", style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 30),
            
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: _isProcessing ? null : _process,
                icon: _isProcessing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.auto_fix_high),
                label: Text(_isProcessing ? "正在施法中..." : "开始修复"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePicker(String title, XFile? file, bool isWm) {
    return InkWell(
      onTap: () => _pickImage(isWm),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade300),
          image: file != null ? DecorationImage(image: FileImage(File(file.path)), fit: BoxFit.cover) : null,
        ),
        child: file == null ? Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isWm ? Icons.water_drop : Icons.image, size: 40, color: Colors.grey),
              const SizedBox(height: 8),
              Text(title, style: const TextStyle(color: Colors.grey)),
            ],
          ),
        ) : null,
      ),
    );
  }
}