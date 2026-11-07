import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/inventory_store.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/ui/inventory_pages.dart';

class FakeInventoryStore implements InventoryStore {
  final places = <Warehouse>[];
  final progress = <ReceiptLineProgress>[
    const ReceiptLineProgress(lineId: 7, code: 'FB-01',
      orderedLengthMilli: 50000, receivedLengthMilli: 10000,
      widthMilli: 2800, productId: 1),
  ];
  final receipts = <PurchaseReceiptRecord>[];
  final movements = <StockMovementRecord>[];
  List<ReceiptInputLine> lastInput = [];

  @override
  Future<List<Warehouse>> warehouses() async => List.of(places);

  @override
  Future<int> addWarehouse({required String code, required String name}) async {
    places.add(Warehouse(id: places.length + 1, code: code.toUpperCase(),
      name: name, active: true));
    return places.last.id;
  }

  @override
  Future<List<ReceiptLineProgress>> receivableLines(int purchaseOrderId) async =>
    List.of(progress);

  @override
  Future<int> postPurchaseReceipt({required int purchaseOrderId,
    required String requestKey, required List<ReceiptInputLine> lines, String note = ''}) async {
    lastInput = lines;
    final id = receipts.length + 1;
    final area = lines.fold<int>(0, (n, line) => n + line.lengthMilli * 2800);
    receipts.add(PurchaseReceiptRecord(id: id, number: 'SH202611070001',
      purchaseOrderId: purchaseOrderId, orderNumber: 'CG202611070001',
      createdAt: '2026-11-07', note: note, totalAreaMicro: area));
    movements.add(StockMovementRecord(id: 1, receiptNumber: 'SH202611070001',
      productCode: 'FB-01', warehouseCode: 'MAIN', batchCode: lines.first.batchCode,
      deltaAreaMicro: area, createdAt: '2026-11-07'));
    return id;
  }

  @override
  Future<List<PurchaseReceiptRecord>> purchaseReceipts({int? purchaseOrderId}) async =>
    List.of(receipts);

  @override
  Future<List<StockMovementRecord>> stockMovements() async => List.of(movements);

  @override
  Future<List<StockBalance>> stockBalances() async =>
    movements.isEmpty ? [] : [StockBalance(
      productId: 1, productCode: 'FB-01',
      warehouseId: 1, warehouseCode: 'MAIN',
      batchCode: movements.first.batchCode,
      areaMicro: movements.first.deltaAreaMicro)];
}

void main() {
  testWidgets('库存模块：新建仓库并通过库存表读取', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = FakeInventoryStore();
    await tester.pumpWidget(MaterialApp(home: InventoryPage(store: store)));
    await tester.pumpAndSettle();
    expect(find.text('尚无实际收货入库流水'), findsOneWidget);

    await tester.tap(find.text('新增仓库'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '仓库编码 *'), 'MAIN');
    await tester.enterText(find.widgetWithText(TextFormField, '仓库名称 *'), '主仓');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(store.places.single.name, '主仓');
    expect(find.text('MAIN · 主仓'), findsOneWidget);
  });

  testWidgets('采购单部分收货输入→事务端口→库存流水输出', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = FakeInventoryStore();
    await store.addWarehouse(code: 'MAIN', name: '主仓');
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) => Scaffold(
        body: Center(child: FilledButton(
          onPressed: () => Navigator.push(ctx, MaterialPageRoute(
            builder: (_) => PurchaseReceivePage(
              store: store, purchaseOrderId: 3))),
          child: const Text('测试收货'))),
      )),
    ));
    await tester.tap(find.text('测试收货'));
    await tester.pumpAndSettle();
    expect(find.textContaining('剩余 40 米'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '本次实际收货米数'), '20');
    await tester.enterText(find.widgetWithText(TextFormField, '批次编码（可空）'),
      'LOT-2026');
    await tester.tap(find.text('确认收货并入库'));
    await tester.pumpAndSettle();
    expect(store.receipts, hasLength(1));
    expect(store.lastInput.single.lengthMilli, 20000);
    expect(store.lastInput.single.batchCode, 'LOT-2026');
    expect(store.movements.single.deltaAreaMicro, 56000000);
    expect(find.text('测试收货'), findsOneWidget);
  });
}
