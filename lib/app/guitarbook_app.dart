import 'package:flutter/material.dart';

import '../features/tools/presentation/tools_page.dart';
import 'theme.dart';

class GuitarbookApp extends StatelessWidget {
  const GuitarbookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '吉他宝典',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: const ToolsPage(),
    );
  }
}
