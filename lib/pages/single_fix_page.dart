import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart'; 
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../logic/yolo_service.dart';

class SingleFixPage extends StatefulWidget {
  const SingleFixPage({super.key});

  @override
  State<SingleFixPage> createState() => _SingleFixPageState();
}

class _SingleFixPageState extends State<SingleFixPage> {
  File? wmFile;
  File? noWmFile;
  Uint8List? resultBytes;
  bool isProcessing = false;
  final YoloService _yoloService = YoloService();
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _yoloService.confidenceThreshold = prefs.getDouble('confidence') ?? 0.5;
    });
  }

  Future<void> _pickImage(bool isWm) async {
    // 请求权限
    await Permission.storage.request();
    await Permission.photos.request();

    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        if (isWm) wmFile = File(image.path);
        else noWmFile = File(image.path);
        resultBytes = null; // 重置结果
      });
    }
  }

  Future<void> _startRepair() async {
    if (wmFile == null || noWmFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先选择两张图片')));
      return;
    }

    setState(() => isProcessing = true);
    try {
      await _loadSettings();
      
      final result = await _yoloService.repairImage(wmFile!.path, noWmFile!.path);
      
      if (result == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未检测到水印，无需修复')));
        }
      } else {
        setState(() => resultBytes = result);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('处理出错: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => isProcessing = false);
      }
    }
  }

  Future<void> _saveImage() async {
    if (resultBytes == null) return;
    
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: '保存修复后的图片',
      fileName: 'repaired_${DateTime.now().millisecondsSinceEpoch}.jpg',
      bytes: resultBytes,
    );

    if (outputFile != null && mounted) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('图片已保存')));
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
            Row(
              children: [
                _buildImageCard("水印图 (有字)", wmFile, () => _pickImage(true)),
                const SizedBox(width: 10),
                _buildImageCard("无水印图 (原图)", noWmFile, () => _pickImage(false)),
              ],
            ),
            const SizedBox(height: 20),
            
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton.icon(
                onPressed: isProcessing ? null : _startRepair,
                icon: isProcessing 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
                    : const Icon(Icons.auto_fix_high),
                label: Text(isProcessing ? "AI 正在修复..." : "开始去水印"),
              ),
            ),
            
            const SizedBox(height: 20),
            
            if (resultBytes != null) ...[
              const Divider(),
              const Text("修复结果", style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(resultBytes!),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _saveImage,
                icon: const Icon(Icons.save_alt),
                label: const Text("保存到文件"),
              )
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildImageCard(String title, File? file, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 150,
          decoration: BoxDecoration(
            // 👈 关键修复：改为 surfaceVariant
            color: Theme.of(context).colorScheme.surfaceVariant,
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
                    const Icon(Icons.add_photo_alternate, size: 30, color: Colors.grey),
                    const SizedBox(height: 4),
                    Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ) 
              : null,
        ),
      ),
    );
  }
}