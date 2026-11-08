import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/services/sales_csv.dart';

void main() {
  sqfliteFfiInit();
  for (final count in [100, 1000]) {
    test('$count sales: numbering, debt and CSV', () async {
      final dir = await Directory.systemTemp.createTemp('kaibao-stress-');
      final db = AppDatabase.forTesting(factory: databaseFactoryFfi,
        databasePath: p.join(dir.path, 'test.db'), clock: () => DateTime(2026, 11, 7));
      try {
        await db.addCustomer(const Customer(name: '压力测试', openingBalanceCents: 500));
        final customer = (await db.customers()).single;
        final watch = Stopwatch()..start();
        for (var i = 0; i < count; i++) {
          await db.createSale(customer: customer,
            lines: [const SaleLine(code: '测试', lengthMilli: 1000, widthMilli: 1000, unitPriceCents: 1000)],
            discountCents: 100, initialReceivedCents: 400);
        }
        final sales = await db.sales();
        final csv = SalesCsvExporter.generate(sales);
        watch.stop();
        expect(sales, hasLength(count));
        expect(sales.map((sale) => sale.number).toSet(), hasLength(count));
        expect(sales.map((sale) => sale.number), contains('XS20261107${count.toString().padLeft(4, '0')}'));
        expect(await db.customerOutstanding(customer.id!), 500 + count * 500);
        expect('\n'.allMatches(csv.orders).length, count + 1);
        expect('\n'.allMatches(csv.lines).length, count + 1);
        expect(csv.orders, contains('XS202611070001'));
        // Diagnostic timings include inserts, readback and CSV generation.
        // ignore: avoid_print
        print('$count sales: ${watch.elapsedMilliseconds} ms');
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
