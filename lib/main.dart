import 'package:flutter/material.dart';
import 'screens/single_mode.dart';
import 'screens/batch_mode.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '去水印神器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        )
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("LOFTER 智能修复"),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.image), text: "单张精修"),
              Tab(icon: Icon(Icons.photo_library), text: "批量处理"),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            SingleModeScreen(),
            BatchModeScreen(),
          ],
        ),
      ),
    );
  }
}