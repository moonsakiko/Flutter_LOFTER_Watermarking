import 'package:flutter/material.dart';
import 'single_fix_page.dart';
import 'batch_fix_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("LOFTER 去水印神器"),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.auto_fix_high, size: 80, color: Colors.blueAccent),
              const SizedBox(height: 10),
              const Text(
                "请选择修复模式",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 40),
              
              // 单图模式按钮
              _buildMenuCard(
                context,
                title: "单图精修模式",
                subtitle: "手动选择两张图片，一对一修复",
                icon: Icons.image,
                color: Colors.orange.shade100,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SingleFixPage())),
              ),
              
              const SizedBox(height: 20),

              // 批量模式按钮
              _buildMenuCard(
                context,
                title: "批量处理模式",
                subtitle: "选择文件夹，自动匹配 *-wm 和 *-orig",
                icon: Icons.folder_copy,
                color: Colors.blue.shade100,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BatchFixPage())),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuCard(BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 2,
      color: color,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Row(
            children: [
              Icon(icon, size: 40, color: Colors.black87),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 5),
                    Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}