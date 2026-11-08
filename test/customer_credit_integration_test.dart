import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/domain/fulfillment.dart';
import 'package:kaibao_sales/services/backup_codec.dart';
import 'package:kaibao_sales/services/bounded_bytes.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SaleLine creditLine(int amount, {int? id}) => SaleLine(id: id, productId: 1,
  code: 'X', lengthMilli: amount, widthMilli: 1000, unitPriceCents: 1000);

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late AppDatabase db;
  late int source;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kaibao-credit-flow-');
    db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: p.join(temp.path, 'source.db'),
      clock: () => DateTime(2026, 11, 8, 10));
    await db.addCustomer(const Customer(name: 'A'));
    await db.addCustomer(const Customer(name: 'B'));
    await db.addProduct(const Product(code: 'X', unitPriceCents: 1000));
    source = await db.createSale(customer: (await db.customers()).first,
      lines: [creditLine(20000)], discountCents: 0, initialReceivedCents: 20000);
    final line = (await db.saleById(source))!.lines.single;
    await db.reviseSale(saleId: source, expectedRevision: 0, requestKey: 'credit-source-revise-01',
      customerId: 1, date: '2026-11-08', lines: [creditLine(10000, id: line.id)], discountCents: 0, note: '减价');
  });
  tearDown(() async { await db.close(); await temp.delete(recursive: true); });

  Future<int> transfer({String key = 'credit-source-transfer-01', int amount = 10000,
    int customer = 1, int version = 1}) => db.transferSaleRefundToCredit(saleId: source,
      expectedRevision: version, customerId: customer, epoch: 0, amountCents: amount, requestKey: key);
  Future<int> sale(int payable, int cash, {String key = 'credit-create-request-01'}) async =>
    db.createSaleWithCredit(customer: (await db.customers()).first,
      lines: [creditLine(payable)], discountCents: 0, initialReceivedCents: cash, requestKey: key);
  Future<int> revise(int id, int amount, {int customer = 1}) async {
    final current = (await db.saleById(id))!;
    return db.reviseSale(saleId: id, expectedRevision: current.revision,
      requestKey: 'credit-modify-$id-${current.revision}', customerId: customer,
      date: '2026-11-08', lines: [creditLine(amount, id: current.lines.single.id)],
      discountCents: 0, note: '余额后改单');
  }

  test('整笔待退款转余额：并发重试不重复返还、错客/超额/过期拒绝、不伪造现金', () async {
    await expectLater(transfer(amount: 10001), throwsStateError);
    await expectLater(transfer(customer: 2), throwsStateError);
    await expectLater(transfer(version: 0), throwsStateError);
    final ids = await Future.wait(List.generate(4, (_) => transfer()));
    expect(ids.toSet().length, 1);
    expect((await db.customerCreditAccount(1)).balanceCents, 10000);
    expect(await db.pendingSaleRefunds(source), isEmpty);
    expect((await db.saleById(source))!.receivedCents, 20000);
    expect((await db.saleById(source))!.transferredCents, 10000);
    expect((await db.saleById(source))!.currentDueCents, 0);
    expect((await db.dayStatement('2026-11-08')).salesReceiptsCents, 20000);
    await expectLater(transfer(key: 'credit-source-transfer-02'), throwsStateError);
    await expectLater(transfer(amount: 1), throwsStateError);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('部分转余额：响应丢失重试、不同请求并发防超额、恢复重开核账', () async {
    final first = await transfer(amount: 3000);
    expect(await transfer(amount: 3000), first);
    await expectLater(transfer(amount: 3001), throwsStateError);
    expect((await db.pendingSaleRefunds(source)).single.amountCents, 7000);
    final outcomes = await Future.wait(List.generate(2, (i) async {
      try { await transfer(amount: 5000, key: 'partial-racing-request-$i'); return true; }
      on StateError { return false; }
    }));
    expect(outcomes.where((ok) => ok).length, 1);
    expect((await db.pendingSaleRefunds(source)).single.amountCents, 2000);
    expect((await db.customerCreditAccount(1)).balanceCents, 8000);
    expect((await db.dayStatement('2026-11-08')).salesReceiptsCents, 20000);
    final plain = await db.exportSnapshotJson();
    BackupSnapshot.parse(plain);
    const password = 'partial-credit-file-verification';
    final file = File(p.join(temp.path, 'partial-credit.kberp'));
    await file.writeAsBytes(await BackupCodec.encrypt(plain, password), flush: true);
    final encrypted = await BoundedBytes.read(file.openRead,
      limit: BackupCodec.maxEncryptedBytes, reportedLength: await file.length());
    final verified = await db.verifySnapshotJson(await BackupCodec.decrypt(encrypted, password));
    expect(verified['sales'], 1);
    expect((jsonDecode(await db.exportSnapshotJson()) as Map)['tables'],
      (jsonDecode(plain) as Map)['tables']);
    final targetPath = p.join(temp.path, 'partial-restored.db');
    final target = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: targetPath);
    await target.restoreSnapshotJson(plain);
    await target.close();
    final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: targetPath);
    try {
      expect((await reopened.pendingSaleRefunds(source)).single.amountCents, 2000);
      expect((await reopened.customerCreditAccount(1)).balanceCents, 8000);
      expect((jsonDecode(await reopened.exportSnapshotJson()) as Map)['tables'],
        (jsonDecode(plain) as Map)['tables']);
    } finally { await reopened.close(); }
    final bad = jsonDecode(plain) as Map;
    final events = (bad['tables'] as Map)['sale_credit_events'] as List;
    final ledger = (bad['tables'] as Map)['customer_credit_entries'] as List;
    final event = events.last as Map;
    event['amount_cents'] = 8000;
    (ledger.last as Map)['delta_cents'] = 8000;
    final payload = jsonDecode(event['payload'] as String) as Map;
    payload['amountCents'] = 8000;
    event['payload'] = jsonEncode(payload);
    expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
    await expectLater(db.verifySnapshotJson(jsonEncode(bad)), throwsFormatException);
    expect((jsonDecode(await db.exportSnapshotJson()) as Map)['tables'],
      (jsonDecode(plain) as Map)['tables']);
  });

  for (final scenario in [(8000, 2000, 6000, 4000, 0),
                          (20000, 2000, 10000, 0, 8000),
                          (10000, 10000, 0, 10000, 0)]) {
    test('现金优先+余额：合同${scenario.$1}、现金${scenario.$2}，抵扣${scenario.$3}、未收${scenario.$5}', () async {
      await transfer();
      final id = await sale(scenario.$1, scenario.$2);
      final current = (await db.saleById(id))!;
      expect(current.receivedCents, scenario.$2);
      expect(current.creditAppliedCents, scenario.$3);
      expect(current.currentDueCents, scenario.$5);
      expect((await db.customerCreditAccount(1)).balanceCents, scenario.$4);
      expect(await db.customerOutstanding(1), scenario.$5);
      expect((await db.dayStatement('2026-11-08')).salesReceiptsCents, 20000 + scenario.$2);
      if (current.currentDueCents > 0) {
        await expectLater(db.addPayment(current, current.currentDueCents + 1, requestKey: 'fixture-customer_credit_integration_test-1'), throwsArgumentError);
        await db.addPayment(current, current.currentDueCents, requestKey: 'fixture-customer_credit_integration_test-2');
        expect((await db.saleById(id))!.currentDueCents, 0);
      }
      BackupSnapshot.parse(await db.exportSnapshotJson());
    });
  }

  test('同键并发开单只抵扣一次，不同订单并发不能超用同一余额', () async {
    await transfer();
    final ids = await Future.wait(List.generate(4, (_) => sale(8000, 2000)));
    expect(ids.toSet().length, 1);
    expect((await db.customerCreditAccount(1)).balanceCents, 4000);
    await expectLater(sale(9000, 2000), throwsStateError);
    final more = await Future.wait([sale(8000, 0, key: 'credit-racing-order-01'),
      sale(8000, 0, key: 'credit-racing-order-02')]);
    final orders = await Future.wait(more.map(db.saleById));
    expect(orders.fold<int>(0, (n,s) => n + s!.creditAppliedCents), 4000);
    expect(orders.fold<int>(0, (n,s) => n + s!.currentDueCents), 12000);
    expect((await db.customerCreditAccount(1)).balanceCents, 0);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('减价先释放多余抵扣，增价不追加，换客全释放；现金单独待退', () async {
    await transfer();
    final id = await sale(10000, 2000);
    await revise(id, 6000);
    var current = (await db.saleById(id))!;
    expect(current.creditAppliedCents, 4000);
    expect((await db.customerCreditAccount(1)).balanceCents, 6000);
    expect((await db.saleRevisions(id)).last.sale.creditAppliedCents, 8000);
    await revise(id, 9000);
    current = (await db.saleById(id))!;
    expect(current.creditAppliedCents, 4000);
    expect(current.currentDueCents, 3000);
    expect((await db.customerCreditAccount(1)).balanceCents, 6000);
    await revise(id, 9000, customer: 2);
    current = (await db.saleById(id))!;
    expect(current.creditAppliedCents, 0);
    expect(current.receivedCents, 0);
    expect(current.currentDueCents, 9000);
    expect((await db.customerCreditAccount(1)).balanceCents, 10000);
    expect((await db.pendingSaleRefunds(id)).single.amountCents, 2000);
    expect((await db.customerCreditAccount(2)).balanceCents, 0);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('转余额后再次增减价：新应收重新付款，不追回或重复抵扣已转余额', () async {
    await transfer();
    await revise(source, 15000);
    var current = (await db.saleById(source))!;
    expect(current.currentDueCents, 5000);
    expect(current.creditAppliedCents, 0);
    expect((await db.customerCreditAccount(1)).balanceCents, 10000);
    await db.addPayment(current, 5000, requestKey: 'fixture-customer_credit_integration_test-3');
    await revise(source, 5000);
    expect((await db.pendingSaleRefunds(source)).single.amountCents, 10000);
    await db.transferSaleRefundToCredit(saleId: source, expectedRevision: 3,
      customerId: 1, epoch: 0, amountCents: 10000, requestKey: 'credit-source-transfer-more');
    expect((await db.customerCreditAccount(1)).balanceCents, 20000);
    expect(await db.pendingSaleRefunds(source), isEmpty);
    current = (await db.saleById(source))!;
    expect(current.netReceivedCents, 5000);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('减至低于现金：先返还全部余额抵扣，再仅将现金超收转余额', () async {
    await transfer();
    final id = await sale(10000, 2000);
    await revise(id, 1000);
    expect((await db.saleById(id))!.creditAppliedCents, 0);
    expect((await db.customerCreditAccount(1)).balanceCents, 10000);
    expect((await db.pendingSaleRefunds(id)).single.amountCents, 1000);
    await db.transferSaleRefundToCredit(saleId: id, expectedRevision: 1,
      customerId: 1, epoch: 0, amountCents: 1000, requestKey: 'credit-consumer-transfer');
    expect((await db.customerCreditAccount(1)).balanceCents, 11000);
    expect((await db.saleById(id))!.currentDueCents, 0);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('转入、抵扣、改单释放的事务故障均全表回滚，修复后重试成功', () async {
    final raw = await db.db;
    Future<void> fault(String kind) => raw.execute('''CREATE TRIGGER fail_credit BEFORE INSERT ON sale_credit_events
      WHEN NEW.kind='$kind' BEGIN SELECT RAISE(ABORT, 'credit failure'); END''');
    Future<Object?> snapshot() async => (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
    var before = await snapshot();
    await fault('transfer');
    await expectLater(transfer(), throwsA(isA<DatabaseException>()));
    expect(await snapshot(), before);
    await raw.execute('DROP TRIGGER fail_credit');
    await transfer();
    await db.saveDraft('draft must survive failure');
    before = await snapshot();
    await fault('apply');
    await expectLater(sale(10000, 2000), throwsA(isA<DatabaseException>()));
    expect(await snapshot(), before);
    await raw.execute('DROP TRIGGER fail_credit');
    final id = await sale(10000, 2000);
    before = await snapshot();
    await fault('release');
    await expectLater(revise(id, 6000), throwsA(isA<DatabaseException>()));
    expect(await snapshot(), before);
    await raw.execute('DROP TRIGGER fail_credit');
    await revise(id, 6000);
    expect((await db.customerCreditAccount(1)).balanceCents, 6000);
    expect(await db.integrityOk(), isTrue);
  });

  test('金额超范围开单被拒绝，余额和既有业务不变', () async {
    await transfer();
    final before = (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
    await expectLater(db.createSaleWithCredit(customer: (await db.customers()).first,
      lines: const [SaleLine(productId: 1, code: 'X', lengthMilli: 9223372036854775807,
        widthMilli: 2000, unitPriceCents: 1000)], discountCents: 0,
      initialReceivedCents: 0, requestKey: 'credit-overflow-order'), throwsArgumentError);
    expect((jsonDecode(await db.exportSnapshotJson()) as Map)['tables'], before);
  });

  test('跨午夜补收款只取一次发生时间，关账校验日期与实际入账日期一致', () async {
    await transfer();
    final id = await sale(20000, 2000);
    await db.close();
    var ticks = 0;
    db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: p.join(temp.path, 'source.db'),
      clock: () => ++ticks == 1 ? DateTime(2026, 11, 8, 23, 59, 59) : DateTime(2026, 11, 9));
    await db.addPayment((await db.saleById(id))!, 1000, requestKey: 'fixture-customer_credit_integration_test-4');
    expect(ticks, 1);
    expect((await db.dayStatement('2026-11-08')).salesReceiptsCents, 23000);
    expect((await db.dayStatement('2026-11-09')).salesReceiptsCents, 0);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('余额全链加密备份恢复与重启逐表一致，篡改分配/转入/来源被拒绝', () async {
    await transfer();
    final id = await sale(10000, 2000);
    await revise(id, 6000);
    final plain = await db.exportSnapshotJson();
    const password = 'credit-backup-passphrase-2026';
    final encrypted = await BackupCodec.encrypt(plain, password);
    final targetPath = p.join(temp.path, 'target.db');
    final target = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: targetPath);
    await target.restoreSnapshotJson(await BackupCodec.decrypt(encrypted, password));
    await target.close();
    final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: targetPath);
    try {
      expect((jsonDecode(await reopened.exportSnapshotJson()) as Map)['tables'], (jsonDecode(plain) as Map)['tables']);
      expect((await reopened.customerCreditAccount(1)).balanceCents, 6000);
      expect((await reopened.saleById(id))!.creditAppliedCents, 4000);
      expect(await reopened.customerOutstanding(1), 0);
    } finally { await reopened.close(); }
    for (final field in ['amount_cents', 'customer_epoch', 'ledger_entry_id']) {
      final bad = jsonDecode(plain) as Map<String,dynamic>;
      final events = (bad['tables'] as Map)['sale_credit_events'] as List;
      (events[1] as Map)[field] = 999;
      expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
    }
    final bad = jsonDecode(plain) as Map<String,dynamic>;
    ((bad['tables'] as Map)['sale_credit_events'] as List).removeLast();
    expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
  });

  test('跨模块：出库→改单→日结→转余额→新单抵扣→实物退回→次日收余款', () async {
    await db.addSupplier(const Supplier(name: 'S'));
    final wh = await db.addWarehouse(code: 'W', name: '仓库');
    final po = await db.createPurchaseOrder(supplierId: 1, lines: const [
      PurchaseLine(productId: 1, code: 'X', lengthMilli: 30000, widthMilli: 1000, unitCostCents: 500)]);
    await db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'credit-inventory-receipt',
      lines: [ReceiptInputLine(purchaseLineId: (await db.receivableLines(po)).single.lineId,
        warehouseId: wh, lengthMilli: 30000)]);
    final sale = (await db.saleById(source))!;
    final dispatch = await db.postSaleDispatch(saleId: source, requestKey: 'credit-inventory-dispatch',
      lines: [DispatchInputLine(saleLineId: sale.lines.single.id!, warehouseId: wh, lengthMilli: 10000)]);
    await revise(source, 6000);
    expect((await db.pendingSaleReturns(source)).single.lengthMilli, 4000);
    final stock = (await db.stockBalances()).single.areaMicro;
    final day = await db.dayStatement('2026-11-08');
    await db.closeDay(day: day.day, actualNetByMethod: day.expectedNetByMethod, requestKey: 'credit-day-close-001');
    await transfer(amount: 14000, version: 2);
    expect((await db.stockBalances()).single.areaMicro, stock);
    expect((await db.dayStatement('2026-11-08')).expectedNetCents, 20000);
    final consumer = await saleWithCreditForIntegration(db, 15000);
    var current = (await db.saleById(consumer))!;
    expect(current.creditAppliedCents, 14000);
    expect(current.currentDueCents, 1000);
    await expectLater(db.addPayment(current, 1000, requestKey: 'fixture-customer_credit_integration_test-5'), throwsStateError);
    final row = (await db.returnableLines(dispatch)).single;
    await db.postSaleReturn(dispatchId: dispatch, requestKey: 'credit-inventory-return',
      lines: [ReturnInputLine(dispatchLineId: row.lineId, lengthMilli: 4000)]);
    expect(await db.pendingSaleReturns(source), isEmpty);
    expect((await db.stockBalances()).single.areaMicro, stock + 4000000);
    await db.close();
    db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: p.join(temp.path, 'source.db'),
      clock: () => DateTime(2026, 11, 9, 10));
    current = (await db.saleById(consumer))!;
    await db.addPayment(current, 1000, requestKey: 'fixture-customer_credit_integration_test-6');
    expect((await db.saleById(consumer))!.currentDueCents, 0);
    expect((await db.dayStatement('2026-11-08')).expectedNetCents, 20000);
    expect((await db.dayStatement('2026-11-09')).expectedNetCents, 1000);
    expect((await db.customerCreditAccount(1)).balanceCents, 0);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });
}

Future<int> saleWithCreditForIntegration(AppDatabase db, int payable) async =>
  db.createSaleWithCredit(customer: (await db.customers()).first,
    lines: [creditLine(payable)], discountCents: 0, initialReceivedCents: 0,
    requestKey: 'credit-inventory-consumer');
