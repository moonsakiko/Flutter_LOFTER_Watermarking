import 'package:flutter/material.dart';
import 'single_fix_page.dart';
import 'batch_fix_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("LOFTER 智能修复")),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildCard(
              context,
              title: "单张精修模式",
              desc: "手动选择两张图片，可视化调整，精准修复。",
              icon: Icons.image_search,
              color: Colors.blue.shade100,
              target: const SingleFixPage(),
            ),
            const SizedBox(height: 20),
            _buildCard(
              context,
              title: "批量处理模式",
              desc: "选择文件夹，自动匹配 *-wm.jpg 和 *-orig.jpg 进行处理。",
              icon: Icons.folder_copy,
              color: Colors.orange.shade100,
              target: const BatchFixPage(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, {
    required String title,
    required String desc,
    required IconData icon,
    required Color color,
    required Widget target,
  }) {
    return InkWell(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => target)),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black12, blurRadius: 10, offset: const Offset(0, 5))
          ],
        ),
        child: Row(
          children: [
            Icon(icon, size: 48, color: Colors.black54),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(desc, style: const TextStyle(fontSize: 14, color: Colors.black87)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.black26),
          ],
        ),
      ),
    );
  }
}