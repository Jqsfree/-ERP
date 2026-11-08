import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/ui/database_scope.dart';
import 'package:kaibao_sales/ui/pages.dart';
import 'package:kaibao_sales/services/invoice_pdf.dart';
import 'package:kaibao_sales/services/sales_csv.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('kaibao/image_album'), (call) async => {'saved': (call.arguments as Map)['indices'], 'error': null});
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('kaibao/image_album'), null);
  });
  testWidgets('真实DB+UI：待退款转余额→新单现金+抵扣→减量释放→历史/账务核对', (tester) async {
    sqfliteFfiInit();
    tester.view.physicalSize = const Size(1200, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('kaibao-credit-flow-ui-')))!;
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: p.join(temp.path, 'book.db'));
    Future<void> settle() async {
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
        if (!tester.binding.hasScheduledFrame && find.byType(CircularProgressIndicator).evaluate().isEmpty &&
            find.text('待退款读取中…').evaluate().isEmpty && find.text('待退货读取中…').evaluate().isEmpty) {
          return;
        }
      }
      fail('Credit flow UI did not settle');
    }
    Future<void> mount(Widget page) async {
      await tester.pumpWidget(DatabaseScope(key: UniqueKey(), database: db, child: MaterialApp(home: page)));
      await settle();
    }
    try {
      final source = (await tester.runAsync(() async {
        await db.addCustomer(const Customer(name: 'A'));
        await db.addProduct(const Product(code: 'X', unitPriceCents: 1000));
        final id = await db.createSale(customer: (await db.customers()).single,
          lines: const [SaleLine(productId: 1, code: 'X', lengthMilli: 20000,
            widthMilli: 1000, unitPriceCents: 1000)], discountCents: 0, initialReceivedCents: 20000);
        final sale = (await db.saleById(id))!;
        await db.reviseSale(saleId: id, expectedRevision: 0, requestKey: 'credit-ui-source-revise',
          customerId: 1, date: '2026-11-08', lines: [SaleLine(id: sale.lines.single.id,
            productId: 1, code: 'X', lengthMilli: 10000, widthMilli: 1000, unitPriceCents: 1000)],
          discountCents: 0, note: '减量');
        return (await db.saleById(id))!;
      }))!;
      await mount(SaleDetailPage(sale: source));
      // Scroll to a static anchor before awaiting lazy-built SQLite futures.
      await tester.scrollUntilVisible(find.text('更多操作'), 250, scrollable: find.byType(Scrollable).first);
      await settle();
      await tester.ensureVisible(find.text('转入A余额 ¥100.00'));
      await settle();
      expect(find.text('转入A余额 ¥100.00'), findsOneWidget);
      final before = await tester.runAsync(() async => (jsonDecode(await db.exportSnapshotJson()) as Map)['tables']);
      await tester.runAsync(() async => (await db.db).execute('''CREATE TRIGGER fail_credit_ui
        BEFORE INSERT ON sale_credit_events WHEN NEW.kind='transfer'
        BEGIN SELECT RAISE(ABORT, 'UI credit failure'); END'''));
      await tester.tap(find.text('转入A余额 ¥100.00'));
      await settle();
      await tester.tap(find.text('确认转入余额'));
      await settle();
      expect(find.textContaining('操作未完成：'), findsOneWidget);
      expect(find.textContaining('转入结果未能确认'), findsOneWidget);
      expect(await tester.runAsync(() async => (jsonDecode(await db.exportSnapshotJson()) as Map)['tables']), before);
      await tester.tap(find.text('关闭'));
      await settle();
      expect(find.text('转入A余额 ¥100.00'), findsOneWidget);
      await tester.runAsync(() async => (await db.db).execute('DROP TRIGGER fail_credit_ui'));
      await tester.tap(find.text('转入A余额 ¥100.00'));
      await settle();
      expect(find.text('待退款转余额'), findsOneWidget);
      await tester.tap(find.text('确认转入余额'));
      await settle();
      expect(find.textContaining('待退款：A'), findsNothing);
      expect(find.text('本客户收款已转余额'), findsOneWidget);
      expect((await tester.runAsync(() => db.customerCreditAccount(1)))!.balanceCents, 10000);
      await tester.scrollUntilVisible(find.text('更多操作'), 250, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('更多操作'));
      await settle();
      await tester.tap(find.text('查看客户余额与明细'));
      await settle();
      expect(find.text('可用余额 ¥100.00'), findsOneWidget);
      expect(find.textContaining('应退款转入余额'), findsOneWidget);
      await mount(const SaleEditorPage());
      await tester.tap(find.byType(DropdownButtonFormField<int>).first);
      await settle();
      await tester.tap(find.text('A').last);
      await settle();
      await tester.tap(find.text('下一步'));
      await settle();
      await tester.tap(find.byType(DropdownButtonFormField<int>).last);
      await settle();
      await tester.tap(find.text('X').last);
      await settle();
      await tester.enterText(find.widgetWithText(TextFormField, '米数 *'), '10');
      await tester.enterText(find.widgetWithText(TextFormField, '门幅 *'), '1');
      await tester.tap(find.text('下一步'));
      await settle();
      await tester.enterText(find.widgetWithText(TextFormField, '开单已收款（元）'), '20');
      await settle();
      expect(find.textContaining('预计余额抵扣 ¥80.00 · 预计未收 ¥0.00'), findsOneWidget);
      await tester.tap(find.text('确认开单并保存图片'));
      await settle();
      expect(find.text('余额抵扣'), findsOneWidget);
      expect(find.text('¥80.00'), findsOneWidget);
      final consumer = (await tester.runAsync(db.sales))!.firstWhere((s) => s.id != source.id);
      expect(consumer.creditAppliedCents, 8000);
      expect(consumer.receivedCents, 2000);
      expect(consumer.currentDueCents, 0);
      expect((await tester.runAsync(() => db.customerCreditAccount(1)))!.balanceCents, 2000);
      await tester.scrollUntilVisible(find.text('更多操作'), 250, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('更多操作'));
      await settle();
      await tester.tap(find.text('修改已确认销售单'));
      await settle();
      await tester.enterText(find.widgetWithText(TextFormField, '米数 *'), '6');
      await tester.tap(find.text('核对并保存修改'));
      await settle();
      expect(find.textContaining('释放原客户余额抵扣 ¥40.00'), findsOneWidget);
      await tester.tap(find.text('确认保存修改'));
      await settle();
      expect(find.text('版本 1（当前有效）'), findsOneWidget);
      expect(find.text('¥40.00'), findsOneWidget);
      expect((await tester.runAsync(() => db.customerCreditAccount(1)))!.balanceCents, 6000);
      expect((await tester.runAsync(() => db.saleRevisions(consumer.id)))!.last.sale.creditAppliedCents, 8000);
      await tester.runAsync(() async => BackupSnapshot.parse(await db.exportSnapshotJson()));
      await tester.runAsync(() async {
        final current = (await db.saleById(consumer.id))!;
        final csv = SalesCsvExporter.generate([current]);
        List<String> cells(String line) => RegExp(r'"((?:[^"]|"")*)"').allMatches(line)
          .map((m) => m.group(1)!.replaceAll('""', '"')).toList();
        final rows = csv.orders.split('\r\n');
        final headers = cells(rows[0]);
        final values = cells(rows[1]);
        String value(String field) => values[headers.indexOf(field)];
        expect(value('合同金额(元)'), '60.00');
        expect(value('已收(元)'), '20.00');
        expect(value('余额抵扣(元)'), '40.00');
        expect(value('未收(元)'), '0.00');
        expect(value('版本'), '1');
        final dir = Directory('build/phase3-output-evidence');
        await dir.create(recursive: true);
        final png = (await InvoicePdf.images(current)).single;
        final pdf = await InvoicePdf.bytes(current);
        expect(utf8.decode(pdf.take(4).toList()), '%PDF');
        await File(p.join(dir.path, 'credit-v1.png')).writeAsBytes(png);
        await File(p.join(dir.path, 'credit-v1.pdf')).writeAsBytes(pdf);
        await File(p.join(dir.path, 'credit-v1-orders.csv')).writeAsString(csv.orders);
        // Engine-generated artifacts only; this is not a physical print test.
      });
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async { await db.close(); await temp.delete(recursive: true); });
    }
  });
}
