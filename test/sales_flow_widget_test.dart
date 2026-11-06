import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/sales_store.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/ui/pages.dart';
import 'package:kaibao_sales/ui/database_scope.dart';

/// UI tests use a synchronous-in-memory application port implementation.
/// True SQLite IO and process reopen are verified separately by database_integration_test.
class _InMemorySalesStore implements SalesStore {
  final _customers = <Customer>[];
  final _products = <Product>[];
  final _sales = <Sale>[];
  String? _draft;

  @override
  Future<void> addCustomer(Customer customer) async {
    _customers.add(Customer(id: _customers.length + 1, name: customer.name,
      phone: customer.phone, address: customer.address,
      openingBalanceCents: customer.openingBalanceCents));
  }

  @override
  Future<void> addProduct(Product product) async {
    _products.add(Product(id: _products.length + 1, code: product.code,
      specification: product.specification, unitPriceCents: product.unitPriceCents));
  }

  @override
  Future<List<Customer>> customers() async => List.of(_customers);

  @override
  Future<List<Product>> products() async => List.of(_products);

  @override
  Future<List<Sale>> sales() async => List.of(_sales.reversed);

  @override
  Future<Sale?> saleById(int id) async {
    for (final sale in _sales) {
      if (sale.id == id) return sale;
    }
    return null;
  }

  @override
  Future<int> customerOutstanding(int customerId) async {
    final customer = _customers.firstWhere((c) => c.id == customerId);
    var due = customer.openingBalanceCents;
    for (final sale in _sales) {
      if (sale.customerId == customerId) due += sale.currentDueCents;
    }
    return due;
  }

  @override
  Future<int> createSale({required Customer customer, required List<SaleLine> lines,
    required int discountCents, required int initialReceivedCents, String note = ''}) async {
    final subtotal = lines.fold<int>(0, (sum, row) => sum + row.totalCents);
    final id = _sales.length + 1;
    _sales.add(Sale(id: id, number: 'XS202611060001', date: '2026-11-06',
      customerId: customer.id!, customerName: customer.name,
      customerPhone: customer.phone, customerAddress: customer.address,
      subtotalCents: subtotal, discountCents: discountCents, priorDueCents: 0,
      receivedCents: initialReceivedCents, status: 'confirmed', note: note,
      lines: List.of(lines)));
    _draft = null;
    return id;
  }

  @override
  Future<void> addPayment(Sale sale, int amountCents, {String method = '其他'}) async {
    final index = _sales.indexWhere((s) => s.id == sale.id);
    final prior = _sales[index];
    _sales[index] = Sale(id: prior.id, number: prior.number, date: prior.date,
      customerId: prior.customerId, customerName: prior.customerName,
      customerPhone: prior.customerPhone, customerAddress: prior.customerAddress,
      subtotalCents: prior.subtotalCents, discountCents: prior.discountCents,
      priorDueCents: prior.priorDueCents, receivedCents: prior.receivedCents + amountCents,
      status: prior.status, note: prior.note, lines: prior.lines);
  }

  @override
  Future<void> saveDraft(String jsonPayload) async { _draft = jsonPayload; }

  @override
  Future<String?> loadDraft() async => _draft;

  @override
  Future<void> deleteDraft() async { _draft = null; }
}

void main() {
  testWidgets('表单输入客户、产品及销售单，输出与 Application Port 一致',
      (tester) async {
    final store = _InMemorySalesStore();
    Future<void> mountPage(Widget page) async {
      await tester.pumpWidget(DatabaseScope(
        key: UniqueKey(),
        database: store,
        child: MaterialApp(home: page),
      ));
      await tester.pumpAndSettle();
    }

    await mountPage(const CustomersPage());
    await tester.tap(find.text('新增客户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '客户名称 *'), '客户A');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect((await store.customers()).single.name, '客户A');
    await mountPage(const ProductsPage());
    await tester.tap(find.text('新增产品'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '产品型号 *'), 'KB56-34');
    await tester.enterText(find.widgetWithText(TextFormField, '默认单价（元/平方米）*'), '13.99');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect((await store.products()).single.unitPriceCents, 1399);
    await mountPage(const SaleEditorPage());
    await tester.ensureVisible(find.byType(DropdownButtonFormField<int>).first);
    await tester.tap(find.byType(DropdownButtonFormField<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('客户A').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(DropdownButtonFormField<int>).last);
    await tester.tap(find.byType(DropdownButtonFormField<int>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('KB56-34').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, '米数 *'), '37');
    await tester.enterText(find.widgetWithText(TextFormField, '优惠金额（元）'), '0.36');
    await tester.enterText(find.widgetWithText(TextFormField, '开单已收款（元）'), '500');
    await tester.ensureVisible(find.text('确认销售并保存'));
    await tester.tap(find.text('确认销售并保存'));
    await tester.pumpAndSettle();

    final sales = await store.sales();
    expect(sales, hasLength(1));
    expect(sales.single.number, 'XS202611060001');
    expect(sales.single.payableCents, 144900);
    expect(sales.single.receivedCents, 50000);
    expect(sales.single.lines.single.areaText, '103.6');
    expect(find.text('NO.XS202611060001'), findsOneWidget);
    expect(find.text('¥1449.00'), findsWidgets);
  });
}
