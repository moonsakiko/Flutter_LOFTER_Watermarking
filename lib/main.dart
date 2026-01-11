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
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        cardTheme: const CardTheme(elevation: 4),
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

  double _confidence = 0.5;
  String? _singleWmPath;
  String? _singleCleanPath;
  bool _isProcessing = false;
  String _logText = "准备就绪...\n图片将保存至相册的 LofterFixed 文件夹";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    if (await Permission.photos.isDenied) await Permission.photos.request();
    if (await Permission.storage.isDenied) await Permission.storage.request();
  }

  Future<void> _pickImage(bool isWm) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        if (isWm) _singleWmPath = image.path;
        else _singleCleanPath = image.path;
      });
    }
  }

  Future<void> _pickBatchFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image);
    if (result != null) {
      List<String> files = result.paths.whereType<String>().toList();
      _processBatchLogic(files);
    }
  }

  void _processBatchLogic(List<String> files) {
    List<Map<String, String>> tasks = [];
    var wmFiles = files.where((f) => f.toLowerCase().contains("-wm.")).toList();

    for (var wm in wmFiles) {
      String expectedOrig = wm.replaceAll(RegExp(r'-wm\.', caseSensitive: false), '-orig.');
      try {
        String foundOrig = files.firstWhere((f) => f == expectedOrig);
        tasks.add({'wm': wm, 'clean': foundOrig});
      } catch (e) {
        _appendLog("⚠️ 未找到配对原图: ${wm.split('/').last}");
      }
    }

    if (tasks.isEmpty) {
      _appendLog("❌ 没有找到符合命名规则的图片对。\n文件名需包含 -wm 和 -orig");
    } else {
      _appendLog("✅ 匹配到 ${tasks.length} 组图片，开始处理...");
      _callNativeRepair(tasks);
    }
  }

  Future<void> _callNativeRepair(List<Map<String, String>> tasks) async {
    setState(() => _isProcessing = true);
    try {
      final int successCount = await platform.invokeMethod('processImages', {
        'tasks': tasks,
        'confidence': _confidence,
      });
      _appendLog("🎉 处理完成! 成功修复: $successCount 张");
      if (successCount > 0) Fluttertoast.showToast(msg: "已保存至相册 LofterFixed 文件夹");
    } on PlatformException catch (e) {
      _appendLog("❌ 错误: ${e.message}");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _appendLog(String msg) {
    setState(() => _logText = "$msg\n------------------\n$_logText");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("LOFTER 修复机"),
        bottom: TabBar(controller: _tabController, tabs: const [Tab(text: "单张精修"), Tab(text: "批量工厂")]),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[100],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("AI 置信度 (越低越敏感)", style: TextStyle(fontWeight: FontWeight.bold)),
                    Text("${(_confidence * 100).toInt()}%"),
                  ],
                ),
                Slider(value: _confidence, min: 0.1, max: 0.9, divisions: 8, onChanged: (v) => setState(() => _confidence = v)),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildImagePicker("有水印图", _singleWmPath, true),
                          const Icon(Icons.arrow_forward),
                          _buildImagePicker("无水印图", _singleCleanPath, false),
                        ],
                      ),
                      const SizedBox(height: 30),
                      FilledButton.icon(
                        onPressed: _isProcessing ? null : () {
                          if (_singleWmPath != null && _singleCleanPath != null) {
                            _callNativeRepair([{'wm': _singleWmPath!, 'clean': _singleCleanPath!}]);
                          } else {
                            Fluttertoast.showToast(msg: "请先选择两张图片");
                          }
                        },
                        icon: const Icon(Icons.build),
                        label: Text(_isProcessing ? "修复中..." : "开始修复"),
                      )
                    ],
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.folder_copy, size: 80, color: Colors.teal),
                      const SizedBox(height: 20),
                      const Text("xxx-wm.jpg + xxx-orig.jpg", style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 30),
                      FilledButton(onPressed: _isProcessing ? null : _pickBatchFiles, child: const Text("📂 批量选择文件")),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 150,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: Colors.black87,
            child: SingleChildScrollView(child: Text(_logText, style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace'))),
          )
        ],
      ),
    );
  }

  Widget _buildImagePicker(String label, String? path, bool isWm) {
    return GestureDetector(
      onTap: () => _pickImage(isWm),
      child: Column(children: [
        Container(
          width: 120, height: 120,
          decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey), image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null),
          child: path == null ? const Icon(Icons.add_a_photo, size: 40, color: Colors.grey) : null,
        ),
        const SizedBox(height: 8), Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ]),
    );
  }
}