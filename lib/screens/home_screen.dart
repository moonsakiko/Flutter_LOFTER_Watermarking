import 'package:flutter/material.dart';
import 'single_mode.dart';
import 'batch_mode.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final List<Widget> _pages = const [
    SingleModeScreen(),
    BatchModeScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_filter),
            label: '单图精修',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_copy),
            label: '批量处理',
          ),
        ],
      ),
    );
  }
}