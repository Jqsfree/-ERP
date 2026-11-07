import 'dart:math';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:flutter/material.dart';

import '../application/finance_store.dart';
import '../domain/finance.dart';
import '../domain/money.dart';
import '../services/finance_csv.dart';

String _cashText(int cents) => '¥${Fixed.format(cents, decimals: 2)}';

String _key(String prefix) =>
  '$prefix-${DateTime.now().microsecondsSinceEpoch}-'
  '${Random.secure().nextInt(1 << 32)}';

int _signedCents(String input) {
  final s = input.trim();
  if (s.isEmpty) throw const FormatException('必须填写实际净变动');
  final negative = s.startsWith('-');
  final value = Fixed.parse(negative ? s.substring(1) : s, decimals: 2);
  return negative ? -value : value;
}

/// Other financial movements only. Sale receipts are displayed in the daily
/// statement but must be recorded through their original sale, not here.
class CashbookPage extends StatefulWidget {
  const CashbookPage({super.key, required this.store});
  final FinanceStore store;

  @override
  State<CashbookPage> createState() => _CashbookPageState();
}

class _CashbookPageState extends State<CashbookPage> {
  late Future<({List<CashEntry> entries, DayStatement statement})> _data = _load();

  Future<({List<CashEntry> entries, DayStatement statement})> _load() async {
    final today = FinanceMath.day(DateTime.now());
    return (entries: await widget.store.cashEntries(),
      statement: await widget.store.dayStatement(today));
  }

  void _refresh() {
    final next = _load();
    setState(() { _data = next; });
  }

  Future<void> _newEntry() async {
    var kind = 'expense';
    var method = '现金';
    var category = '';
    var amount = '';
    var note = '';
    var saving = false;
    final form = GlobalKey<FormState>();
    final request = _key('cash');
    final ok = await showDialog<bool>(context: context, builder: (ctx) =>
      StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: const Text('登记其他收入 / 费用支出'),
        content: SingleChildScrollView(child: Form(key: form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('销售客户收款请在原销售单登记；这里不能重复登记货款。'),
            DropdownButtonFormField<String>(
              initialValue: kind,
              decoration: const InputDecoration(labelText: '收支类型'),
              items: const [
                DropdownMenuItem(value: 'expense', child: Text('费用支出')),
                DropdownMenuItem(value: 'income', child: Text('其他收入')),
              ],
              onChanged: saving ? null : (v) { if (v != null) kind = v; }),
            DropdownButtonFormField<String>(
              initialValue: method,
              decoration: const InputDecoration(labelText: '资金渠道'),
              items: FinanceMath.methods.map((m) =>
                DropdownMenuItem(value: m, child: Text(m))).toList(),
              onChanged: saving ? null : (v) { if (v != null) method = v; }),
            TextFormField(
              decoration: const InputDecoration(labelText: '分类 *（如运费/房租/利息）'),
              onChanged: (v) => category = v,
              validator: (v) => (v == null || v.trim().isEmpty)
                ? '请填写实际收支分类' : null),
            TextFormField(
              decoration: const InputDecoration(labelText: '金额（元）*'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (v) => amount = v,
              validator: (v) {
                try {
                  if (v == null || Fixed.parse(v, decimals: 2) <= 0) {
                    return '请输入大于 0 的金额';
                  }
                } catch (_) { return '金额最多两位小数'; }
                return null;
              },
            ),
            TextFormField(
              decoration: const InputDecoration(labelText: '凭证说明 / 备注'),
              onChanged: (v) => note = v,
            ),
          ]))),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(ctx, false),
            child: const Text('取消')),
          FilledButton(
            onPressed: saving ? null : () async {
              if (!form.currentState!.validate()) return;
              setDialog(() => saving = true);
              try {
                await widget.store.recordCashEntry(
                  kind: kind, method: method, category: category,
                  amountCents: Fixed.parse(amount, decimals: 2),
                  note: note, requestKey: request);
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('收支未入账：$e')));
                }
              } finally {
                if (ctx.mounted) setDialog(() => saving = false);
              }
            },
            child: const Text('确认记账')),
        ],
      )),
    );
    if (ok == true && mounted) _refresh();
  }

  Future<void> _reverse(CashEntry original) async {
    if (original.kind == 'reversal') return;
    var reason = '';
    var saving = false;
    final form = GlobalKey<FormState>();
    final request = _key('cash-reverse');
    final ok = await showDialog<bool>(context: context, builder: (ctx) =>
      StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: Text('冲销 ${original.number}'),
        content: Form(key: form, child: Column(mainAxisSize: MainAxisSize.min,
          children: [
            Text('不会删除原凭证；会在当前未关账日期增加一条反向资金事件。'
              '原收支：${_cashText(original.signedCents)}'),
            TextFormField(
              decoration: const InputDecoration(labelText: '冲销原因 *'),
              onChanged: (v) => reason = v,
              validator: (v) => v == null || v.trim().isEmpty ? '必须说明原因' : null),
          ])),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(ctx, false),
            child: const Text('返回')),
          FilledButton(onPressed: saving ? null : () async {
            if (!form.currentState!.validate()) return;
            setDialog(() => saving = true);
            try {
              await widget.store.reverseCashEntry(
                originalEntryId: original.id, requestKey: request, reason: reason);
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('冲销未完成：$e')));
              }
            } finally {
              if (ctx.mounted) setDialog(() => saving = false);
            }
          }, child: const Text('确认生成冲销凭证')),
        ],
      )),
    );
    if (ok == true && mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('其他资金收支'),
      actions: [
        IconButton(tooltip: '日结对账', icon: const Icon(Icons.fact_check_outlined),
          onPressed: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => DayClosePage(store: widget.store)))),
        IconButton(tooltip: '刷新收支', icon: const Icon(Icons.refresh), onPressed: _refresh),
      ]),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _newEntry, icon: const Icon(Icons.add), label: const Text('新增收支')),
    body: FutureBuilder<({List<CashEntry> entries, DayStatement statement})>(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('读取收支失败：${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final data = snap.data!;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text('当日现金流（${data.statement.day}）',
            style: Theme.of(context).textTheme.titleMedium),
          ListTile(title: const Text('销售收款（只读取原销售单）'),
            trailing: Text(_cashText(data.statement.salesReceiptsCents))),
          ListTile(title: const Text('其他收入'),
            trailing: Text(_cashText(data.statement.otherIncomeCents))),
          ListTile(title: const Text('费用支出'),
            trailing: Text(_cashText(-data.statement.otherExpenseCents))),
          ListTile(title: const Text('冲销净额'),
            trailing: Text(_cashText(data.statement.reversalNetCents))),
          ListTile(title: const Text('今日资金净变动'),
            trailing: Text(_cashText(data.statement.expectedNetCents))),
          const Divider(),
          const Text('下列记录不包括销售原单收款；本模块不是利润表，'
            '不能代替应收应付总账。', style: TextStyle(color: Colors.grey)),
          Text('其他收入与费用流水（${data.entries.length}）',
            style: Theme.of(context).textTheme.titleMedium),
          if (data.entries.isEmpty) const ListTile(title: Text('尚未记录其他资金流水')),
          for (final e in data.entries)
            Card(child: ListTile(
              title: Text('${e.number} · ${e.category}'),
              subtitle: Text('${e.businessDate} · ${e.method} · '
                '${e.kind == 'reversal' ? '冲销' : (e.kind == 'income' ? '其他收入' : '费用支出')}'
                '${e.note.isEmpty ? '' : ' · ${e.note}'}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_cashText(e.signedCents)),
                if (e.kind != 'reversal')
                  IconButton(tooltip: '冲销 ${e.number}',
                    onPressed: () => _reverse(e),
                    icon: const Icon(Icons.undo)),
              ]),
            )),
          const SizedBox(height: 100),
        ]);
      },
    ),
  );
}

