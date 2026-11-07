import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../application/finance_store.dart';
import '../domain/finance.dart';

/// SQLite is the sole money-movement authority. All writes are committed once.
/// Day closures use the same transaction for query, validation and insertion.
class FinanceRepository implements FinanceStore {
  FinanceRepository(this.database, this.clock);

  final Database database;
  final DateTime Function() clock;

  Future<void> _ensureOpen(Transaction tx, String day) async {
    final rows = await tx.query('day_closures',
      columns: ['id'], where: 'business_date=?', whereArgs: [day]);
    if (rows.isNotEmpty) throw StateError('该业务日期已经日结，不允许新增或改写当天资金流水');
  }

  static void _checkCents(int amount) {
    if (amount <= 0 || amount > 9223372036854775807) {
      throw ArgumentError('金额应为合法的正整数分');
    }
  }

  static void _checkNote(String value, {int maxLength = 500}) {
    if (value.length > maxLength) throw ArgumentError('备注或原因超出长度限制');
  }

  static String _category(String category) {
    final value = category.trim();
    if (value.isEmpty || value.length > 80 ||
        FinanceMath.reservedCategories.contains(value)) {
      throw ArgumentError('分类为空或与销售收款/采购货款混淆，请使用独立非销售收支分类');
    }
    return value;
  }

  static String _method(String method) {
    if (!FinanceMath.methods.contains(method)) {
      throw ArgumentError('请选择支持的现金或支付渠道');
    }
    return method;
  }

  Future<String> _number(Transaction tx, String table, String prefix) async {
    final rows = await tx.rawQuery('''
      SELECT COALESCE(MAX(CAST(SUBSTR(number, ?) AS INTEGER)),0) AS latest
      FROM $table WHERE number LIKE ?
    ''', [prefix.length + 1, '$prefix%']);
    final serial = (rows.single['latest'] as int) + 1;
    return '$prefix${serial.toString().padLeft(4,'0')}';
  }

  Future<DayStatement> _statement(DatabaseExecutor tx, String day) async {
    final payments = await tx.rawQuery(
      'SELECT amount_cents, method, created_at FROM payments WHERE SUBSTR(created_at, 1, 10) = ?',
      [day]);
    final entries = await tx.query('cash_entries',
      columns: ['kind', 'business_date', 'amount_cents', 'direction', 'method'],
      where: 'business_date = ?', whereArgs: [day]);
    return FinanceMath.statement(day, payments, entries);
  }

  static DayClose _readClose(Map<String, Object?> row) {
    Map<String,int> asAmounts(String name) {
      final obj = jsonDecode(row[name] as String);
      if (obj is! Map<String, dynamic>) throw const FormatException('日结方式数据不是对象');
      return FinanceMath.normalized(obj.map((key, value) {
        if (value is! int) throw const FormatException('日结金额不是整数分');
        return MapEntry(key, value);
      }));
    }
    return DayClose(
      id: row['id'] as int, day: row['business_date'] as String,
      expectedNetByMethod: asAmounts('expected_json'),
      actualNetByMethod: asAmounts('actual_json'),
      varianceReason: row['variance_reason'] as String,
      createdAt: row['created_at'] as String,
    );
  }

  @override
  Future<int> recordCashEntry({
    required String kind, required String method, required String category,
    required int amountCents, required String requestKey, String note = '',
  }) async {
    if (kind != 'income' && kind != 'expense') {
      throw ArgumentError('这里只支持独立的其他收入或费用支出');
    }
    final key = FinanceMath.key(requestKey);
    final channel = _method(method);
    final type = _category(category);
    final remark = note.trim();
    _checkNote(remark);
    _checkCents(amountCents);
    final payload = jsonEncode({
      'kind': kind, 'method': channel, 'category': type,
      'amountCents': amountCents, 'note': remark,
    });
    return database.transaction((tx) async {
      final prior = await tx.query('cash_entries',
        columns: ['id','payload'], where: 'request_key=?', whereArgs: [key]);
      if (prior.isNotEmpty) {
        if (prior.single['payload'] != payload) {
          throw StateError('同一请求标识关联了不同收支记录');
        }
        return prior.single['id'] as int;
      }
      final now = clock();
      final date = FinanceMath.day(now);
      await _ensureOpen(tx, date);
      final prefix = '${kind == 'income' ? 'SR' : 'FZ'}${date.replaceAll('-', '')}';
      return tx.insert('cash_entries', {
        'number': await _number(tx, 'cash_entries', prefix),
        'business_date': date, 'kind': kind,
        'direction': kind == 'income' ? 1 : -1,
        'method': channel, 'category': type,
        'amount_cents': amountCents, 'original_entry_id': null,
        'request_key': key, 'payload': payload,
        'note': remark, 'created_at': now.toIso8601String(),
      });
    });
  }

