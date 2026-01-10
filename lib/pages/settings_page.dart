import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  double _confidence = 0.5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _confidence = prefs.getDouble('confidence') ?? 0.5;
    });
  }

  Future<void> _save(double value) async {
    setState(() => _confidence = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('confidence', value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("设置")),
      body: ListView(
        children: [
          ListTile(
            title: const Text("置信度阈值 (Confidence)"),
            subtitle: Text("当前: ${(_confidence * 100).toStringAsFixed(0)}% (越低越容易误判，越高越容易漏检)"),
          ),
          Slider(
            value: _confidence,
            min: 0.1,
            max: 0.9,
            divisions: 8,
            label: _confidence.toString(),
            onChanged: _save,
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text("关于模型"),
            subtitle: Text("YOLOv8/v11 Float16 TFLite\nInput Size: 640x640"),
          )
        ],
      ),
    );
  }
}