import 'package:flutter/material.dart';
import 'data/app_database.dart';
import 'application/sales_store.dart';
import 'ui/pages.dart';
import 'ui/database_scope.dart';

Future<void> _initializeDatabase() async {
  await AppDatabase.instance.db;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(KaibaoStartup(
    initialize: _initializeDatabase,
    ready: const KaibaoApp(),
  ));
}

/// A failed SQLite open must show a safe retry path instead of leaving the
/// application without a Flutter error screen. No DB is reset or replaced.
class KaibaoStartup extends StatefulWidget {
  const KaibaoStartup({super.key, required this.initialize, required this.ready});
  final Future<void> Function() initialize;
  final Widget ready;

  @override
  State<KaibaoStartup> createState() => _KaibaoStartupState();
}

class _KaibaoStartupState extends State<KaibaoStartup> {
  late Future<void> _initialization;

  @override
  void initState() {
    super.initState();
    _initialization = widget.initialize();
  }

  void _retry() {
    setState(() => _initialization = widget.initialize());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _initialization,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done && !snapshot.hasError) {
        // Force a fresh MaterialApp/Navigator when leaving the error screen;
        // reusing the old MaterialApp State retains its previous home route.
        return KeyedSubtree(key: const ValueKey('database-ready'), child: widget.ready);
      }
      return KeyedSubtree(key: const ValueKey('database-initializing'), child: MaterialApp(
        title: '凯堡软装 · 启动',
        home: Scaffold(
          body: SafeArea(child: Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.storage_outlined, size: 48),
                  const SizedBox(height: 16),
                  Text(snapshot.hasError ? '本地数据库无法打开' : '正在检查本地数据库',
                    style: const TextStyle(fontSize: 22)),
                  const SizedBox(height: 16),
                  if (snapshot.hasError) ...[
                    const Text('数据没有被自动删除或重置。请勿卸载应用、清除数据或覆盖数据库。'
                      '检查手机剩余空间后可以重试；仍失败时应保留原数据并记录错误。'),
                    const SizedBox(height: 16),
                    SelectableText('错误信息：${snapshot.error}'),
                    const SizedBox(height: 24),
                    FilledButton(onPressed: _retry, child: const Text('重试打开数据库')),
                  ] else const CircularProgressIndicator(),
                ],
              ),
            ),
          ))),
        ),
      ));
    },
  );
}

class KaibaoApp extends StatelessWidget {
  const KaibaoApp({super.key, this.database});
  final SalesStore? database;
  @override
  Widget build(BuildContext context) => DatabaseScope(
    database: database ?? AppDatabase.instance,
    child: MaterialApp(
    title: '凯堡软装',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1375b5)),
      textTheme: const TextTheme(bodyLarge: TextStyle(fontSize: 18), bodyMedium: TextStyle(fontSize: 18), titleMedium: TextStyle(fontSize: 20)),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(0,56), textStyle: const TextStyle(fontSize: 18))),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(0,56), textStyle: const TextStyle(fontSize: 18))),
      appBarTheme: const AppBarTheme(centerTitle: true),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(vertical: 11, horizontal: 12)),
    ),
    home: const HomePage(),
  ));
}
