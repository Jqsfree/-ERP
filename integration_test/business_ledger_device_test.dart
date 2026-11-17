import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

import '../test/support/business_ledger_scenario.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> isolatedRoot() async {
    final directory = Directory(await getDatabasesPath());
    await directory.create(recursive: true);
    return directory;
  }

  // The shared scenario creates a unique temporary directory and never
  // opens or overwrites the production database.
  testWidgets('Android native SQLite: complete sales, refund, credit, stock, and encrypted restore',
    (tester) async {
      await verifyBusinessLedger(databaseFactory, await isolatedRoot());
    });

  testWidgets('Android native SQLite: zero opening receipt and backup validation',
    (tester) async {
      await verifyZeroOpeningReceipt(databaseFactory, await isolatedRoot());
    });
}