  @override
  Future<int> reverseCashEntry({
    required int originalEntryId, required String requestKey, required String reason,
  }) async {
    final key = FinanceMath.key(requestKey);
    if (originalEntryId <= 0) throw ArgumentError('原始收支 ID 无效');
    final why = reason.trim();
    if (why.isEmpty || why.length > 500) throw ArgumentError('冲销原因必须填写');
    final payload = jsonEncode({'reverseOf': originalEntryId, 'reason': why});
    return database.transaction((tx) async {
      final oldKey = await tx.query('cash_entries', columns: ['id','payload'],
        where: 'request_key=?', whereArgs: [key]);
      if (oldKey.isNotEmpty) {
        if (oldKey.single['payload'] != payload) throw StateError('冲销请求标识冲突');
        return oldKey.single['id'] as int;
      }
      final original = await tx.query('cash_entries',
        where: 'id=?', whereArgs: [originalEntryId]);
      if (original.isEmpty || original.single['kind'] == 'reversal') {
        throw StateError('原始收支不存在或是冲销凭证');
      }
      final duplicate = await tx.query('cash_entries',
        columns: ['id'], where: 'original_entry_id=?', whereArgs: [originalEntryId]);
      if (duplicate.isNotEmpty) throw StateError('原始凭证已经冲销，不能重复处理');
      final now = clock();
      final date = FinanceMath.day(now);
      await _ensureOpen(tx, date);
      final source = original.single;
      final prefix = 'CX${date.replaceAll('-', '')}';
      return tx.insert('cash_entries', {
        'number': await _number(tx, 'cash_entries', prefix),
        'business_date': date, 'kind': 'reversal',
        'direction': -(source['direction'] as int),
        'method': source['method'], 'category': source['category'],
        'amount_cents': source['amount_cents'],
        'original_entry_id': originalEntryId,
        'request_key': key, 'payload': payload,
        'note': why, 'created_at': now.toIso8601String(),
      });
    });
  }

  @override
  Future<List<CashEntry>> cashEntries({String? day}) async {
    if (day != null) FinanceMath.validDay(day);
    final rows = await database.query('cash_entries',
      where: day == null ? null : 'business_date=?',
      whereArgs: day == null ? null : [day], orderBy: 'id DESC');
    return rows.map((r) => CashEntry(
      id: r['id'] as int, number: r['number'] as String,
      businessDate: r['business_date'] as String,
      kind: r['kind'] as String, method: r['method'] as String,
      category: r['category'] as String,
      amountCents: r['amount_cents'] as int,
      direction: r['direction'] as int,
      originalEntryId: r['original_entry_id'] as int?,
      note: r['note'] as String, createdAt: r['created_at'] as String,
    )).toList();
  }

  @override
  Future<DayStatement> dayStatement(String day) async {
    FinanceMath.validDay(day);
    return database.transaction((tx) async {
      final statement = await _statement(tx, day);
      final closed = await tx.query('day_closures',
        columns: ['expected_json'], where: 'business_date=?', whereArgs: [day]);
      if (closed.isNotEmpty &&
          closed.single['expected_json'] !=
            jsonEncode(statement.expectedNetByMethod)) {
        throw StateError('已日结日期的业务流水与关账快照不符，禁止静默覆盖差异');
      }
      return statement;
    });
  }

  @override
  Future<int> closeDay({
    required String day, required String requestKey,
    required Map<String, int> actualNetByMethod,
    String varianceReason = '',
  }) async {
    FinanceMath.validDay(day);
    if (day.compareTo(FinanceMath.day(clock())) > 0) {
      throw ArgumentError('未来日期不允许提前日结');
    }
    final key = FinanceMath.key(requestKey);
    final counted = FinanceMath.normalized(actualNetByMethod);
    final reason = varianceReason.trim();
    _checkNote(reason);
    return database.transaction((tx) async {
      final existing = await tx.query('day_closures',
        where: 'business_date=?', whereArgs: [day]);
      if (existing.isNotEmpty) {
        final row = existing.single;
        if (row['request_key'] == key &&
            row['actual_json'] == jsonEncode(counted) &&
            row['variance_reason'] == reason) {
          return row['id'] as int;
        }
        throw StateError('该日期已经关账，不能重复创建不同的日结报告');
      }
      final used = await tx.query('day_closures', columns: ['id'],
        where: 'request_key=?', whereArgs: [key]);
      if (used.isNotEmpty) throw StateError('日结请求标识已经用于其他日期');
      final statement = await _statement(tx, day);
      final expected = statement.expectedNetByMethod;
      if (expected.keys.toSet().difference(counted.keys.toSet()).isNotEmpty ||
          counted.keys.toSet().difference(expected.keys.toSet()).isNotEmpty) {
        throw ArgumentError('实际渠道净变动必须覆盖账面所有渠道，不能省略或新增渠道');
      }
      const maxCents = 9223372036854775807;
      if (counted.values.any((v) => v > maxCents || v < -maxCents)) {
        throw ArgumentError('实际渠道净变动超出 SQLite 整数范围');
      }
      final mismatched = expected.keys.any((k) => expected[k] != counted[k]);
      if (mismatched && reason.isEmpty) {
        throw ArgumentError('日结金额有差异，必须说明原因并保留差异');
      }
      final now = clock();
      return tx.insert('day_closures', {
        'business_date': day, 'request_key': key,
        'expected_json': jsonEncode(expected),
        'actual_json': jsonEncode(counted),
        'variance_reason': reason, 'created_at': now.toIso8601String(),
      });
    });
  }

  @override
  Future<DayClose?> dayClose(String day) async {
    FinanceMath.validDay(day);
    final rows = await database.query('day_closures',
      where: 'business_date=?', whereArgs: [day], limit: 1);
    return rows.isEmpty ? null : _readClose(rows.single);
  }

  @override
  Future<List<DayClose>> closedDays() async {
    final rows = await database.query('day_closures',
      orderBy: 'business_date DESC');
    return rows.map(_readClose).toList();
  }
}
