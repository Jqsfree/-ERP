import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/main.dart';
import 'package:kaibao_sales/application/sales_store.dart';
import 'package:kaibao_sales/application/payment_request_store.dart';
import 'package:kaibao_sales/application/customer_credit_store.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/payment_request.dart';
import 'package:kaibao_sales/domain/customer_credit.dart';
import 'package:kaibao_sales/ui/payment_page.dart';
import 'package:kaibao_sales/ui/pages.dart';
import 'package:kaibao_sales/ui/database_scope.dart';
import 'package:kaibao_sales/ui/customer_credit_page.dart';

const longCode = '很长的商品型号用于核对大字体下是否能完整选择并且继续填写';
const sample = Sale(id: 1, number: 'XS202611080001', date: '2026-11-08', customerId: 1,
  customerName: '名称较长的客户用于检查销售页面大字体换行情况', customerPhone: '13800000000', customerAddress: '',
  subtotalCents: 5600, discountCents: 0, priorDueCents: 0, receivedCents: 2000, status: 'confirmed', note: '',
  lines: [SaleLine(productId: 1, code: longCode, lengthMilli: 2000, widthMilli: 2800, unitPriceCents: 1000)]);
class LayoutStore extends Fake implements SalesStore, PaymentRequestStore {
  @override Future<List<Customer>> customers() async => [Customer(id: 1, name: sample.customerName)];
  @override Future<List<Product>> products() async => [const Product(id: 1, code: longCode, unitPriceCents: 1000)];
  @override Future<String?> loadDraft() async => jsonEncode({'schema': 1, 'step': 1, 'customerId': 1,
    'discount': '0', 'received': '0', 'note': '', 'lines': [{'productId': 1, 'code': longCode, 'spec': '', 'length': '2', 'width': '2.8', 'price': '10', 'note': ''}]});
  @override Future<void> saveDraft(String value) async {}
  @override Future<int> customerOutstanding(int id) async => 3600;
  @override Future<Sale?> saleById(int id) async => sample;
  @override Future<PaymentRequest?> latestPaymentRequest(int id) async => const PaymentRequest(key: 'layout-payment-001', saleId: 1, revision: 0, amountCents: 2000, method: '微信', status: 'posted', paymentId: 1);
}
class LayoutCredit extends Fake implements CustomerCreditStore {
  @override Future<CustomerCreditAccount> customerCreditAccount(int id) async => CustomerCreditAccount(
    customer: Customer(id: 1, name: sample.customerName), balanceCents: 8000,
    entries: const [CustomerCreditEntry(id: 1, saleId: 1, saleNumber: 'XS202611080001', deltaCents: 8000, balanceAfterCents: 8000, reason: '改单后应退款转入客户余额', createdAt: '2026-11-08T12:00:00')]);
}
void size(WidgetTester tester, Size value) {
  tester.view.physicalSize = value; tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
void main() {
  testWidgets('360dp/200%：长型号商品选择、核对页和键盘布局', (tester) async {
    size(tester, const Size(360, 800));
    await tester.pumpWidget(KaibaoApp(database: LayoutStore())); await tester.pumpAndSettle();
    await tester.tap(find.text('快速开单')); await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('下一步')); await tester.pumpAndSettle();
    expect(find.text('确认开单并保存图片'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle(); expect(tester.takeException(), isNull);
  });
  testWidgets('360dp/200%：收款恢复和历史单据、余额流水无溢出', (tester) async {
    size(tester, const Size(360, 800));
    final store = LayoutStore();
    Widget mount(Widget child) => DatabaseScope(database: store, child: MaterialApp(home: child));
    await tester.pumpWidget(mount(PaymentPage(sale: sample, store: store))); await tester.pumpAndSettle();
    expect(find.text('登记另一笔收款'), findsOneWidget); expect(tester.takeException(), isNull);
    await tester.pumpWidget(mount(const SaleDetailPage(sale: sample, historical: true))); await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('更多操作'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle(); expect(tester.takeException(), isNull);
    await tester.tap(find.text('更多操作')); await tester.pumpAndSettle(); expect(tester.takeException(), isNull);
    await tester.pumpWidget(mount(CustomerCreditPage(customerId: 1, store: LayoutCredit()))); await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0,-300)); await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
