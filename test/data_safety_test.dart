import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/money.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/domain/fulfillment.dart';
import 'package:kaibao_sales/services/bounded_bytes.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('十进制缩放及面积边界拒绝回绕，合法最大值精确', () {
    expect(Fixed.parse('92233720368547758.07', decimals: 2), 9223372036854775807);
    expect(() => Fixed.parse('92233720368547758.08', decimals: 2), throwsFormatException);
    expect(() => Fixed.parse('184467440737095516.17', decimals: 2), throwsFormatException);
    expect(() => Fixed.parse('18446744073709551.616', decimals: 3), throwsFormatException);
    expect(() => Fixed.parse('1' * 1000, decimals: 2), throwsFormatException);
    expect(() => BillingMath.areaMicro(4294967297, 4294967297), throwsArgumentError);
    expect(BillingMath.lineCents(1000, 1000, 1399), 1399);
    expect(Fixed.format(-9223372036854775808, decimals: 2), '-92233720368547758.08');
  });
  test('备份有界读取：元数据超限不打开流，伪造大小仍被阻止并取消流', () async {
    var opened = false;
    await expectLater(BoundedBytes.read(() { opened = true; return const Stream.empty(); }, limit: 8, reportedLength: 9), throwsFormatException);
    expect(opened, false);
    var cancelled = false;
    Stream<List<int>> source() async* {
      try { yield List.filled(8, 1); yield [1]; fail('越界后不应继续读取'); }
      finally { cancelled = true; }
    }
    await expectLater(BoundedBytes.read(source, limit: 8, reportedLength: 1), throwsFormatException);
    expect(cancelled, true);
    expect(await BoundedBytes.read(() => Stream.value([1,2,3]), limit: 3), [1,2,3]);
  });

  late Directory dir;
  late AppDatabase db;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('erp-safety-');
    db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: '${dir.path}/db');
  });
  tearDown(() async { await db.close(); await dir.delete(recursive: true); });
  Future<int> sale() async {
    await db.addCustomer(const Customer(name: 'C'));
    return db.createSale(customer: (await db.customers()).single, lines: const [SaleLine(code: 'X', lengthMilli: 1000, widthMilli: 1000, unitPriceCents: 10000)], discountCents: 0, initialReceivedCents: 0);
  }
  test('采购溢出写入完全回滚，恶意面积备份在恢复前拒绝', () async {
    await db.addProduct(const Product(code: 'A', unitPriceCents: 100));
    await db.addSupplier(const Supplier(name: 'S'));
    await expectLater(db.createPurchaseOrder(supplierId: 1, lines: const [PurchaseLine(productId: 1, code: 'A', lengthMilli: 4294967297, widthMilli: 4294967297, unitCostCents: 100)]), throwsArgumentError);
    expect(await (await db.db).query('purchase_orders'), isEmpty);
    expect(await (await db.db).query('purchase_lines'), isEmpty);
    final po = await db.createPurchaseOrder(supplierId: 1, lines: const [PurchaseLine(productId: 1, code: 'A', lengthMilli: 1000, widthMilli: 1000, unitCostCents: 100)]);
    final wh = await db.addWarehouse(code: 'W', name: 'W');
    await db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'safe-receipt-key-01', lines: [ReceiptInputLine(purchaseLineId: (await db.receivableLines(po)).single.lineId, warehouseId: wh, lengthMilli: 1000)]);
    final bad = jsonDecode(await db.exportSnapshotJson()) as Map;
    final tables = bad['tables'] as Map;
    final line = (tables['purchase_lines'] as List).single as Map;
    line['length_milli'] = 4294967297; line['width_milli'] = 4294967297; line['amount_cents'] = 858993;
    ((tables['purchase_orders'] as List).single as Map)['total_cents'] = 858993;
    final receipt = (tables['purchase_receipt_lines'] as List).single as Map;
    receipt['length_milli'] = 4294967297; receipt['width_milli'] = 4294967297; receipt['area_micro'] = 8589934593;
    expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
  });
  test('持久化收款：并发同键一次，不同payload拒绝，重启后同键仍不重复', () async {
    final id = await sale(); final original = (await db.saleById(id))!;
    await Future.wait(List.generate(5, (_) => db.addPayment(original, 2000, method: '微信', requestKey: 'payment-replay-key-01')));
    expect((await db.saleById(id))!.receivedCents, 2000);
    await expectLater(db.addPayment(original, 3000, method: '微信', requestKey: 'payment-replay-key-01'), throwsStateError);
    await db.close();
    await db.addPayment(original, 2000, method: '微信', requestKey: 'payment-replay-key-01');
    expect((await (await db.db).query('payments')), hasLength(1));
    // Another intentional payment with the same amount gets a new key.
    await db.addPayment(original, 2000, method: '微信', requestKey: 'payment-new-intent-02');
    expect((await db.saleById(id))!.receivedCents, 4000);
    final target = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: '${dir.path}/restore');
    try {
      await target.restoreSnapshotJson(await db.exportSnapshotJson());
      await target.addPayment(original, 2000, method: '微信', requestKey: 'payment-replay-key-01');
      expect((await target.saleById(id))!.receivedCents, 4000);
    } finally { await target.close(); }
  });
  test('收款请求与真实收款同事务失败回滚，已提交后即使日结仍可查询原结果', () async {
    final original = (await db.saleById(await sale()))!;
    final raw = await db.db;
    await db.preparePayment(original, 2000, requestKey: 'durable-request-001', method: '微信');
    await raw.execute("CREATE TRIGGER fail_request BEFORE UPDATE ON payment_requests BEGIN SELECT RAISE(ABORT, 'fault'); END");
    await expectLater(db.addPayment(original, 2000, method: '微信', requestKey: 'durable-request-001'), throwsA(isA<Exception>()));
    expect(await raw.query('payments'), isEmpty);
    expect((await db.latestPaymentRequest(original.id))!.status, 'pending');
    await raw.execute('DROP TRIGGER fail_request');
    await db.close();
    expect((await db.latestPaymentRequest(original.id))!.status, 'pending');
    await db.addPayment(original, 2000, method: '微信', requestKey: 'durable-request-001');
    final now = DateTime.now(); final day = '${now.year}-${now.month.toString().padLeft(2,'0')}-${now.day.toString().padLeft(2,'0')}';
    await db.closeDay(day: day, requestKey: 'close-replay-test-01', actualNetByMethod: {'微信': 2000, '支付宝': 0, '现金': 0, '银行转账': 0, '其他': 0});
    await db.addPayment(original, 2000, method: '微信', requestKey: 'durable-request-001');
    expect((await db.saleById(original.id))!.receivedCents, 2000);
  });
  test('未入账请求取消可重填，已入账不能取消，待处理请求可备份恢复', () async {
    final original = (await db.saleById(await sale()))!;
    await db.preparePayment(original, 2000, method: '微信', requestKey: 'pending-first-key-01');
    await expectLater(db.preparePayment(original, 2000, method: '微信', requestKey: 'pending-second-key-02'), throwsStateError);
    await db.cancelPaymentRequest('pending-first-key-01');
    await expectLater(db.addPayment(original, 2000, method: '微信', requestKey: 'pending-first-key-01'), throwsStateError);
    await db.preparePayment(original, 2000, method: '微信', requestKey: 'pending-second-key-02');
    final target = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: '${dir.path}/pending-restore');
    try {
      await target.restoreSnapshotJson(await db.exportSnapshotJson());
      expect((await target.latestPaymentRequest(original.id))!.status, 'pending');
      await target.addPayment(original, 2000, method: '微信', requestKey: 'pending-second-key-02');
      await expectLater(target.cancelPaymentRequest('pending-second-key-02'), throwsStateError);
      expect((await target.saleById(original.id))!.receivedCents, 2000);
      expect((await db.saleById(original.id))!.receivedCents, 0);
    } finally { await target.close(); }
  });
  test('库存身份：不一致新单拒绝；旧不一致行禁止出库且不自动重写', () async {
    await db.addCustomer(const Customer(name: 'C'));
    await db.addProduct(const Product(code: 'A', unitPriceCents: 100));
    Future<int> create(String code) => db.createSale(customer: const Customer(id: 1, name: 'C'), lines: [SaleLine(productId: 1, code: code, lengthMilli: 1000, widthMilli: 1000, unitPriceCents: 100)], discountCents: 0, initialReceivedCents: 0);
    await expectLater(create('B'), throwsStateError);
    expect(await db.sales(), isEmpty);
    final id = await create('A');
    final line = (await db.saleById(id))!.lines.single;
    // Reconstruct a legacy mismatch only in this isolated fixture.
    await (await db.db).update('sale_lines', {'code_snapshot': 'B'}, where: 'id=?', whereArgs: [line.id]);
    final wh = await db.addWarehouse(code: 'W', name: 'W');
    await expectLater(db.postSaleDispatch(saleId: id, requestKey: 'mismatch-dispatch-01', lines: [DispatchInputLine(saleLineId: line.id!, warehouseId: wh, lengthMilli: 1000)]), throwsStateError);
    expect(await (await db.db).query('sale_dispatches'), isEmpty);
    expect((await db.saleById(id))!.lines.single.code, 'B');
    expect(await db.checkDataIntegrity(), isNotEmpty);
    expect((await db.saleById(id))!.lines.single.code, 'B');
  });
}
