import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
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
  // 必须与 Kotlin 端的 CHANNEL 保持一致
  static const platform = MethodChannel('com.example.lofter_fixer/processor');

  double _confidence = 0.4;
  String? _wmPath;
  String? _noWmPath;
  bool _isProcessing = false;
  String _log = "👋 欢迎使用！\n📂 修复后的图片将保存至相册的 LofterFixed 文件夹";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _checkPermissions();
  }

  // 虽然保存图片交给了 Kotlin (Android 10+ 免权限)，但读取图片仍需权限
  Future<void> _checkPermissions() async {
    await [
      Permission.storage,
      Permission.photos,
      Permission.manageExternalStorage, // Android 11+ 部分机型需要
    ].request();
  }

  // --- 图片选择逻辑 ---
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

  Future<void> _pickFilesBatch() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true, 
      type: FileType.image
    );
    
    if (result != null) {
      List<String> files = result.paths.whereType<String>().toList();
      _matchAndProcess(files);
    }
  }

  // --- 批量匹配逻辑 ---
  void _matchAndProcess(List<String> files) {
    List<Map<String, String>> tasks = [];
    // 寻找所有带 -wm 的图片
    List<String> wmFiles = files.where((f) => f.toLowerCase().contains("-wm.")).toList();
    
    for (var wm in wmFiles) {
      // 尝试匹配对应的 -orig 图片
      String expectedOrig = wm.replaceAll(RegExp(r'-wm\.', caseSensitive: false), '-orig.');
      String? foundOrig;
      
      try {
        foundOrig = files.firstWhere((f) => f == expectedOrig);
      } catch (e) {
        try {
          // 尝试忽略大小写匹配
          foundOrig = files.firstWhere((f) => f.toLowerCase() == expectedOrig.toLowerCase());
        } catch (_) {}
      }

      if (foundOrig != null) {
        tasks.add({'wm': wm, 'clean': foundOrig});
      } else {
        _addLog("⚠️ 跳过无原图: ${wm.split('/').last}");
      }
    }

    if (tasks.isEmpty) {
      _addLog("❌ 未找到匹配对。请确保文件名为 xxx-wm.jpg 和 xxx-orig.jpg");
    } else {
      _addLog("📦 匹配成功: ${tasks.length} 组任务");
      _runNativeRepair(tasks);
    }
  }

  // --- 核心：调用 Kotlin 原生代码 ---
  Future<void> _runNativeRepair(List<Map<String, String>> tasks) async {
    if (tasks.isEmpty) return;
    
    setState(() => _isProcessing = true);
    int successCount = 0;

    try {
      for (var i = 0; i < tasks.length; i++) {
        var task = tasks[i];
        String fileName = task['wm']!.split('/').last;
        
        try {
          // 👇 调用原生方法 processOneImage
          // Kotlin 处理完后会直接保存，并返回保存路径 (String)
          final String? savedPath = await platform.invokeMethod('processOneImage', {
            'wm': task['wm'],
            'clean': task['clean'],
            'confidence': _confidence,
          });

          if (savedPath != null) {
            successCount++;
            _addLog("✅ 成功: $fileName\n   📍 $savedPath");
          } else {
             _addLog("❌ 未识别/置信度低: $fileName");
          }
        } on PlatformException catch (e) {
          _addLog("🚫 原生错误 ($fileName): ${e.message}");
        }
      }
      
      _addLog("🎉 任务结束。成功: $successCount / ${tasks.length}");
      _showSnack(successCount > 0 ? "修复完成，请查看系统相册" : "没有图片被修复");

    } catch (e) {
      _addLog("🔥 异常: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // --- 单张处理触发器 ---
  Future<void> _processSingle() async {
    if (_wmPath == null || _noWmPath == null) {
      _showSnack("请先选择两张图片");
      return;
    }
    _addLog("⏳ 开始处理单张图片...");
    await _runNativeRepair([{'wm': _wmPath!, 'clean': _noWmPath!}]);
  }

  void _addLog(String msg) {
    setState(() => _log = "$msg\n$_log");
  }
  
  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.teal,
      )
    );
  }

  // --- 界面构建 ---
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
          labelColor: Colors.teal,
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.teal,
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
              Text("${(_confidence * 100).toInt()}%", style: TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
            ],
          ),
          Slider(
            value: _confidence,
            min: 0.1, max: 0.9, divisions: 8,
            activeColor: Colors.teal,
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
              style: FilledButton.styleFrom(backgroundColor: Colors.teal),
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
          Icon(Icons.folder_zip_outlined, size: 80, color: Colors.teal[200]),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.symmetric(horizontal: 30),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: const Column(
              children: [
                Text("匹配规则", style: TextStyle(fontWeight: FontWeight.bold)),
                Divider(),
                Text("水印图: xxx-wm.jpg", style: TextStyle(color: Colors.grey)),
                Text("原图: xxx-orig.jpg", style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 30),
          FilledButton(
            onPressed: _isProcessing ? null : _pickFilesBatch,
            style: FilledButton.styleFrom(backgroundColor: Colors.teal, padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15)),
            child: const Text("📂 批量选择图片"),
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
            border: Border.all(color: path != null ? Colors.teal : Colors.grey.shade300, width: 2),
            image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : nu