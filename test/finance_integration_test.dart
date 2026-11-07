import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/finance.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late String dbPath;
  late DateTime clock;
  late AppDatabase db;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kaibao-finance-');
    dbPath = p.join(temp.path, 'book.db');
    clock = DateTime(2026, 11, 7, 14);
    db = AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: dbPath, clock: () => clock);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  Future<int> sale() async {
    await db.addCustomer(const Customer(name: '财务测试客户', openingBalanceCents: 300));
    await db.addProduct(const Product(code: 'FIN-1', unitPriceCents: 2000));
    final customer = (await db.customers()).single;
    final product = (await db.products()).single;
    final saleId = await db.createSale(customer: customer,
      lines: [SaleLine(productId: product.id, code: product.code,
        lengthMilli: 10000, widthMilli: 2000, unitPriceCents: 2000)],
      discountCents: 0, initialReceivedCents: 5000);
    return saleId;
  }

  test('销售收款只进原付款表；其他收支、冲销对账不重复算应收', () async {
    final saleId = await sale();
    final originalSale = (await db.saleById(saleId))!;
    final originalDue = await db.customerOutstanding(originalSale.customerId);
    await db.addPayment(originalSale, 1000, method: '微信');
    final dueAfterPayment = await db.customerOutstanding(originalSale.customerId);

    final income = await db.recordCashEntry(kind: 'income', method: '现金',
      category: '利息', amountCents: 750, requestKey: 'other-income-0001');
    final expense = await db.recordCashEntry(kind: 'expense', method: '现金',
      category: '运费', amountCents: 1250, requestKey: 'transport-cost-0001');
    await db.recordCashEntry(kind: 'expense', method: '微信',
      category: '耗材', amountCents: 300, requestKey: 'material-cost-0001');
    expect(await db.cashEntries(), hasLength(3));
    expect((await db.cashEntries()).map((e) => e.id), containsAll([income, expense]));
    expect((await db.saleById(saleId))!.receivedCents, 6000);
    expect(originalDue - dueAfterPayment, 1000);

    final s = await db.dayStatement('2026-11-07');
    expect(s.salesReceiptsCents, 6000);
    expect(s.otherIncomeCents, 750);
    expect(s.otherExpenseCents, 1550);
    expect(s.reversalNetCents, 0);
    expect(s.expectedNetByMethod['现金'], -500);
    expect(s.expectedNetByMethod['微信'], 700);
    expect(s.expectedNetByMethod['其他'], 5000);
    expect(s.expectedNetCents, 5200);

    final reversal = await db.reverseCashEntry(originalEntryId: expense,
      requestKey: 'undo-transport-0001', reason: '重复报销');
    expect((await db.cashEntries()).first.id, reversal);
    expect((await db.cashEntries()).first.signedCents, 1250);
    final after = await db.dayStatement('2026-11-07');
    expect(after.reversalNetCents, 1250);
    expect(after.expectedNetByMethod['现金'], 750);
    expect(after.expectedNetCents, 6450);
    expect((await db.saleById(saleId))!.receivedCents, 6000);
    expect(await db.customerOutstanding(originalSale.customerId), dueAfterPayment);
    expect(await db.integrityOk(), isTrue);
  });

  test('收支写入同键并发只记一次，类型/金额变化拒绝；禁止伪装客户回款', () async {
    final ids = await Future.wait(List.generate(6, (_) =>
      db.recordCashEntry(kind: 'expense', method: '支付宝', category: '停车费',
        amountCents: 899, requestKey: 'duplicate-expense-01')));
    expect(ids.toSet(), hasLength(1));
    expect(await db.cashEntries(), hasLength(1));
    await expectLater(db.recordCashEntry(kind: 'expense', method: '支付宝',
      category: '停车费', amountCents: 900, requestKey: 'duplicate-expense-01'),
      throwsStateError);
    await expectLater(db.recordCashEntry(kind: 'income', method: '微信',
      category: '销售回款', amountCents: 100,
      requestKey: 'fake-sales-income-01'), throwsArgumentError);
    await expectLater(db.recordCashEntry(kind: 'income', method: '微信',
      category: '其他收入', amountCents: -1,
      requestKey: 'invalid-amount-entry'), throwsArgumentError);
    await expectLater(db.reverseCashEntry(originalEntryId: ids.first,
      requestKey: 'first-reversal-key', reason: '费用写错'), completes);
    await expectLater(db.reverseCashEntry(originalEntryId: ids.first,
      requestKey: 'different-reversal-key', reason: '再冲一次'), throwsStateError);
    expect(await db.cashEntries(), hasLength(2));
  });

  test('日结有差异必须填原因；关账快照锁住当天客户收款和费用', () async {
    final saleId = await sale();
    await db.recordCashEntry(kind: 'expense', method: '现金', category: '租金',
      amountCents: 1500, requestKey: 'rent-expense-00001');
    final s = await db.dayStatement('2026-11-07');
    final actual = {...s.expectedNetByMethod};
    actual['现金'] = actual['现金']! + 50;
    await expectLater(db.closeDay(day: '2026-11-07',
      requestKey: 'close-without-reason', actualNetByMethod: actual),
      throwsArgumentError);
    expect(await db.dayClose('2026-11-07'), isNull);
    final closedId = await db.closeDay(day: '2026-11-07',
      requestKey: 'closed-day-20261107', actualNetByMethod: actual,
      varianceReason: '现金盘点比系统多五角，等待人工确认');
    final closed = (await db.dayClose('2026-11-07'))!;
    expect(closed.id, closedId);
    expect(closed.differenceByMethod['现金'], 50);
    expect(closed.hasDifference, isTrue);
    expect(closed.varianceReason, contains('现金'));
    expect(await db.closeDay(day: '2026-11-07',
      requestKey: 'closed-day-20261107', actualNetByMethod: actual,
      varianceReason: closed.varianceReason), closedId);
    await expectLater(db.closeDay(day: '2026-11-07',
      requestKey: 'another-day-close-key', actualNetByMethod: actual,
      varianceReason: closed.varianceReason), throwsStateError);
    await expectLater(db.recordCashEntry(kind: 'income', method: '现金',
      category: '利息', amountCents: 1, requestKey: 'after-day-closed-01'),
      throwsStateError);
    await expectLater(db.addPayment((await db.saleById(saleId))!,
      100, method: '现金'), throwsStateError);
    await expectLater(db.createSale(customer: (await db.customers()).single,
      lines: const [SaleLine(code: 'AFTER', lengthMilli: 1000,
        widthMilli: 1000, unitPriceCents: 1000)],
      discountCents: 0, initialReceivedCents: 100), throwsStateError);
    expect((await db.saleById(saleId))!.receivedCents, 5000);
    expect((await db.dayStatement('2026-11-07')).expectedNetCents,
      s.expectedNetCents);
    expect(await db.integrityOk(), isTrue);
  });

  test('旧日期已关账后冲销原凭证：只追加到新日期，不改旧日结', () async {
    final original = await db.recordCashEntry(kind: 'expense', method: '现金',
      category: '邮费', amountCents: 1000, requestKey: 'day-one-expense-01');
    final first = await db.dayStatement('2026-11-07');
    await db.closeDay(day: '2026-11-07', requestKey: 'closed-day-one-key',
      actualNetByMethod: first.expectedNetByMethod);
    clock = DateTime(2026, 11, 8, 9);
    await db.reverseCashEntry(originalEntryId: original,
      requestKey: 'reverse-next-day-001', reason: '次日核实重复计提');
    expect((await db.dayStatement('2026-11-07')).expectedNetCents, -1000);
    expect((await db.dayStatement('2026-11-08')).expectedNetCents, 1000);
    expect((await db.dayClose('2026-11-07'))!.hasDifference, isFalse);
    final second = await db.dayStatement('2026-11-08');
    await expectLater(db.closeDay(day: '2026-11-09',
      requestKey: 'future-day-closing', actualNetByMethod: second.expectedNetByMethod),
      throwsArgumentError);
    await expectLater(db.closeDay(day: '2026-11-08',
      requestKey: 'missing-methods-close', actualNetByMethod: {'现金': 1000}),
      throwsArgumentError);
  });

  test('v5→v6 真实文件迁移保留原销售及收款与库存模型', () async {
    final saleId = await sale();
    await db.close();
    final old = await databaseFactoryFfi.openDatabase(dbPath);
    await old.execute('DROP TABLE day_closures');
    await old.execute('DROP TABLE cash_entries');
    await old.execute('DROP INDEX idx_payments_created_at');
    await old.setVersion(5);
    await old.close();
    final upgraded = AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: dbPath);
    try {
      expect(await (await upgraded.db).getVersion(), AppDatabase.schemaVersion);
      expect((await upgraded.saleById(saleId))!.receivedCents, 5000);
      expect(await upgraded.cashEntries(), isEmpty);
      expect(await upgraded.closedDays(), isEmpty);
      expect(await upgraded.integrityOk(), isTrue);
    } finally { await upgraded.close(); }
  });

  test('v6 加密备份包含资金凭证和日结，恢复后可回放；篡改拒绝', () async {
    final saleId = await sale();
    await db.recordCashEntry(kind: 'expense', method: '现金',
      category: '物业费', amountCents: 1200, requestKey: 'maintenance-expense-01');
    final expense = (await db.cashEntries()).single;
    await db.reverseCashEntry(originalEntryId: expense.id,
      requestKey: 'maintenance-reversal', reason: '账单重复');
    final s = await db.dayStatement('2026-11-07');
    final counted = {...s.expectedNetByMethod, '现金': 10};
    await db.closeDay(day: '2026-11-07', requestKey: 'backup-day-close-key',
      actualNetByMethod: counted, varianceReason: '现金实物净增与流水差一角');
    final json = await db.exportSnapshotJson();
    final snapshot = BackupSnapshot.parse(json);
    expect(snapshot.counts['cash_entries'], 2);
    expect(snapshot.counts['day_closures'], 1);
    final target = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'restore.db'));
    try {
      await target.restoreSnapshotJson(json);
      expect(await target.cashEntries(), hasLength(2));
      expect((await target.dayClose('2026-11-07'))!.differenceByMethod['现金'], 10);
      expect((await target.saleById(saleId))!.receivedCents, 5000);
      expect(await target.integrityOk(), isTrue);
      await target.close();
      final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi,
        databasePath: p.join(temp.path, 'restore.db'));
      try {
        expect((await reopened.dayStatement('2026-11-07')).expectedNetCents, 5000);
        expect((await reopened.dayClose('2026-11-07'))!.hasDifference, isTrue);
      } finally { await reopened.close(); }
    } finally { await target.close(); }

    final bad = jsonDecode(json) as Map<String, dynamic>;
    final tables = bad['tables'] as Map<String, dynamic>;
    ((tables['cash_entries'] as List).first as Map<String, dynamic>)['amount_cents'] = 1;
    expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
    final altered = jsonDecode(json) as Map<String, dynamic>;
    final tb = altered['tables'] as Map<String, dynamic>;
    ((tb['day_closures'] as List).first as Map<String, dynamic>)['expected_json'] =
      jsonEncode({'现金': 9999});
    expect(() => BackupSnapshot.parse(jsonEncode(altered)), throwsFormatException);
  });

  test('旧 v5 快照恢复到 v6，新增资金流水/日结表是真正空表', () async {
    final saleId = await sale();
    final raw = jsonDecode(await db.exportSnapshotJson()) as Map<String, dynamic>;
    raw['schemaVersion'] = 5;
    final tables = raw['tables'] as Map<String, dynamic>;
    tables.remove('cash_entries');
    tables.remove('day_closures');
    final previous = jsonEncode(raw);
    expect(BackupSnapshot.parse(previous).counts['cash_entries'], 0);
    final recovered = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'v5.db'));
    try {
      await recovered.restoreSnapshotJson(previous);
      expect((await recovered.saleById(saleId))!.receivedCents, 5000);
      expect(await recovered.cashEntries(), isEmpty);
      expect(await recovered.closedDays(), isEmpty);
      expect(await recovered.integrityOk(), isTrue);
    } finally { await recovered.close(); }
  });

  test('日结之后绕过应用层直接改原资金流水会被回放校验发现', () async {
    final saleId = await sale();
    final statement = await db.dayStatement('2026-11-07');
    await db.closeDay(day: '2026-11-07', requestKey: 'audit-day-close-key',
      actualNetByMethod: statement.expectedNetByMethod);
    await (await db.db).update('payments', {'amount_cents': 4500},
      where: 'sale_id=?', whereArgs: [saleId]);
    await expectLater(db.dayStatement('2026-11-07'), throwsStateError);
    await expectLater(db.exportSnapshotJson(), throwsFormatException);
  });
}
