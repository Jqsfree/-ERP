import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/sale_revision.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SaleLine line({int? id, int price = 1000, int length = 1000,
  int width = 2000, int product = 1}) => SaleLine(id: id,
    productId: product, code: 'X', lengthMilli: length,
    widthMilli: width, unitPriceCents: price);

Sale original({int received = 0}) => Sale(id: 1, number: 'XS202611070001',
  date: '2026-11-07', customerId: 1, customerName: 'A', customerPhone: '',
  customerAddress: '', subtotalCents: 4000, discountCents: 0, priorDueCents: 0,
  receivedCents: received, status: 'confirmed', note: '',
  lines: [line(id: 11), line(id: 12)]);

void main() {
  test('同商品重复行按原行ID改价、减量、删除及新增，差额独立计算', () {
    final preview = SaleRevisionPreview.calculate(original: original(),
      lines: [line(id: 12, length: 500, price: 1200), line(price: 500)],
      discountCents: 100);
    expect(preview.number, 'XS202611070001');
    expect(preview.payableCents, 2100);
    expect(preview.amountDeltaCents, -1900);
    expect(preview.changes[0].before!.id, 12);
    expect(preview.changes[0].amountDeltaCents, -800);
    expect(preview.changes[1].before, isNull);
    expect(preview.changes[2].before!.id, 11);
    expect(preview.changes[2].after, isNull);
    expect(() => preview.lines.clear(), throwsUnsupportedError);
  });

  test('未、部分和全额收款的金额预览不重记或分配原收款', () {
    for (final received in [0, 1000, 4000]) {
      final sale = original(received: received);
      final preview = SaleRevisionPreview.calculate(original: sale,
        lines: [line(id: 11, price: 1500), line(id: 12)], discountCents: 0);
      expect(preview.amountDeltaCents, 1000);
      expect(preview.payableCents, 5000);
      expect(sale.receivedCents, received);
      expect(sale.payableCents, 4000);
    }
  });

  test('同商品改价与换商品/门幅有明确区分', () {
    for (final changed in [line(id: 11, product: 2), line(id: 11, width: 3000)]) {
      final result = SaleRevisionPreview.calculate(original: original(),
        lines: [changed, line(id: 12)], discountCents: 0);
      expect(result.changes.first.physicalIdentityChanged, isTrue);
    }
    final result = SaleRevisionPreview.calculate(original: original(),
      lines: [line(id: 11, price: 900), line(id: 12)], discountCents: 0);
    expect(result.changes.first.physicalIdentityChanged, isFalse);
  });

  test('拒绝跨单ID、重复ID、无明细、非法优惠和过大数值', () {
    for (final lines in <List<SaleLine>>[
      [line(id: 99)], [line(id: 11), line(id: 11)], [],
      [line(id: 11, length: 0)], [line(id: 11, price: -1)],
      [line(id: 11, length: 9223372036854775807)],
    ]) {
      expect(() => SaleRevisionPreview.calculate(original: original(),
        lines: lines, discountCents: 0), throwsArgumentError);
    }
    expect(() => SaleRevisionPreview.calculate(original: original(),
      lines: [line(id: 11)], discountCents: 2001), throwsArgumentError);
  });

  test('真实SQLite读单保留稳定行ID，重复预览不修改任何业务表', () async {
    sqfliteFfiInit();
    final temp = await Directory.systemTemp.createTemp('kaibao-revision-preview-');
    final path = p.join(temp.path, 'book.db');
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
    try {
      await db.addCustomer(const Customer(name: '预览客户'));
      await db.addProduct(const Product(code: 'X', unitPriceCents: 1000));
      final id = await db.createSale(customer: (await db.customers()).single,
        lines: [line(), line()], discountCents: 0, initialReceivedCents: 1000);
      final sale = (await db.saleById(id))!;
      final firstId = sale.lines.first.id!;
      expect(sale.lines.last.id, isNot(firstId));
      final before = (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
      for (var i = 0; i < 2; i++) {
        final preview = SaleRevisionPreview.calculate(original: sale,
          lines: [line(id: firstId, price: 900)], discountCents: 0);
        expect(preview.amountDeltaCents, -2200);
      }
      expect((jsonDecode(await db.exportSnapshotJson()) as Map)['tables'], before);
      await db.close();
      final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
      try {
        final restored = (await reopened.saleById(id))!;
        expect(restored.lines.first.id, firstId);
        expect(restored.receivedCents, 1000);
        expect(restored.payableCents, 4000);
      } finally {
        await reopened.close();
      }
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });
}
