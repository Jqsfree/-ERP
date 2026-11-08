import 'package:sqflite/sqflite.dart';

/// Remove only v11 additions when constructing historical fixtures from a new DB.
void removeRefundArchiveTables(Map archive) {
  final tables = archive['tables'] as Map;
  tables.remove('sale_refund_events');
  tables.remove('refund_requests');
  for (final row in (tables['day_closures'] as List? ?? [])) {
    (row as Map).remove('refund_cutoff');
  }
  for (final row in (tables['sale_credit_events'] as List? ?? [])) {
    (row as Map).remove('refund_cutoff');
  }
}

Future<void> removeRefundDatabaseTables(Database db) async {
  await db.execute('DROP TABLE IF EXISTS sale_refund_events');
  await db.execute('DROP TABLE IF EXISTS refund_requests');
  for (final table in ['sale_credit_events', 'day_closures']) {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.any((c) => c['name'] == 'refund_cutoff')) {
      await db.execute('ALTER TABLE $table DROP COLUMN refund_cutoff');
    }
  }
}
