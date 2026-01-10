import 'package:flutter/material.dart';
import 'package:lofter_repair/screens/single_mode_screen.dart';
import 'package:lofter_repair/screens/batch_mode_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  final List<Widget> _pages = [
    const SingleModeScreen(),
    const BatchModeScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_filter),
            label: '单张精修',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library),
            label: '批量处理',
          ),
        ],
      ),
    );
  }
}