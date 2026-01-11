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
  double _paddingRatio = 0.2; // 🆕 默认扩大 20%
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
    // 降级后的权限申请，更优雅
    Map<Permission, PermissionStatus> statuses = await [
      Permission.storage,
      Permission.photos, // Android 13+
    ].request();
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
              Text("1. 图片没变化？", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
              Text("请尝试调大【区域扩大】滑块。有时候AI识别的水印框太紧凑，需要扩大一圈才能完全覆盖。"),
              Divider(),
              Text("2. 核心原理", style: TextStyle(fontWeight: FontWeight.bold)),
              Text("利用 AI 找到水印位置，然后从【无水印原图】中截取相同位置的画面，覆盖到【水印图】上。"),
              Divider(),
              Text("3. 置信度是什么？", style: TextStyle(fontWeight: FontWeight.bold)),
              Text("AI 认为它是水印的概率。一般 30%-50% 效果最好。"),
              Divider(),
              Text("4. 保存位置", style: TextStyle(fontWeight: FontWeight.bold)),
              Text("相册 -> Pictures -> LofterFixed"),
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
      _addLog("❌ 未找到匹配图片。请确保文件名包含 -wm 和 -orig");
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
        'padding': _paddingRatio, // 🆕 传给 Kotlin
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
          ? "🎉 成功修复 $successCount 张！\n📂 已保存至相册/Pictures/LofterFixed" 
          : "⚠️ 未修复 (请尝试调低置信度或调大区域扩大)";
      
      _addLog(msg);
      Fluttertoast.showToast(msg: successCount > 0 ? "修复完成" : "修复失败");

      if (isSingle && successCount > 0 && firstPath != null) {
        setState(() => _resultPath = firstPath);
      } else if (isSingle && successCount > 0 && _wmPath != null) {
        String fileName = File(_wmPath!).uri.pathSegments.last;
        String guessPath = "/storage/emulated/0/Pictures/LofterFixed/Fixed_$fileName";
        setState(() => _resultPath = guessPath);
      }

    } on PlatformException catch (e) {
      _addLog("❌ 失败: ${e.message}");
      _showErrorDialog("出错了", "错误信息: ${e.message}\n请检查是否授予了相册读写权限。");
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
        actions: [
          IconButton(onPressed: _showHelp, icon: const Icon(Icons.help_outline)),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [Tab(text: "单张精修"), Tab(text: "批量处理")],
        ),
      ),
      body: Column(
        children: [
          // 🎛️ 控制面板
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text("🕵️ 侦探置信度: ", style: TextStyle(fontWeight: FontWeight.bold)),
                      Expanded(
                        child: Slider(
                          value: _confidence,
                          min: 0.1, max: 0.9, divisions: 8,
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
                          value: _paddingRatio,
                          min: 0.0, max: 0.5, divisions: 10, // 最大扩大 50%
                          activeColor: Colors.orange,
                          label: "${(_paddingRatio * 100).toInt()}%",
                          onChanged: (v) => setState(() => _paddingRatio = v),
                        ),
                      ),
                      Text("${(_paddingRatio * 100).toInt()}%"),
                    ],
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
              height: 120,
              padding: const EdgeInsets.all(8),
              color: Colors.green.withOpacity(0.1),
              child: Row(
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(_resultPath!), 
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, s) => Container(color: Colors.grey[300], child: const Icon(Icons.check, color: Colors.green)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text("✨ 修复成功", style: TextStyle(fontWeight: FontWeight.bold)),
                      Text("如果水印还在，请调大【区域扩大】滑块", style: TextStyle(fontSize: 12, color: Colors.orange)),
                    ],
                  )),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _resultPath = null),
                  )
                ],
              ),
            ),

          Container(
            height: 100,
            width: double.infinity,
            color: Colors.black.withOpacity(0.05),
            padding: const EdgeInsets.all(8),
            child: SingleChildScrollView(
              child: Text(_log, style: const TextStyle(fontSize: 12, fontFamily: "monospace")),
            ),
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
            label: Text(_isProcessing ? "正在修复..." : "开始修复"),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15)),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.folder_zip, size: 80, color: Colors.teal),
          const SizedBox(height: 20),
          const Text("请选择包含以下后缀的图片对：", style: TextStyle(color: Colors.grey)),
          const Text("-wm.jpg (水印图)\n-orig.jpg (原图)", style: TextStyle(fontWeight: FontWeight.bold, height: 1.5)),
          const SizedBox(height: 30),
          FilledButton(
            onPressed: _isProcessing ? null : _pickFilesBatch,
            child: const Text("📂 批量选择并修复"),
          ),
        ],
      ),
    );
  }

  Widget _imgBtn(String label, String? path, bool isWm) {
    return GestureDetector(
      onTap: () => _pickImage(isWm),
      child: Column(
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.withOpacity(0.3)),
              image: path != null ? DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover) : null,
            ),
            child: path == null ? const Icon(Icons.image_search, size: 40, color: Colors.grey) : null,
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}