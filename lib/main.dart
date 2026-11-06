import 'package:flutter/material.dart';
import 'data/app_database.dart';
import 'ui/pages.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDatabase.instance.db;
  runApp(const KaibaoApp());
}

class KaibaoApp extends StatelessWidget {
  const KaibaoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '凯堡软装',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1375b5)),
      appBarTheme: const AppBarTheme(centerTitle: true),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(vertical: 11, horizontal: 12)),
    ),
    home: const HomePage(),
  );
}
