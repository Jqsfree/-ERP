import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/fulfillment_store.dart';
import 'package:kaibao_sales/application/inventory_store.dart';
import 'package:kaibao_sales/domain/fulfillment.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/ui/fulfillment_pages.dart';

class StockFake extends Fake implements FulfillmentStore, InventoryStore {
  int posts = 0;
  @override Future<List<Warehouse>> warehouses() async => [const Warehouse(id: 1, code: 'W', name: '仓库', active: true)];
  @override Future<List<DispatchLineProgress>> dispatchableLines(int id) async => [const DispatchLineProgress(lineId: 1, productId: 1, code: 'X', orderedLengthMilli: 10000, dispatchedLengthMilli: 4000, widthMilli: 1000)];
  @override Future<List<ReturnLineProgress>> returnableLines(int id) async => [const ReturnLineProgress(lineId: 1, productId: 1, code: 'X', warehouseId: 1, warehouseCode: 'W', batchCode: '', widthMilli: 1000, dispatchedLengthMilli: 4000, returnedLengthMilli: 1000)];
  @override Future<int> postSaleDispatch({required int saleId, required String requestKey, required List<DispatchInputLine> lines, String note = ''}) async { posts++; return 1; }
  @override Future<int> postSaleReturn({required int dispatchId, required String requestKey, required List<ReturnInputLine> lines, String note = ''}) async { posts++; return 1; }
}
void main() {
  for (final returning in [false, true]) {
    testWidgets('${returning ? '退货' : '出库'}：超量拦截、确认取消不提交、确认仅提交一次', (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = StockFake();
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => Scaffold(body: TextButton(onPressed: () => Navigator.push(ctx,
        MaterialPageRoute(builder: (_) => returning ? SaleReturnEditorPage(dispatchId: 1, fulfillment: store) : DispatchEditorPage(saleId: 1, fulfillment: store, inventory: store))), child: const Text('打开'))))));
      await tester.tap(find.text('打开')); await tester.pumpAndSettle();
      final field = find.widgetWithText(TextFormField, returning ? '本次实际退货米数' : '本次实际出库米数');
      final button = find.text(returning ? '确认实物退货入库' : '确认销售出库');
      await tester.enterText(field, '20'); await tester.tap(button); await tester.pumpAndSettle();
      expect(store.posts, 0);
      expect(find.textContaining(returning ? '退货米数超过可退量' : '不能超过剩余可出库米数'), findsOneWidget);
      await tester.enterText(field, '2'); await tester.tap(button); await tester.pumpAndSettle();
      expect(find.text('确认登记'), findsOneWidget);
      await tester.tap(find.text('返回修改')); await tester.pumpAndSettle();
      expect(store.posts, 0);
      await tester.tap(button); await tester.pumpAndSettle();
      await tester.tap(find.text('确认登记')); await tester.pumpAndSettle();
      expect(store.posts, 1);
      expect(find.text('打开'), findsOneWidget);
    });
  }
}
