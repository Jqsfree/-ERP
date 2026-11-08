import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/ui/credit_transfer_dialog.dart';

void main() {
  testWidgets('字段错误可修正；部分金额、等待禁重入、响应丢失原请求重试', (tester) async {
    final pending = Completer<void>();
    final calls = <(int, String)>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) =>
      TextButton(onPressed: () => showDialog<bool>(context: context,
        builder: (_) => CreditTransferDialog(customerName: '客户', maximumCents: 10000,
          post: (amount, key) async {
            calls.add((amount, key));
            if (calls.length == 1) await pending.future;
          })), child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final input = find.byType(TextFormField);
    await tester.enterText(input, '100.01');
    await tester.tap(find.text('确认转入余额'));
    await tester.pumpAndSettle();
    expect(find.text('金额须大于0且不超过可处理金额'), findsOneWidget);
    expect(calls, isEmpty);
    await tester.enterText(input, '30.00');
    await tester.pumpAndSettle();
    expect(find.text('金额须大于0且不超过可处理金额'), findsNothing);
    await tester.tap(find.text('确认转入余额'));
    await tester.pump();
    await tester.tap(find.text('正在转入…'));
    await tester.pump();
    expect(calls.length, 1);
    expect(calls.single.$1, 3000);
    pending.completeError(Exception('response lost'));
    await tester.pumpAndSettle();
    expect(find.text('30.00'), findsOneWidget);
    expect(tester.widget<EditableText>(find.byType(EditableText)).readOnly, isTrue);
    await tester.tap(find.text('原请求重试'));
    await tester.pumpAndSettle();
    expect(calls.length, 2);
    expect(calls[1], calls[0]);
    expect(find.byType(CreditTransferDialog), findsNothing);
  });

  for (final viewport in [const Size(320, 500), const Size(360, 500),
    const Size(411, 500), const Size(600, 320)]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('转余额弹窗尺寸$viewport 字体$scale 键盘可达', (tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final names = List.filled(8, '长客户名称').join();
        await tester.pumpWidget(MaterialApp(builder: (_, child) => MediaQuery(
          data: MediaQueryData(size: viewport, textScaler: TextScaler.linear(scale),
            viewInsets: const EdgeInsets.only(bottom: 160)), child: child!),
          home: Scaffold(body: Builder(builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(context: context, builder: (_) =>
              CreditTransferDialog(customerName: names, maximumCents: 999999999,
                post: (_, _) async {})), child: const Text('打开'))))));
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(TextFormField));
        await tester.enterText(find.byType(TextFormField), '1.00');
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('确认转入余额'));
        await tester.tap(find.text('确认转入余额'));
        await tester.pumpAndSettle();
        expect(find.byType(CreditTransferDialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
