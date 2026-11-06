import 'package:flutter/widgets.dart';
import '../data/app_database.dart';

/// Explicit dependency boundary: widget tests inject an isolated SQLite
/// repository; production uses the Android-backed singleton.
class DatabaseScope extends InheritedWidget {
  const DatabaseScope({super.key, required this.database, required super.child});

  final AppDatabase database;

  static AppDatabase of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DatabaseScope>();
    if (scope == null) throw StateError('DatabaseScope missing above application UI');
    return scope.database;
  }

  @override
  bool updateShouldNotify(DatabaseScope oldWidget) =>
      !identical(database, oldWidget.database);
}
