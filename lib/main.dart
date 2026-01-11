FILE: lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fluttertoast/fluttertoast.dart';
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
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
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
  // 方法通道：连接 Kotlin
  static const platform = MethodChannel('com.example.lofter_fixer/processor');

  // 状态变量
  double _confidence = 0.45;
  bool _isProcessing = false;
  
  // 单张模式变量
  String? _singleWmPath;
  String? _singleCleanPath;
  
  // 日志
  String _statusLog = "准备就绪...";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _requestPermissions();
  }

  // 🛡️ 权限请求加强版
  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.storage,
      // Android 13+ 需要分别申请图片权限
      Permission.photos,
    ].request();
    
    if (statuses[Permission.photos]?.isGranted == true || 
        statuses[Permission.storage]?.isGranted == true) {
      _log("✅ 存储权限已获取");
    } else {
      _log("⚠️ 请授予存储权限，否则无法读取图片");
    }
  }

  void _log(String msg) {
    setState(() => _statusLog = msg);
  }

  // 🖼️ 单张选择
  Future<void> _pickSingleImage(bool isWm) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        if (isWm) _singleWmPath = image.path;
        else _singleCleanPath = image.path;
      });
    }
  }

  // 📂 批量选择
  Future<void> _pickBatchFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );

    if (result != null) {
      List<String> paths = result.paths.whereType<String>().toList();
      _processBatchLogic(paths);
    }
  }

  // 🧠 批量匹配逻辑
  void _processBatchLogic(List<String> files) {
    List<Map<String, String>> tasks = [];
    
    // 找出所有水印图
    var wmFiles = files.where((f) => f.toLowerCase().contains("-wm.")).toList();
    
    for (var wm in wmFiles) {
      // 构造期望的无水印图名字 (image-wm.jpg -> image-orig.jpg)
      // 根据你的要求，这里匹配包含 -orig 的文件
      String baseName = wm.split(Platform.pathSeparator).last;
      String dir = File(wm).parent.path;
      
      // 简单的字符串替换匹配
      String expectedOrigName = baseName.replaceAll("-wm", "-orig");
      String expectedPath = "$dir/$expectedOrigName";
      
      // 在选中的文件列表里找，或者直接检查文件是否存在
      if (files.contains(expectedPath) || File(expectedPath).existsSync()) {
        tasks.add({'wm': wm, 'clean': expectedPath});
      }
    }

    if (tasks.isEmpty) {
      Fluttertoast.showToast(msg: "未找到匹配的图片对 (-wm 和 -orig)");
      return;
    }

    _callNativeRepair(tasks);
  }

  // 🚀 调用原生 Kotlin
  Future<void> _callNativeRepair(List<Map<String, String>> tasks) async {
    setState(() => _isProcessing = true);
    _log("正在处理 ${tasks.length} 组图片...");

    try {
      final int successCount = await platform.invokeMethod('processImages', {
        'tasks': tasks,
        'confidence': _confidence,
      });
      
      _log("🎉 处理完成！成功修复 $successCount 张。\n已保存至相册的 Pictures/LofterFixed 文件夹");
      Fluttertoast.showToast(msg: "修复完成: $successCount 张");
      
    } on PlatformException catch (e) {
      _log("❌ 失败: ${e.message}");
      Fluttertoast.showToast(msg: "处理出错");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("LOFTER 修复机", style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [Tab(text: "单张精修"), Tab(text: "批量处理")],
        ),
      ),
      body: Column(
        children: [
          // 置信度滑块
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("🕵️ 侦探置信度 (Confidence)"),
                    Text("${(_confidence * 100).toInt()}%", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
                  ],
                ),
                Slider(
                  value: _confidence,
                  min: 0.1,
                  max: 0.9,
                  onChanged: (v) => setState(() => _confidence = v),
                  activeColor: Colors.teal,
                ),
              ],
            ),
          ),
          
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildSingleTab(),
                _buildBatchTab(),
              ],
            ),
          ),

          // 底部状态栏
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Colors.grey[200],
            child: Text(_statusLog, style: TextStyle(color: Colors.grey[800], fontSize: 12)),
          )
        ],
      ),
    );
  }

  Widget _buildSingleTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _imgSelector("有水印图", _singleWmPath, true),
              const Icon(Icons.add_circle_outline, color: Colors.grey),
              _imgSelector("无水印图", _singleCleanPath, false),
            ],
          ),
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              icon: _isProcessing 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                : const Icon(Icons.auto_fix_high),
              label: Text(_isProcessing ? "修复中..." : "开始修复"),
              onPressed: _isProcessing ? null : () {
                if (_singleWmPath != null && _singleCleanPath != null) {
                  _callNativeRepair([{'wm': _singleWmPath!, 'clean': _singleCleanPath!}]);
                } else {
                  Fluttertoast.showToast(msg: "请先选择两张图片");
                }
              },
            ),
          )
        ],
      ),
    );
  }

  Widget _buildBatchTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.folder_copy_outlined, size: 80, color: Colors.teal),
          const SizedBox(height: 20),
          const Text("规则：\n1. 水印图文件名包含 -wm\n2. 原图文件名包含 -orig\n3. 两者在同一文件夹内", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 30),
          FilledButton(
            onPressed: _isProcessing ? null : _pickBatchFiles,
            child: const Text("📂 选择图片 (支持多选)"),
          ),
        ],
      ),
    );
  }

  Widget _imgSelector(String label, String? path, bool isWm) {
    return GestureDetector(
      onTap: () => _pickSingleImage(isWm),
      child: Column(
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withOpacity(0.3)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
              image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null,
            ),
            child: path == null ? const Icon(Icons.image, size: 40, color: Colors.grey) : null,
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}