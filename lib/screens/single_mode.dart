import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:path_provider/path_provider.dart';
import '../logic/yolo_service.dart';
import '../logic/image_fixer.dart';

class SingleModeScreen extends StatefulWidget {
  const SingleModeScreen({super.key});

  @override
  State<SingleModeScreen> createState() => _SingleModeScreenState();
}

class _SingleModeScreenState extends State<SingleModeScreen> {
  File? _wmImage;
  File? _cleanImage;
  File? _resultImage;
  bool _isProcessing = false;
  
  // 设置
  double _confThreshold = 0.5;
  final YoloService _yoloService = YoloService();

  @override
  void initState() {
    super.initState();
    _yoloService.loadModel();
  }

  Future<void> _pickImage(bool isWm) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null) {
      setState(() {
        if (isWm) {
          _wmImage = File(result.files.single.path!);
          _resultImage = null; // 重置结果
        } else {
          _cleanImage = File(result.files.single.path!);
        }
      });
    }
  }

  Future<void> _process() async {
    if (_wmImage == null || _cleanImage == null) return;
    setState(() => _isProcessing = true);

    try {
      // 1. 侦测
      final boxes = await _yoloService.detect(_wmImage!, _confThreshold);
      if (boxes.isEmpty) {
        _showSnack("未检测到水印，请降低置信度重试");
        setState(() => _isProcessing = false);
        return;
      }

      // 2. 修复
      final tempDir = await getTemporaryDirectory();
      final savePath = "${tempDir.path}/fixed_${DateTime.now().millisecondsSinceEpoch}.jpg";
      
      final result = await ImageFixer.fixImage(
        watermarkFile: _wmImage!,
        cleanFile: _cleanImage!,
        box: boxes.first, // 取第一个检测到的水印
        outputPath: savePath,
      );

      setState(() {
        _resultImage = result;
      });
    } catch (e) {
      _showSnack("处理失败: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _saveToGallery() async {
    if (_resultImage != null) {
      await GallerySaver.saveImage(_resultImage!.path);
      _showSnack("已保存到相册");
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 选图区域
          Row(
            children: [
              _buildImageBox("有水印图", _wmImage, () => _pickImage(true)),
              const SizedBox(width: 10),
              _buildImageBox("无水印图\n(原图)", _cleanImage, () => _pickImage(false)),
            ],
          ),
          
          const SizedBox(height: 20),
          
          // 设置区域
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  Text("置信度阈值: ${_confThreshold.toStringAsFixed(2)}"),
                  Slider(
                    value: _confThreshold,
                    min: 0.1,
                    max: 0.9,
                    onChanged: (v) => setState(() => _confThreshold = v),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // 按钮
          FilledButton.icon(
            onPressed: _isProcessing ? null : _process,
            icon: _isProcessing ? const SizedBox(width:20, height:20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.auto_fix_high),
            label: Text(_isProcessing ? "处理中..." : "开始去水印"),
            style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
          ),

          const SizedBox(height: 20),

          // 结果展示
          if (_resultImage != null) ...[
            const Text("处理结果:", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(_resultImage!),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _saveToGallery,
              icon: const Icon(Icons.save),
              label: const Text("保存到相册"),
            )
          ]
        ],
      ),
    );
  }

  Widget _buildImageBox(String label, File? file, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 150,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey[400]!),
            image: file != null ? DecorationImage(image: FileImage(file), fit: BoxFit.cover) : null,
          ),
          child: file == null 
            ? Center(child: Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)))
            : null,
        ),
      ),
    );
  }
}