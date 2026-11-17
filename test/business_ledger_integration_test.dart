import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/business_ledger_scenario.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('P2 integrated ledger: purchase, sales, revisions, cash, credit, stock, reopening and restore',
    () => verifyBusinessLedger(databaseFactoryFfi, Directory.systemTemp));

  test('Zero opening receipt preserves valid selected channel without creating cash',
    () => verifyZeroOpeningReceipt(databaseFactoryFfi, Directory.systemTemp));
}
