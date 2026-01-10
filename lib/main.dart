import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart'; 
import 'dart:io';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LOFTER 修复机',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.cyan),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        cardTheme: CardTheme(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.white,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  static const platform = MethodChannel('com.example.lofter_fixer/processor');

  double _confidence = 0.4;
  String? _wmPath;
  String? _noWmPath;
  bool _isProcessing = false;
  String _log = "👋 欢迎使用！\n📂 修复后的图片将直接保存到系统相册";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  // --- 权限与保存逻辑 ---
  Future<bool> _requestAccess() async {
    try {
      bool hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
        return await Gal.hasAccess();
      }
      return true;
    } catch (e) {
      _showToast("权限申请失败: $e");
      return false;
    }
  }

  Future<void> _pickImage(bool isWm) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        if (isWm) _wmPath = image.path;
        else _noWmPath = image.path;
      });
    }
  }

  // --- 单张处理 ---
  Future<void> _processSingle() async {
    if (_wmPath == null || _noWmPath == null) {
      _showToast("请先选择两张图片");
      return;
    }
    if (!await _requestAccess()) return;
    
    _addLog("⏳ 开始修复单张图片...");
    await _runNativeRepair([{'wm': _wmPath!, 'clean': _noWmPath!}]);
  }

  // --- 批量处理 ---
  Future<void> _pickFilesBatch() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image);
    if (result != null) {
      List<String> files = result.paths.whereType<String>().toList();
      _matchAndProcess(files);
    }
  }

  void _matchAndProcess(List<String> files) async {
    List<Map<String, String>> tasks = [];
    List<String> wmFiles = files.where((f) => f.toLowerCase().contains("-wm.")).toList();
    
    for (var wm in wmFiles) {
      String expectedOrig = wm.replaceAll(RegExp(r'-wm\.', caseSensitive: false), '-orig.');
      String? foundOrig;
      try {
        foundOrig = files.firstWhere((f) => f == expectedOrig);
      } catch (e) {
        try {
          foundOrig = files.firstWhere((f) => f.toLowerCase() == expectedOrig.toLowerCase());
        } catch (_) {}
      }

      if (foundOrig != null) {
        tasks.add({'wm': wm, 'clean': foundOrig});
      } else {
        _addLog("⚠️ 跳过无配对原图: ${wm.split('/').last}");
      }
    }

    if (tasks.isEmpty) {
      _addLog("❌ 未找到任何匹配对 (-wm 和 -orig)");
      return;
    }
    
    if (!await _requestAccess()) return;

    _addLog("📦 准备修复 ${tasks.length} 组图片...");
    await _runNativeRepair(tasks);
  }

  // --- 核心：调用原生并保存 ---
  Future<void> _runNativeRepair(List<Map<String, String>> tasks) async {
    setState(() => _isProcessing = true);
    int successCount = 0;

    try {
      for (var i = 0; i < tasks.length; i++) {
        var task = tasks[i];
        String fileName = task['wm']!.split('/').last;
        
        try {
          // 1. 调用 Kotlin，获取 Bytes
          final Uint8List? imageBytes = await platform.invokeMethod('processOneImage', {
            'wm': task['wm'],
            'clean': task['clean'],
            'confidence': _confidence,
          });

          if (imageBytes != null && imageBytes.isNotEmpty) {
            // 2. Flutter 保存到相册
            await Gal.putImageBytes(imageBytes, name: "Fixed_$fileName");
            successCount++;
            _addLog("✅ 成功: $fileName");
          } else {
             _addLog("❌ 失败 (未识别/置信度低): $fileName");
          }
        } on PlatformException catch (e) {
          _addLog("🚫 错误 ($fileName): ${e.message}");
        }
      }
      
      String msg = "🎉 任务结束。成功修复 $successCount / ${tasks.length} 张";
      _addLog(msg);
      _showToast(successCount > 0 ? "修复完成，请查看相册" : "修复失败");

    } catch (e) {
      _addLog("🔥 系统异常: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _addLog(String msg) {
    setState(() => _log = "$msg\n$_log");
  }
  
  // 👇 替换了原来的 Fluttertoast，使用原生 SnackBar
  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.cyan[700],
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // --- UI 构建部分 ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("LOFTER 修复机", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.cyan[700],
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.cyan,
          tabs: const [Tab(text: "单张精修"), Tab(text: "批量处理")],
        ),
      ),
      body: Column(
        children: [
          _buildConfidenceSlider(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildSingleTab(),
                _buildBatchTab(),
              ],
            ),
          ),
          _buildLogConsole(),
        ],
      ),
    );
  }

  Widget _buildConfidenceSlider() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("🕵️ 侦探置信度", style: TextStyle(fontWeight: FontWeight.bold)),
              Text("${(_confidence * 100).toInt()}%", style: TextStyle(color: Colors.cyan[700], fontWeight: FontWeight.bold)),
            ],
          ),
          Slider(
            value: _confidence,
            min: 0.1, max: 0.9, divisions: 8,
            activeColor: Colors.cyan,
            onChanged: (v) => setState(() => _confidence = v),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleTab() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _imgBtn("水印图", _wmPath, true)),
              const SizedBox(width: 15),
              Expanded(child: _imgBtn("无水印图", _noWmPath, false)),
            ],
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: _isProcessing ? null : _processSingle,
              icon: _isProcessing 
                ? const SizedBox(width:20, height:20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                : const Icon(Icons.auto_fix_high),
              label: Text(_isProcessing ? "处理中..." : "开始修复"),
              style: FilledButton.styleFrom(backgroundColor: Colors.cyan[600]),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildBatchTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_copy_outlined, size: 80, color: Colors.cyan[200]),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.symmetric(horizontal: 30),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: const Column(
              children: [
                Text("文件名匹配规则", style: TextStyle(fontWeight: FontWeight.bold)),
                Divider(),
                Text("水印图: xxx-wm.jpg", style: TextStyle(color: Colors.grey)),
                Text("原图: xxx-orig.jpg", style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 30),
          FilledButton(
            onPressed: _isProcessing ? null : _pickFilesBatch,
            style: FilledButton.styleFrom(backgroundColor: Colors.cyan[600], padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15)),
            child: const Text("📂 选择图片并批量修复"),
          ),
        ],
      ),
    );
  }

  Widget _imgBtn(String label, String? path, bool isWm) {
    return GestureDetector(
      onTap: () => _pickImage(isWm),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: path != null ? Colors.cyan : Colors.grey.shade300, width: 2),
            image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null,
          ),
          child: path == null 
              ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_photo_alternate, color: Colors.grey[400], size: 40), Text(label, style: TextStyle(color: Colors.grey[600]))]) 
              : null,
        ),
      ),
    );
  }

  Widget _buildLogConsole() {
    return Container(
      height: 150,
      width: double.infinity,
      color: const Color(0xFF222222),
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Text(_log, style: const TextStyle(color: Colors.greenAccent, fontFamily: "monospace", fontSize: 12)),
      ),
    );
  }
}