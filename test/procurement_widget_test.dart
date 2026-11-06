import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/procurement_store.dart';
import 'package:kaibao_sales/application/sales_store.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:kaibao_sales/ui/procurement_pages.dart';

class MemoryProcurementStore implements ProcurementStore, SalesStore {
  final supplierRows = <Supplier>[];
  final productRows = <Product>[
    const Product(id: 1, code: 'FB-01', specification: '棉布',
      unitPriceCents: 2500),
  ];
  final orders = <PurchaseOrder>[];

  @override
  Future<List<Supplier>> suppliers({bool includeInactive = true}) async =>
    supplierRows.where((s) => includeInactive || s.active).toList();

  @override
  Future<void> addSupplier(Supplier item) async {
    supplierRows.add(Supplier(id: supplierRows.length + 1, name: item.name,
      phone: item.phone, address: item.address, note: item.note,
      active: item.active));
  }

  @override
  Future<void> updateSupplier(Supplier item) async {
    final i = supplierRows.indexWhere((s) => s.id == item.id);
    supplierRows[i] = item;
  }

  @override
  Future<List<PurchaseOrder>> purchaseOrders() async => List.of(orders);

  @override
  Future<PurchaseOrder?> purchaseOrderById(int id) async {
    for (final order in orders) {
      if (order.id == id) return order;
    }
    return null;
  }

  @override
  Future<int> createPurchaseOrder({
    required int supplierId, required List<PurchaseLine> lines,
    String note = '',
  }) async {
    final supplier = supplierRows.firstWhere((s) => s.id == supplierId);
    final id = orders.length + 1;
    orders.add(PurchaseOrder(
      id: id, number: 'CG202611070001', date: '2026-11-07',
      supplierId: supplierId, supplierName: supplier.name,
      supplierPhone: supplier.phone, supplierAddress: supplier.address,
      status: 'ordered', note: note,
      totalCents: lines.fold<int>(0, (v, row) => v + row.amountCents),
      lines: lines,
    ));
    return id;
  }

  @override
  Future<void> cancelPurchaseOrder(int id) async {
    final index = orders.indexWhere((o) => o.id == id);
    final prior = orders[index];
    orders[index] = PurchaseOrder(
      id: prior.id, number: prior.number, date: prior.date,
      supplierId: prior.supplierId, supplierName: prior.supplierName,
      supplierPhone: prior.supplierPhone, supplierAddress: prior.supplierAddress,
      status: 'cancelled', note: prior.note, totalCents: prior.totalCents,
      lines: prior.lines,
    );
  }

  @override
  Future<List<Product>> products() async => List.of(productRows);

  @override
  Future<void> addProduct(Product item) async { productRows.add(item); }

  @override
  Future<List<Customer>> customers() async => [];

  @override
  Future<void> addCustomer(Customer item) async {}

  @override
  Future<List<Sale>> sales() async => [];

  @override
  Future<Sale?> saleById(int id) async => null;

  @override
  Future<int> customerOutstanding(int customerId) async => 0;

  @override
  Future<int> createSale({
    required Customer customer, required List<SaleLine> lines,
    required int discountCents, required int initialReceivedCents,
    String note = '',
  }) async => throw UnimplementedError();

  @override
  Future<void> addPayment(Sale sale, int amountCents,
    {String method = '其他'}) async => throw UnimplementedError();

  @override
  Future<void> saveDraft(String jsonPayload) async {}

  @override
  Future<String?> loadDraft() async => null;

  @override
  Future<void> deleteDraft() async {}
}

void main() {
  testWidgets('供应商表单输入→保存→修改停用→内存端口输出', (tester) async {
    tester.view.physicalSize = const Size(1200, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryProcurementStore();
    await tester.pumpWidget(MaterialApp(home: SuppliersPage(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新增供应商'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '供应商名称 *'),
      '采购商测试A');
    await tester.enterText(find.widgetWithText(TextFormField, '电话'), '13000001234');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(store.supplierRows.single.name, '采购商测试A');
    expect(store.supplierRows.single.phone, '13000001234');

    await tester.tap(find.text('采购商测试A'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(store.supplierRows.single.active, isFalse);
    expect(find.text('停用'), findsOneWidget);
  });

  testWidgets('采购单 UI 输入两行面积和价格，正确生成采购承诺，不动销售', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = MemoryProcurementStore();
    await store.addSupplier(const Supplier(name: '供货方A'));

    await tester.pumpWidget(MaterialApp(
      home: PurchaseEditorPage(store: store, catalog: store),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, '供应商 *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('供货方A').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, '产品型号 *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FB-01').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, '米数（米）*'), '37');
    await tester.enterText(find.widgetWithText(TextFormField, '采购单价（元/㎡）*'), '10');
    await tester.pumpAndSettle();
    expect(find.text('预计采购金额：¥1036.00'), findsOneWidget);

    await tester.ensureVisible(find.text('确认采购订单'));
    await tester.tap(find.text('确认采购订单'));
    await tester.pumpAndSettle();
    expect(store.orders, hasLength(1));
    expect(store.orders.single.totalCents, 103600);
    expect(store.orders.single.lines.single.code, 'FB-01');
    expect(await store.sales(), isEmpty);
  });
}
