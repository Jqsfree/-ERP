import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/main.dart';

void main() {
  testWidgets('数据库首次打开失败显示保留数据提示，重试后进入应用', (tester) async {
    var attempts = 0;
    Future<void> initialize() async {
      attempts++;
      if (attempts == 1) throw StateError('simulated storage unavailable');
    }

    await tester.pumpWidget(KaibaoStartup(
      initialize: initialize,
      ready: const MaterialApp(home: Scaffold(body: Text('已进入业务'))),
    ));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.text('本地数据库无法打开'), findsOneWidget);
    expect(find.textContaining('请勿卸载应用'), findsOneWidget);
    expect(find.text('已进入业务'), findsNothing);

    await tester.tap(find.text('重试打开数据库'));
    await tester.pumpAndSettle();
    debugPrint('STARTUP_RETRY_AFTER_SETTLE ready=${find.text('已进入业务').evaluate().length} loading=${find.text('正在检查本地数据库').evaluate().length} error=${find.text('本地数据库无法打开').evaluate().length}');
    // Flush the completion of an immediately returning Future in FakeAsync.
    await tester.pump();
    await tester.pumpAndSettle();
    debugPrint('STARTUP_RETRY_AFTER_PUMP ready=${find.text('已进入业务').evaluate().length} loading=${find.text('正在检查本地数据库').evaluate().length} error=${find.text('本地数据库无法打开').evaluate().length}');
    expect(attempts, 2);
    expect(find.text('已进入业务'), findsOneWidget);
    expect(find.text('本地数据库无法打开'), findsNothing);
  });
}
