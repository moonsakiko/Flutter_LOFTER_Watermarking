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
        cardTheme: const CardTheme(elevation: 2, margin: EdgeInsets.all(8)),
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
  double _paddingRatio = 0.2;
  bool _debugMode = false; // 🆕 调试模式开关
  String? _wmPath;
  String? _noWmPath;
  String? _resultPath;
  bool _isProcessing = false;
  String _log = "✅ 准备就绪\n📂 图片将保存至系统相册 (Pictures/LofterFixed)";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _checkAndRequestPermissions();
  }

  Future<void> _checkAndRequestPermissions() async {
    await [Permission.storage, Permission.photos].request();
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("📖 使用说明书"),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("1. 开启【调试模式】", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
              Text("如果你发现修复后的图片没变化，请勾选【调试模式】。"),
              Text("此时图片上会出现一个【红框】。"),
              Text("● 红框位置正确 -> 说明修复功能正常，请关闭调试模式再试。"),
              Text("● 红框位置错误 -> 请调整置信度。"),
              Text("● 没有红框 -> AI 未检测到水印。"),
              Divider(),
              Text("2. 区域扩大", style: TextStyle(fontWeight: FontWeight.bold)),
              Text("如果水印边缘没修干净，请调大此滑块。"),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("懂了"))],
      ),
    );
  }

  Future<void> _pickImage(bool isWm) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        if (isWm) _wmPath = image.path;
        else _noWmPath = image.path;
        _resultPath = null;
      });
    }
  }

  Future<void> _processSingle() async {
    if (_wmPath == null || _noWmPath == null) {
      Fluttertoast.showToast(msg: "请先选择两张图片");
      return;
    }
    if (_wmPath == _noWmPath) {
      _showErrorDialog("操作错误", "水印图和原图不能是同一张图片！");
      return;
    }
    _runNativeRepair([{'wm': _wmPath!, 'clean': _noWmPath!}], isSingle: true);
  }

  Future<void> _pickFilesBatch() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image);
    if (result != null) {
      List<String> files = result.paths.whereType<String>().toList();
      _matchAndProcess(files);
    }
  }

  void _matchAndProcess(List<String> files) {
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
      if (foundOrig != null) tasks.add({'wm': wm, 'clean': foundOrig});
    }
    if (tasks.isEmpty) {
      _addLog("❌ 未找到匹配图片");
    } else {
      _addLog("✅ 匹配到 ${tasks.length} 组任务");
      _runNativeRepair(tasks, isSingle: false);
    }
  }

  Future<void> _runNativeRepair(List<Map<String, String>> tasks, {required bool isSingle}) async {
    setState(() => _isProcessing = true);
    try {
      final result = await platform.invokeMethod('processImages', {
        'tasks': tasks,
        'confidence': _confidence,
        'padding': _paddingRatio,
        'debug': _debugMode, // 🆕 传给 Kotlin
      });

      int successCount = 0;
      String? firstPath;

      if (result is Map) {
        successCount = result['count'] as int;
        firstPath = result['firstPath'] as String?;
      } else if (result is int) {
        successCount = result;
      }
      
      String msg = successCount > 0 
          ? "🎉 处理完成 $successCount 张！\n📂 已保存至相册/Pictures/LofterFixed" 
          : "⚠️ 未检测到水印";
      
      _addLog(msg);
      Fluttertoast.showToast(msg: "处理完成");

      if (isSingle && successCount > 0 && firstPath != null) {
        setState(() => _resultPath = firstPath);
      } else if (isSingle && successCount > 0 && _wmPath != null) {
        String fileName = File(_wmPath!).uri.pathSegments.last;
        String guessPath = "/storage/emulated/0/Pictures/LofterFixed/Fixed_$fileName";
        setState(() => _resultPath = guessPath);
      }
    } on PlatformException catch (e) {
      _addLog("❌ 失败: ${e.message}");
      _showErrorDialog("错误", "${e.message}");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _showErrorDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("⚠️ $title"),
        content: Text(content),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭"))],
      ),
    );
  }

  void _addLog(String msg) {
    setState(() => _log = "$msg\n----------------\n$_log");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("LOFTER 修复机"),
        actions: [IconButton(onPressed: _showHelp, icon: const Icon(Icons.help_outline))],
        bottom: TabBar(controller: _tabController, tabs: const [Tab(text: "单张精修"), Tab(text: "批量处理")]),
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text("🕵️ 置信度: ", style: TextStyle(fontWeight: FontWeight.bold)),
                      Expanded(
                        child: Slider(
                          value: _confidence, min: 0.1, max: 0.9, divisions: 8,
                          label: "${(_confidence * 100).toInt()}%",
                          onChanged: (v) => setState(() => _confidence = v),
                        ),
                      ),
                      Text("${(_confidence * 100).toInt()}%"),
                    ],
                  ),
                  const Divider(height: 1),
                  Row(
                    children: [
                      const Text("📐 区域扩大: ", style: TextStyle(fontWeight: FontWeight.bold)),
                      Expanded(
                        child: Slider(
                          value: _paddingRatio, min: 0.0, max: 0.5, divisions: 10,
                          activeColor: Colors.orange,
                          label: "${(_paddingRatio * 100).toInt()}%",
                          onChanged: (v) => setState(() => _paddingRatio = v),
                        ),
                      ),
                      Text("${(_paddingRatio * 100).toInt()}%"),
                    ],
                  ),
                  const Divider(height: 1),
                  // 🆕 调试模式开关
                  SwitchListTile(
                    title: const Text("🛠️ 调试模式 (仅画红框)", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                    subtitle: const Text("勾选后不修复，只标记水印位置，用于排查问题"),
                    value: _debugMode,
                    onChanged: (v) => setState(() => _debugMode = v),
                    dense: true,
                  ),
                ],
              ),
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

          if (_resultPath != null)
            Container(
              height: 140,
              padding: const EdgeInsets.all(8),
              color: _debugMode ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
              child: Row(
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(_resultPath!), fit: BoxFit.cover,
                        errorBuilder: (c,e,s) => const Center(child: Icon(Icons.broken_image)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_debugMode ? "🛠️ 调试结果 (红框)" : "✨ 修复成功", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 5),
                      Text(_debugMode ? "如果红框位置正确，请关闭调试模式再试" : "如果水印还在，请开启调试模式检查", style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 5),
                      const Text("已保存到相册/Pictures/LofterFixed", style: TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                  )),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _resultPath = null))
                ],
              ),
            ),

          Container(
            height: 80,
            width: double.infinity,
            color: Colors.black.withOpacity(0.05),
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(child: Text(_log, style: const TextStyle(fontSize: 12, fontFamily: "monospace"))),
          )
        ],
      ),
    );
  }

  Widget _buildSingleTab() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _imgBtn("有水印图", _wmPath, true),
              const Icon(Icons.add_circle_outline, color: Colors.grey),
              _imgBtn("无水印图", _noWmPath, false),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _isProcessing ? null : _processSingle,
            icon: _isProcessing 
                ? const SizedBox(width:16, height:16, child: CircularProgressIndicator(strokeWidth:2, color:Colors.white)) 
                : const Icon(Icons.auto_fix_high),
            label: Text(_isProcessing ? "处理中..." : "开始执行"),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15)),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchTab() {
    return Center(child: FilledButton(onPressed: _isProcessing ? null : _pickFilesBatch, child: const Text("📂 批量选择")));
  }

  Widget _imgBtn(String label, String? path, bool isWm) {
    return GestureDetector(
      onTap: () => _pickImage(isWm),
      child: Column(
        children: [
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              color: Colors.grey[200], borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.withOpacity(0.3)),
              image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null,
            ),
            child: path == null ? const Icon(Icons.image_search, size: 40, color: Colors.grey) : null,
          ),
          const SizedBox(height: 8),
          Text(label),
        ],
      ),
    );
  }
}