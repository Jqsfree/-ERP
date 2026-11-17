import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/sales_store.dart';
import 'package:kaibao_sales/application/master_data_store.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/ui/pages.dart';
import 'package:kaibao_sales/ui/database_scope.dart';

/// UI tests use a synchronous-in-memory application port implementation.
/// True SQLite IO and process reopen are verified separately by database_integration_test.
class _InMemorySalesStore implements SalesStore, MasterDataStore {
  final _customers = <Customer>[];
  final _products = <Product>[];
  final _sales = <Sale>[];
  String? _draft;
  String? lastInitialPaymentMethod;

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
  Future<void> updateCustomer(Customer customer) async {
    final i = _customers.indexWhere((c) => c.id == customer.id);
    _customers[i] = customer;
  }
  @override
  Future<void> updateProduct(Product product) async {
    final i = _products.indexWhere((p) => p.id == product.id);
    _products[i] = product;
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
    required int discountCents, required int initialReceivedCents,
    String initialPaymentMethod = '其他', String note = ''}) async {
    lastInitialPaymentMethod = initialPaymentMethod;
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
  Future<void> addPayment(Sale sale, int amountCents, {required String requestKey, String method = '其他'}) async {
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
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('kaibao/image_album'), (call) async => {'saved': (call.arguments as Map)['indices'], 'error': null});
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('kaibao/image_album'), null);
  });
  testWidgets('资料页搜索、编辑、停用恢复与新单选择限制', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _InMemorySalesStore();
    await store.addCustomer(const Customer(name: 'Alpha', openingBalanceCents: 500));
    await store.addCustomer(const Customer(name: 'Beta'));
    await store.addProduct(const Product(code: 'X1', specification: 'old', unitPriceCents: 1000));

    Future<void> mount(Widget page) async {
      await tester.pumpWidget(DatabaseScope(key: UniqueKey(), database: store,
        child: MaterialApp(home: page)));
      await tester.pumpAndSettle();
    }
    await mount(const CustomersPage());
    await tester.enterText(find.widgetWithText(TextField, '搜索客户'), 'Alpha');
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsNothing);
    await tester.tap(find.byTooltip('编辑客户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '客户名称 *'), 'Alpha edited');
    final opening = find.descendant(of: find.widgetWithText(TextFormField, '初始欠款（元）'), matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(opening).readOnly, isTrue);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha edited（停用）'), findsOneWidget);
    expect((await store.customers()).first.openingBalanceCents, 500);
    expect((await store.customers()).first.active, isFalse);

    await mount(const ProductsPage());
    await tester.tap(find.byTooltip('编辑产品'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '规格型号（可空）'), 'new spec');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('X1（停用）'), findsOneWidget);
    expect((await store.products()).single.specification, 'new spec');
    expect((await store.products()).single.active, isFalse);

    await mount(const SaleEditorPage());
    await tester.tap(find.byType(DropdownButtonFormField<int>).first);
    await tester.pumpAndSettle();
    expect(find.text('Alpha edited'), findsNothing);
    expect(find.text('Beta'), findsWidgets);

    await mount(const ProductsPage());
    await tester.tap(find.byTooltip('编辑产品'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect((await store.products()).single.active, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('首页常用入口和无客户开单引导、草稿恢复与校验', (tester) async {
    final store = _InMemorySalesStore();
    await tester.pumpWidget(DatabaseScope(database: store,
      child: const MaterialApp(home: HomePage())));
    await tester.pumpAndSettle();
    expect(find.text('快速开单'), findsOneWidget);
    expect(find.text('找单／保存图片'), findsOneWidget);
    await tester.tap(find.text('快速开单'));
    await tester.pumpAndSettle();
    expect(find.text('尚无客户，请先新增客户。'), findsOneWidget);
    await tester.tap(find.text('新增客户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '客户名称 *'), '新客户');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(find.text('新客户'), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '产品型号 *'), '手填产品');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快速开单'));
    await tester.pumpAndSettle();
    expect(find.text('手填产品'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('下一步'), 250,
      scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(await store.sales(), isEmpty);
    await tester.scrollUntilVisible(find.widgetWithText(TextFormField, '米数 *'), -200,
      scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('请填写米数'), findsOneWidget);
  });

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

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(DropdownButtonFormField<int>).last);
    await tester.tap(find.byType(DropdownButtonFormField<int>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('KB56-34').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, '米数 *'), '37');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(TextFormField, '优惠金额（元）'), 200.0,
      scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.widgetWithText(TextFormField, '优惠金额（元）'), '0.36');
    await tester.scrollUntilVisible(
      find.widgetWithText(TextFormField, '开单已收款（元）'), 200.0,
      scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.widgetWithText(TextFormField, '开单已收款（元）'), '500');
    await tester.scrollUntilVisible(find.byType(DropdownButtonFormField<String>), 200.0,
      scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('微信').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('确认开单并保存图片'), 200.0,
      scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('确认开单并保存图片'));
    await tester.pumpAndSettle();

    final sales = await store.sales();
    expect(sales, hasLength(1));
    expect(sales.single.number, 'XS202611060001');
    expect(sales.single.payableCents, 144900);
    expect(sales.single.receivedCents, 50000);
    expect(store.lastInitialPaymentMethod, '微信');
    expect(sales.single.lines.single.areaText, '103.6');
    expect(find.text('销售单保存成功'), findsOneWidget);
    expect(find.text('NO.XS202611060001'), findsOneWidget);
    expect(find.textContaining('合同金额 ¥1449.00'), findsOneWidget);
  });
}
