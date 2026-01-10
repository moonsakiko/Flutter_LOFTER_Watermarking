import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart'; // 👈 引入这个
import 'screens/home_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  
  @override
  void initState() {
    super.initState();
    _clearCache();
  }

  // 👇 启动时清理缓存，解决相册重复图片问题
  Future<void> _clearCache() async {
    try {
      await FilePicker.platform.clearTemporaryFiles();
      print("🧹 缓存已清理");
    } catch (e) {
      print("缓存清理失败: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LOFTER去水印',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
        ),
      ),
      home: const HomePage(),
    );
  }
}