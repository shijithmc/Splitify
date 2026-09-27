import 'package:flutter/material.dart';
import 'core/controller.dart';
import 'core/design.dart';
import 'features/shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(HisaabApp(controller: AppController()..initialize()));
}

const ink = HisaabColors.ink,
    cream = HisaabColors.surface,
    green = HisaabColors.primary,
    clay = HisaabColors.warning;

class HisaabApp extends StatelessWidget {
  final AppController controller;
  const HisaabApp({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MaterialApp(
      key: ValueKey(controller.userId),
      debugShowCheckedModeBanner: false,
      title: 'Hisaab',
      theme: HisaabTheme.light,
      home: AppShell(controller: controller),
    ),
  );
}
