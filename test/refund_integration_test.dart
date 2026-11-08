import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/services/backup_codec.dart';
import 'package:kaibao_sales/services/sales_csv.dart';

SaleLine line(int amount, {int? id}) => SaleLine(
  id: id,
  productId: 1,
  code: 'X',
  lengthMilli: amount,
  widthMilli: 1000,
  unitPriceCents: 1000,
);
void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late AppDatabase db;
  late DateTime now;
  late int sid;
  var serial = 0;
  Future<void> revise(int amount, {int customerId = 1}) async {
    final current = (await db.saleById(sid))!;
    await db.reviseSale(
      saleId: sid,
      expectedRevision: current.revision,
      requestKey: 'refund-revision-${serial++}',
      customerId: customerId,
      date: '2026-11-08',
      lines: [line(amount, id: current.lines.single.id)],
      discountCents: 0,
      note: '改单',
    );
  }

  Future<String> prepare(
    int amount, {
    String? key,
    int customer = 1,
    int epoch = 0,
    String method = '微信',
  }) async {
    final current = (await db.saleById(sid))!;
    final request = await db.prepareSaleRefund(
      saleId: sid,
      expectedRevision: current.revision,
      customerId: customer,
      epoch: epoch,
      amountCents: amount,
      method: method,
      requestKey: key ?? 'refund-request-${serial++}',
    );
    return request.key;
  }

  Future<int> refund(
    int amount, {
    String? key,
    int customer = 1,
    int epoch = 0,
  }) async => db.postRefundRequest(
    await prepare(amount, key: key, customer: customer, epoch: epoch),
  );
  Future<int> reverse(int id, {String? key}) async => db.postRefundRequest(
    (await db.prepareRefundReversal(
      originalEventId: id,
      reason: '误登记，已核对资金',
      fundsRecoveredOrMistake: true,
      requestKey: key ?? 'refund-reversal-${serial++}',
    )).key,
  );
  Future<void> audit() async {
    BackupSnapshot.parse(await db.exportSnapshotJson());
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('refund-flow-');
    now = DateTime(2026, 11, 8, 10);
    db = AppDatabase.forTesting(
      factory: databaseFactoryFfi,
      databasePath: '${dir.path}/source.db',
      clock: () => now,
    );
    await db.addCustomer(const Customer(name: 'A'));
    await db.addCustomer(const Customer(name: 'B'));
    await db.addProduct(const Product(code: 'X', unitPriceCents: 1000));
    sid = await db.createSale(
      customer: (await db.customers()).first,
      lines: [line(20000)],
      discountCents: 0,
      initialReceivedCents: 20000,
    );
    await revise(10000);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('部分退款+部分转余额+冲销保留事实，渠道日结净额与应收一致', () async {
    final first = await refund(3000);
    await db.transferSaleRefundToCredit(
      saleId: sid,
      expectedRevision: 1,
      customerId: 1,
      epoch: 0,
      amountCents: 4000,
      requestKey: 'refund-credit-combination',
    );
    expect((await db.pendingSaleRefunds(sid)).single.amountCents, 3000);
    await refund(3000);
    expect(await db.pendingSaleRefunds(sid), isEmpty);
    var sale = (await db.saleById(sid))!;
    expect(sale.refundedCents, 6000);
    expect(sale.transferredCents, 4000);
    expect(sale.currentDueCents, 0);
    expect(sale.receivedCents, 20000);
    expect(await db.customerOutstanding(1), 0);
    expect((await db.dayStatement('2026-11-08')).expectedNetCents, 14000);
    await reverse(first);
    expect((await db.pendingSaleRefunds(sid)).single.amountCents, 3000);
    expect((await db.saleRefundEvents(sid)).length, 3);
    final day = await db.dayStatement('2026-11-08');
    expect(day.salesRefundsCents, 6000);
    expect(day.refundReversalsCents, 3000);
    expect(day.expectedNetByMethod['微信'], -3000);
    expect(day.expectedNetCents, 17000);
    await revise(18000);
    sale = (await db.saleById(sid))!;
    expect(sale.netReceivedCents, 13000);
    expect(sale.currentDueCents, 5000);
    expect(await db.customerOutstanding(1), 5000);
    await db.addPayment(
      sale,
      5000,
      requestKey: 'refund-add-payment-after-revise',
    );
    expect((await db.saleById(sid))!.currentDueCents, 0);
    expect(
      SalesCsvExporter.generate([(await db.saleById(sid))!]).orders,
      contains('净实际退款'),
    );
    await audit();
  });

  test('同键并发、提交响应丢失和重开仅入账一次，持久化待办可取消', () async {
    final key = await prepare(5000);
    final results = await Future.wait(
      List.generate(5, (_) => db.postRefundRequest(key)),
    );
    expect(results.toSet().length, 1);
    await db.close();
    expect((await db.latestRefundRequest(sid))!.status, 'posted');
    expect(await db.postRefundRequest(key), results.first);
    expect((await db.saleById(sid))!.refundedCents, 5000);
    await expectLater(prepare(4000, key: key), throwsStateError);
    final pending = await prepare(2000);
    await db.close();
    expect((await db.latestRefundRequest(sid))!.key, pending);
    await expectLater(prepare(1000), throwsStateError);
    await db.cancelRefundRequest(pending);
    await expectLater(db.postRefundRequest(pending), throwsStateError);
    await expectLater(db.cancelRefundRequest(key), throwsStateError);
    await audit();
  });

  test('退款与转余额并发共用上限，旧版本、错客户、非正数及精度边界拒绝', () async {
    for (final n in [0, -1, 10001]) {
      await expectLater(
        prepare(n),
        throwsA(anyOf(isA<ArgumentError>(), isA<StateError>())),
      );
    }
    await expectLater(prepare(1, customer: 2), throwsStateError);
    await expectLater(prepare(1, method: '未知渠道'), throwsArgumentError);
    final key = await prepare(7000);
    final outcomes = await Future.wait([
      db.postRefundRequest(key).then((_) => true).catchError((_) => false),
      db
          .transferSaleRefundToCredit(
            saleId: sid,
            expectedRevision: 1,
            customerId: 1,
            epoch: 0,
            amountCents: 7000,
            requestKey: 'refund-racing-credit',
          )
          .then((_) => true)
          .catchError((_) => false),
    ]);
    expect(outcomes.where((ok) => ok).length, 1);
    expect((await db.pendingSaleRefunds(sid)).single.amountCents, 3000);
    if ((await db.refundRequest(key))!.status == 'pending') {
      await db.cancelRefundRequest(key);
    }
    final stale = await prepare(1000);
    await revise(9000);
    await expectLater(db.postRefundRequest(stale), throwsStateError);
    await db.cancelRefundRequest(stale);
    await audit();
  });

  test('冲销需原因及资金确认、不可冲销冲销、重复冲销拒绝，原日期日结冻结', () async {
    final id = await refund(2000);
    for (final caseValue in [('', true), ('原因', false)]) {
      await expectLater(
        db.prepareRefundReversal(
          originalEventId: id,
          reason: caseValue.$1,
          fundsRecoveredOrMistake: caseValue.$2,
          requestKey: 'invalid-reversal-confirmation',
        ),
        throwsArgumentError,
      );
    }
    final reversal = await reverse(id, key: 'refund-reverse-stable-key');
    expect(await reverse(id, key: 'refund-reverse-stable-key'), reversal);
    await expectLater(reverse(id), throwsStateError);
    await expectLater(reverse(reversal), throwsStateError);
    final other = await refund(3000);
    final day = await db.dayStatement('2026-11-08');
    await db.closeDay(
      day: day.day,
      actualNetByMethod: day.expectedNetByMethod,
      requestKey: 'refund-close-day-01',
    );
    await expectLater(prepare(1000), throwsStateError);
    now = DateTime(2026, 11, 9, 10);
    await expectLater(reverse(other), throwsStateError);
    await refund(1000);
    expect((await db.dayStatement('2026-11-09')).salesRefundsCents, 1000);
    expect(
      (await db.dayStatement('2026-11-08')).expectedNetCents,
      day.expectedNetCents,
    );
    await audit();
  });

  test('跨日冲销按登记日和原渠道反向计入，未日结原记录可冲销', () async {
    final id = await refund(3000);
    final before = await db.dayStatement('2026-11-08');
    now = DateTime(2026, 11, 9, 10);
    await reverse(id);
    expect(
      (await db.dayStatement('2026-11-08')).expectedNetCents,
      before.expectedNetCents,
    );
    final next = await db.dayStatement('2026-11-09');
    expect(next.refundReversalsCents, 3000);
    expect(next.expectedNetByMethod['微信'], 3000);
    expect(next.expectedNetCents, 3000);
    await db.closeDay(
      day: before.day,
      actualNetByMethod: before.expectedNetByMethod,
      requestKey: 'refund-close-prior-open-day',
    );
    await audit();
  });

  test('退款准备后强关重启、准备后日结冻结、原请求可核查不自动入账', () async {
    final key = await prepare(3000);
    await db.close();
    expect((await db.refundRequest(key))!.status, 'pending');
    expect((await db.saleRefundEvents(sid)), isEmpty);
    final id = await db.postRefundRequest(key);
    final pending = await prepare(1000);
    final day = await db.dayStatement('2026-11-08');
    await db.closeDay(
      day: day.day,
      actualNetByMethod: day.expectedNetByMethod,
      requestKey: 'refund-close-with-pending',
    );
    await expectLater(db.postRefundRequest(pending), throwsStateError);
    expect((await db.refundRequest(pending))!.status, 'pending');
    expect((await db.saleRefundEvents(sid)).single.id, id);
    expect((await db.saleRefundEvents(sid)).single.closed, isTrue);
    await db.cancelRefundRequest(pending);
    await audit();
  });

  test('退款及冲销事务故障全回滚，请求保留后可原键重试', () async {
    final key = await prepare(3000);
    final raw = await db.db;
    final before = (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
    await raw.execute(
      "CREATE TRIGGER fail_refund BEFORE UPDATE ON refund_requests BEGIN SELECT RAISE(ABORT, 'fail request update'); END",
    );
    await expectLater(
      db.postRefundRequest(key),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'],
      before,
    );
    await raw.execute('DROP TRIGGER fail_refund');
    final id = await db.postRefundRequest(key);
    final r = await db.prepareRefundReversal(
      originalEventId: id,
      reason: '误登记',
      fundsRecoveredOrMistake: true,
      requestKey: 'refund-failed-reversal',
    );
    final beforeReverse =
        (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
    await raw.execute(
      "CREATE TRIGGER fail_reverse BEFORE INSERT ON sale_refund_events WHEN NEW.kind='reversal' BEGIN SELECT RAISE(ABORT, 'fail reversal'); END",
    );
    await expectLater(
      db.postRefundRequest(r.key),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'],
      beforeReverse,
    );
    await raw.execute('DROP TRIGGER fail_reverse');
    await db.postRefundRequest(r.key);
    expect((await db.saleById(sid))!.refundedCents, 0);
    await audit();
  });

  test('换客户后退款归属隔离、连续改单历史不变、加密备份恢复重开及篡改拒绝', () async {
    await refund(3000);
    await revise(10000, customerId: 2);
    expect((await db.saleById(sid))!.refundedCents, 0);
    expect((await db.pendingSaleRefunds(sid)).single.amountCents, 17000);
    await refund(5000);
    await revise(12000, customerId: 2);
    final history = await db.saleRevisions(sid);
    expect(history.first.sale.refundedCents, 0);
    expect(history.first.refunds.single.amountCents, 12000);
    final plain = await db.exportSnapshotJson();
    final file = File('${dir.path}/refund.kberp');
    await file.writeAsBytes(
      await BackupCodec.encrypt(plain, 'refund-backup-password-2026'),
      flush: true,
    );
    final clear = await BackupCodec.decrypt(
      await file.readAsBytes(),
      'refund-backup-password-2026',
    );
    await db.verifySnapshotJson(clear);
    final target = AppDatabase.forTesting(
      factory: databaseFactoryFfi,
      databasePath: '${dir.path}/target.db',
    );
    try {
      await target.restoreSnapshotJson(clear);
      await target.close();
      expect((await target.pendingSaleRefunds(sid)).single.amountCents, 12000);
      expect(
        (jsonDecode(await target.exportSnapshotJson()) as Map)['tables'],
        (jsonDecode(plain) as Map)['tables'],
      );
    } finally {
      await target.close();
    }
    for (final field in [
      'amount_cents',
      'customer_id',
      'customer_epoch',
      'sale_version',
      'credit_cutoff',
      'request_key',
    ]) {
      final bad = jsonDecode(plain) as Map;
      (((bad['tables'] as Map)['sale_refund_events'] as List).first
              as Map)[field] =
          field == 'request_key' ? 'tampered-request-key' : 99999;
      expect(
        () => BackupSnapshot.parse(jsonEncode(bad)),
        throwsFormatException,
        reason: field,
      );
    }
  });
}