/// Close compares daily net movements, not account balances. Real cash/bank
/// statements are manually supplied and a mismatch requires an explanation.
class DayClosePage extends StatefulWidget {
  const DayClosePage({super.key, required this.store, this.initialDay});
  final FinanceStore store;
  final String? initialDay;
  @override
  State<DayClosePage> createState() => _DayClosePageState();
}

class _DayClosePageState extends State<DayClosePage> {
  late String _day;
  late Future<({DayStatement statement, DayClose? close})> _data;

  @override
  void initState() {
    super.initState();
    _day = widget.initialDay ?? FinanceMath.day(DateTime.now());
    _data = _load();
  }
  final _actual = <String, String>{};
  String _reason = '';
  bool _saving = false;
  String _request = _key('day-close');

  Future<({DayStatement statement, DayClose? close})> _load() async =>
    (statement: await widget.store.dayStatement(_day),
      close: await widget.store.dayClose(_day));

  void _refresh() {
    final next = _load();
    setState(() { _data = next; });
  }

  Future<void> _export(DayStatement report, DayClose close) async {
    try {
      final csv = FinanceCsvExporter.generate(report, close);
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'kaibao_day_close_${close.day}.csv'));
      await file.writeAsString(csv, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)], text: '凯堡软装日结对账 ${close.day}',
        subject: '凯堡软装日结对账 ${close.day}'));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('日结报告导出未完成：$e')));
      }
    }
  }

  Future<void> _pickDay() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_day),
      firstDate: DateTime(1970),
      lastDate: DateTime.now(),
    );
    if (selected == null || !mounted) return;
    _day = FinanceMath.day(selected);
    _actual.clear();
    _reason = '';
    _request = _key('day-close');
    _refresh();
  }

  Future<void> _close(DayStatement statement) async {
    if (_saving) return;
    try {
      final actual = <String, int>{};
      for (final method in statement.expectedNetByMethod.keys) {
        actual[method] = _signedCents(_actual[method] ?? '');
      }
      final differences = statement.expectedNetByMethod.keys.where(
        (m) => statement.expectedNetByMethod[m] != actual[m]).toList();
      if (differences.isNotEmpty && _reason.trim().isEmpty) {
        throw ArgumentError('存在差异的渠道：${differences.join('、')}，必须填写差异原因');
      }
      final confirmed = await showDialog<bool>(context: context,
        builder: (ctx) => AlertDialog(
          title: Text('确认关账 $_day？'),
          content: Text('本日账面净变动 ${_cashText(statement.expectedNetCents)}。'
            '提交后当天不能补记其他收支或销售收款。'
            '实际渠道变动应来自真实付款渠道日账单，不是当前账户余额。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('返回核对')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认日结')),
          ]));
      if (confirmed != true || !mounted) return;
      setState(() => _saving = true);
      await widget.store.closeDay(day: _day, requestKey: _request,
        actualNetByMethod: actual, varianceReason: _reason);
      if (mounted) _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('日结未完成：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('日结对账'),
      actions: [
        IconButton(tooltip: '日结历史', icon: const Icon(Icons.history),
          onPressed: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => DayCloseHistoryPage(store: widget.store)))),
        IconButton(tooltip: '选择日结日期', onPressed: _pickDay,
          icon: const Icon(Icons.event)),
        IconButton(tooltip: '刷新日结', onPressed: _refresh,
          icon: const Icon(Icons.refresh)),
      ]),
    body: FutureBuilder<({DayStatement statement, DayClose? close})>(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('无法读取日结：${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final result = snap.data!;
        final summary = result.statement;
        final close = result.close;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text('业务日期：$_day',
            style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(close == null ? '未日结' : '已关账 · ${close.createdAt}',
            style: TextStyle(color: close == null ? Colors.orange : Colors.green)),
          const SizedBox(height: 12),
          ListTile(title: const Text('销售原单收款'),
            trailing: Text(_cashText(summary.salesReceiptsCents))),
          ListTile(title: const Text('其他收入'),
            trailing: Text(_cashText(summary.otherIncomeCents))),
          ListTile(title: const Text('费用支出'),
            trailing: Text(_cashText(-summary.otherExpenseCents))),
          ListTile(title: const Text('冲销净额'),
            trailing: Text(_cashText(summary.reversalNetCents))),
          ListTile(title: const Text('合计账面资金净变动'),
            trailing: Text(_cashText(summary.expectedNetCents))),
          const Divider(),
          const Text('逐渠道填写外部支付平台、银行或现金记录的【本日净变动】'
            '（可为负数），不是账号当前余额；缺失的渠道填 0。'
            '没有实际外部数据时不要按账面值直接日结。'),
          const SizedBox(height: 12),
          for (final row in summary.expectedNetByMethod.entries)
            Padding(padding: const EdgeInsets.only(bottom: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${row.key} · 账面 ${_cashText(row.value)}'),
                if (close == null)
                  TextFormField(
                    key: ValueKey('$_day-${row.key}'),
                    decoration: const InputDecoration(
                      labelText: '外部核对本日净变动（元）*'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                    initialValue: _actual[row.key] ?? '',
                    onChanged: (value) => _actual[row.key] = value,
                  )
                else
                  Text('外部：${_cashText(close.actualNetByMethod[row.key] ?? 0)}；'
                    '差异：${_cashText(close.differenceByMethod[row.key] ?? 0)}'),
              ])),
          if (close == null) ...[
            TextFormField(
              key: ValueKey('reason-$_day'),
              decoration: const InputDecoration(
                labelText: '差异原因（有差异必须填写）'),
              initialValue: _reason, onChanged: (v) => _reason = v,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : () => _close(summary),
              icon: const Icon(Icons.fact_check),
              label: Text(_saving ? '提交中…' : '确认关账并冻结当日资金流水')),
          ] else ...[
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _export(summary, close),
              icon: const Icon(Icons.table_view),
              label: const Text('分享日结对账 CSV')),
            ListTile(title: const Text('日结差异说明'),
              subtitle: Text(close.varianceReason.isEmpty ?
                '账实一致，无需差异原因' : close.varianceReason)),
            const Text('关账报告只读。如发现漏记，须按当前开放日期以独立调整凭证处理，'
              '不得修改已结日期的原记录。'),
          ],
          const SizedBox(height: 80),
        ]);
      },
    ),
  );
}


/// Read-only historical closure listing. Opening an item checks live sources
/// against the stored closure, rather than blindly trusting the snapshot.
class DayCloseHistoryPage extends StatelessWidget {
  const DayCloseHistoryPage({super.key, required this.store});
  final FinanceStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('日结历史')),
    body: FutureBuilder<List<DayClose>>(
      future: store.closedDays(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('读取日结历史失败：${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final days = snap.data!;
        if (days.isEmpty) return const Center(child: Text('还没有已保存的日结对账记录'));
        return ListView.builder(itemCount: days.length,
          itemBuilder: (context, index) {
            final record = days[index];
            return ListTile(
              title: Text(record.day),
              subtitle: Text(record.hasDifference
                ? '账实有差异 · ${record.varianceReason}' : '账实一致'),
              trailing: Text(record.hasDifference
                ? _cashText(record.totalDifferenceCents) : '一致'),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => DayClosePage(
                  store: store, initialDay: record.day))),
            );
          },
        );
      },
    ),
  );
}
