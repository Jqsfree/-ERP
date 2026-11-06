import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/main.dart';

void main() {
  testWidgets('首页展示八项业务入口，销售和客户可点击', (tester) async {
    await tester.pumpWidget(const KaibaoApp());
    expect(find.text('凯堡软装 · 开单管理'), findsOneWidget);
    expect(find.text('销售'), findsOneWidget);
    expect(find.text('采购'), findsOneWidget);
    expect(find.text('客户'), findsOneWidget);
    expect(find.text('供应商'), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
  });
}
