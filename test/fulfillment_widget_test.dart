import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/fulfillment_store.dart';
import 'package:kaibao_sales/application/inventory_store.dart';
import 'package:kaibao_sales/domain/fulfillment.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/ui/fulfillment_pages.dart';

class _FakeFulfillment implements FulfillmentStore, InventoryStore {
  final locations = <Warehouse>[
    const Warehouse(id: 1, code: 'MAIN', name: '主仓', active: true),
  ];
  final dispatches = <DispatchRecord>[];
  final returns = <ReturnRecord>[];
  List<DispatchInputLine> lastDispatch = [];
  List<ReturnInputLine> lastReturn = [];

  @override
  Future<List<DispatchLineProgress>> dispatchableLines(int saleId) async => [
    DispatchLineProgress(lineId: 10, productId: 1, code: 'CURTAIN-01',
      orderedLengthMilli: 50000, dispatchedLengthMilli:
        dispatches.isEmpty ? 0 : 20000, widthMilli: 2800),
  ];

  @override
  Future<int> postSaleDispatch({required int saleId, required String requestKey,
    required List<DispatchInputLine> lines, String note = ''}) async {
    lastDispatch = lines;
    final id = dispatches.length + 1;
    dispatches.add(DispatchRecord(
      id: id, number: 'CK202611070001', saleId: saleId,
      saleNumber: 'XS202611070001', createdAt: '2026-11-07',
      note: note, totalAreaMicro: lines.first.lengthMilli * 2800));
    return id;
  }

  @override
  Future<List<DispatchRecord>> saleDispatches({int? saleId}) async =>
    List.of(dispatches);

  @override
  Future<List<ReturnLineProgress>> returnableLines(int dispatchId) async => [
    ReturnLineProgress(lineId: 20, productId: 1, code: 'CURTAIN-01',
      warehouseId: 1, warehouseCode: 'MAIN', batchCode: 'LOT-A',
      widthMilli: 2800, dispatchedLengthMilli: 20000,
      returnedLengthMilli: returns.isEmpty ? 0 : 5000),
  ];

  @override
  Future<int> postSaleReturn({required int dispatchId, required String requestKey,
    required List<ReturnInputLine> lines, String note = ''}) async {
    lastReturn = lines;
    final id = returns.length + 1;
    returns.add(ReturnRecord(id: id, number: 'TH202611070001',
      dispatchId: dispatchId, dispatchNumber: 'CK202611070001',
      createdAt: '2026-11-07', note: note,
      totalAreaMicro: lines.first.lengthMilli * 2800));
    return id;
  }

  @override
  Future<List<ReturnRecord>> saleReturns({int? dispatchId}) async =>
    List.of(returns);

  @override
  Future<List<Warehouse>> warehouses() async => List.of(locations);

  @override
  Future<int> addWarehouse({required String code, required String name}) async => 1;

  @override
  Future<List<ReceiptLineProgress>> receivableLines(int id) async => [];

  @override
  Future<int> postPurchaseReceipt({required int purchaseOrderId,
    required String requestKey, required List<ReceiptInputLine> lines,
    String note = ''}) async => throw UnimplementedError();

  @override
  Future<List<PurchaseReceiptRecord>> purchaseReceipts({int? purchaseOrderId}) async => [];

  @override
  Future<List<StockMovementRecord>> stockMovements() async => [];

  @override
  Future<List<StockBalance>> stockBalances() async => [];
}

void main() {
  testWidgets('销售出库 UI：输入 20 米/批次 → Application Port → 查看出库单', (tester) async {
    tester.view.physicalSize = const Size(1100, 1850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _FakeFulfillment();
    await tester.pumpWidget(MaterialApp(home: SaleFulfillmentPage(
      saleId: 3, fulfillment: store, inventory: store)));
    await tester.pumpAndSettle();
    expect(find.textContaining('待出 50 米'), findsOneWidget);
    await tester.tap(find.text('登记本单出库'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '本次实际出库米数'), '20');
    await tester.enterText(
      find.widgetWithText(TextFormField, '库存批次（需与已有库存一致）'), 'LOT-A');
    await tester.tap(find.text('确认销售出库'));
    await tester.pumpAndSettle();
    expect(store.dispatches, hasLength(1));
    expect(store.lastDispatch.single.lengthMilli, 20000);
    expect(store.lastDispatch.single.batchCode, 'LOT-A');
    expect(find.textContaining('CK202611070001'), findsOneWidget);
  });

  testWidgets('关联出库退货 UI：只填实物退货米数，不影响业务收款', (tester) async {
    tester.view.physicalSize = const Size(1100, 1850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _FakeFulfillment();
    await store.postSaleDispatch(saleId: 3, requestKey: 'fixture-dispatch-001',
      lines: const [DispatchInputLine(
        saleLineId: 10, warehouseId: 1, lengthMilli: 20000,
        batchCode: 'LOT-A')]);
    await tester.pumpWidget(MaterialApp(home: SaleFulfillmentPage(
      saleId: 3, fulfillment: store, inventory: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记关联实物退货'));
    await tester.pumpAndSettle();
    expect(find.textContaining('可退 20 米'), findsOneWidget);
    expect(find.textContaining('MAIN / LOT-A'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '本次实际退货米数'), '5');
    await tester.tap(find.text('确认实物退货入库'));
    await tester.pumpAndSettle();
    expect(store.returns, hasLength(1));
    expect(store.lastReturn.single.dispatchLineId, 20);
    expect(store.lastReturn.single.lengthMilli, 5000);
    expect(find.textContaining('TH202611070001'), findsOneWidget);
  });
}
