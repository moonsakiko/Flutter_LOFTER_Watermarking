import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const LofterRepairApp());
}

class LofterRepairApp extends StatelessWidget {
  const LofterRepairApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LOFTER 修复姬',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2C5E2E), // 墨绿色调
          brightness: Brightness.light,
        ),
        textTheme: GoogleFonts.notoSansScTextTheme(),
      ),
      home: const HomeScreen(),
    );
  }
}