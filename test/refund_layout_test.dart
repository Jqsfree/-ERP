import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/refund_store.dart';
import 'package:kaibao_sales/application/sales_store.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/sale_refund.dart';
import 'package:kaibao_sales/domain/sale_revision.dart';
import 'package:kaibao_sales/ui/refund_page.dart';

class LayoutStore implements RefundStore, SalesStore {
  final name = List.filled(8, '长客户名称').join();
  @override
  Future<Sale?> saleById(int id) async => Sale(
    id: id,
    number: 'XS202611080001',
    date: '2026-11-08',
    customerId: 1,
    customerName: name,
    customerPhone: '',
    customerAddress: '',
    subtotalCents: 10000,
    discountCents: 0,
    priorDueCents: 0,
    receivedCents: 20000,
    status: 'confirmed',
    note: '',
    lines: const [],
  );
  @override
  Future<List<PendingSaleRefund>> pendingSaleRefunds(int id) async => [
    PendingSaleRefund(
      customerId: 1,
      customerName: name,
      epoch: 0,
      amountCents: 10000,
    ),
  ];
  @override
  Future<List<SaleRefundEvent>> saleRefundEvents(int id) async => [];
  @override
  Future<RefundRequest?> latestRefundRequest(int id) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Layout fixture: ${invocation.memberName}');
}

void main() {
  for (final size in [
    const Size(320, 500),
    const Size(360, 500),
    const Size(411, 500),
    const Size(600, 320),
  ]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('退款页面与弹窗 $size 字号$scale 键盘与长客户名', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = LayoutStore();
        await tester.pumpWidget(
          MaterialApp(
            builder:
                (_, child) => MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(scale),
                    viewInsets: const EdgeInsets.only(bottom: 160),
                  ),
                  child: child!,
                ),
            home: RefundPage(saleId: 1, store: store, sales: store),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('登记已实际退款'),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('登记已实际退款'));
        await tester.pumpAndSettle();
        final field = find.widgetWithText(TextFormField, '已实际退款金额（元，必填）');
        await tester.ensureVisible(field);
        await tester.enterText(field, '30.00');
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(Checkbox));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        await tester.ensureVisible(find.text('确认登记实际退款'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('关闭'));
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
