import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/finance_store.dart';
import 'package:kaibao_sales/domain/finance.dart';
import 'package:kaibao_sales/ui/finance_pages.dart';

class _FakeFinance implements FinanceStore {
  final entries = <CashEntry>[];
  DayClose? closed;
  String? lastKind;
  String? lastCategory;
  int? lastAmount;

  String get today => FinanceMath.day(DateTime.now());

  @override
  Future<int> recordCashEntry({
    required String kind, required String method, required String category,
    required int amountCents, required String requestKey, String note = '',
  }) async {
    lastKind = kind;
    lastCategory = category;
    lastAmount = amountCents;
    final id = entries.length + 1;
    entries.add(CashEntry(id: id, number: 'FZ202611070001',
      businessDate: today, kind: kind, method: method, category: category,
      amountCents: amountCents, direction: kind == 'income' ? 1 : -1,
      note: note, createdAt: DateTime.now().toIso8601String()));
    return id;
  }

  @override
  Future<int> reverseCashEntry({
    required int originalEntryId, required String requestKey,
    required String reason,
  }) async {
    final original = entries.firstWhere((e) => e.id == originalEntryId);
    final id = entries.length + 1;
    entries.add(CashEntry(id: id, number: 'CX202611070001',
      businessDate: today, kind: 'reversal', method: original.method,
      category: original.category, amountCents: original.amountCents,
      direction: -original.direction, originalEntryId: original.id,
      note: reason, createdAt: DateTime.now().toIso8601String()));
    return id;
  }

  @override
  Future<List<CashEntry>> cashEntries({String? day}) async =>
    List.of(entries.reversed.where((e) => day == null || e.businessDate == day));

  @override
  Future<DayStatement> dayStatement(String day) async {
    final rows = entries.map((e) => <String, Object?>{
      'kind': e.kind, 'method': e.method,
      'business_date': e.businessDate, 'amount_cents': e.amountCents,
      'direction': e.direction,
    }).toList();
    return FinanceMath.statement(day, [
      {'method': '微信', 'amount_cents': 5000, 'created_at': '${today}T10:00:00'},
    ], rows);
  }

  @override
  Future<int> closeDay({
    required String day, required String requestKey,
    required Map<String, int> actualNetByMethod,
    String varianceReason = '',
  }) async {
    final statement = await dayStatement(day);
    closed = DayClose(id: 1, day: day,
      expectedNetByMethod: statement.expectedNetByMethod,
      actualNetByMethod: actualNetByMethod,
      varianceReason: varianceReason, createdAt: DateTime.now().toIso8601String());
    return 1;
  }

  @override
  Future<DayClose?> dayClose(String day) async =>
    closed?.day == day ? closed : null;

  @override
  Future<List<DayClose>> closedDays() async =>
    closed == null ? [] : [closed!];
}

void main() {
  testWidgets('费用收支：输入分类及金额→应用端口→完整本地流水', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = _FakeFinance();
    await tester.pumpWidget(MaterialApp(home: CashbookPage(store: fake)));
    await tester.pumpAndSettle();
    expect(find.textContaining('销售收款（只读取原销售单）'), findsOneWidget);

    await tester.tap(find.text('新增收支'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField,
      '分类 *（如运费/房租/利息）'), '运输费');
    await tester.enterText(find.widgetWithText(TextFormField, '金额（元）*'), '12.50');
    await tester.tap(find.text('确认记账'));
    await tester.pumpAndSettle();
    expect(fake.lastKind, 'expense');
    expect(fake.lastCategory, '运输费');
    expect(fake.lastAmount, 1250);
    expect(find.textContaining('FZ202611070001'), findsOneWidget);
    expect(find.text('¥-12.50'), findsWidgets);
  });

  testWidgets('费用收支：原事件不能删除，冲销生成第二条流水', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = _FakeFinance();
    await fake.recordCashEntry(kind: 'expense', method: '现金',
      category: '运输费', amountCents: 500, requestKey: 'test-entry-undo-001');
    await tester.pumpWidget(MaterialApp(home: CashbookPage(store: fake)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('冲销 FZ202611070001'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '冲销原因 *'), '重复记账');
    await tester.tap(find.text('确认生成冲销凭证'));
    await tester.pumpAndSettle();
    expect(fake.entries, hasLength(2));
    expect(fake.entries.last.originalEntryId, fake.entries.first.id);
    expect(find.textContaining('CX202611070001'), findsOneWidget);
  });

  testWidgets('日结：必须输入全部渠道外部净变动后保存快照', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = _FakeFinance();
    await tester.pumpWidget(MaterialApp(home: DayClosePage(store: fake)));
    await tester.pumpAndSettle();
    final today = fake.today;
    for (final method in FinanceMath.methods) {
      await tester.enterText(find.byKey(ValueKey('$today-$method')),
        method == '微信' ? '50.00' : '0');
    }
    final submit = find.text('确认关账并冻结当日资金流水');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('确认关账 ${fake.today}？'), findsOneWidget);
    await tester.tap(find.text('确认日结'));
    await tester.pumpAndSettle();
    expect(fake.closed, isNotNull);
    expect(fake.closed!.expectedNetByMethod['微信'], 5000);
    expect(fake.closed!.hasDifference, isFalse);
    expect(find.textContaining('已关账'), findsOneWidget);
  });
}
