import 'dart:math';

import 'package:flutter/material.dart';

import '../application/fulfillment_store.dart';
import '../application/inventory_store.dart';
import '../domain/fulfillment.dart';
import '../domain/inventory.dart';
import '../domain/money.dart';

String _meters(int milli) => Fixed.format(milli, decimals: 3, trim: true);
String _area(int micro) => Fixed.format(micro, decimals: 6, trim: true);
String _requestKey(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}'
  '-${Random.secure().nextInt(1 << 32)}';

/// From a saved sale, review dispatch status, post partial deliveries, and
/// return only physical stock already shipped on the selected dispatch.
class SaleFulfillmentPage extends StatefulWidget {
  const SaleFulfillmentPage({super.key, required this.saleId,
    required this.fulfillment, required this.inventory});
  final int saleId;
  final FulfillmentStore fulfillment;
  final InventoryStore inventory;

  @override
  State<SaleFulfillmentPage> createState() => _SaleFulfillmentPageState();
}

class _SaleFulfillmentPageState extends State<SaleFulfillmentPage> {
  late Future<(List<DispatchLineProgress>, List<DispatchRecord>,
    Map<int, List<ReturnRecord>>)> _data = _load();

  Future<(List<DispatchLineProgress>, List<DispatchRecord>,
    Map<int, List<ReturnRecord>>)> _load() async {
    final progress = await widget.fulfillment.dispatchableLines(widget.saleId);
    final dispatches = await widget.fulfillment.saleDispatches(saleId: widget.saleId);
    final returns = <int, List<ReturnRecord>>{};
    for (final dispatch in dispatches) {
      returns[dispatch.id] = await widget.fulfillment.saleReturns(dispatchId: dispatch.id);
    }
    return (progress, dispatches, returns);
  }

  void _reload() {
    final next = _load();
    setState(() { _data = next; });
  }

  Future<void> _dispatch() async {
    final id = await Navigator.push<int>(context, MaterialPageRoute(
      builder: (_) => DispatchEditorPage(
        saleId: widget.saleId, fulfillment: widget.fulfillment,
        inventory: widget.inventory)));
    if (id != null && mounted) _reload();
  }

  Future<void> _return(int dispatchId) async {
    final id = await Navigator.push<int>(context, MaterialPageRoute(
      builder: (_) => SaleReturnEditorPage(
        dispatchId: dispatchId, fulfillment: widget.fulfillment)));
    if (id != null && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('销售履约与实物退货'),
      actions: [IconButton(tooltip: '刷新履约', icon: const Icon(Icons.refresh),
        onPressed: _reload)]),
    body: FutureBuilder<(List<DispatchLineProgress>, List<DispatchRecord>,
      Map<int, List<ReturnRecord>>)>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('读取履约记录失败：${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final (progress, dispatches, returns) = snapshot.data!;
        final hasRemaining = progress.any((p) => p.remainingLengthMilli > 0);
        return ListView(padding: const EdgeInsets.all(16), children: [
          const Text('销售单不等于出库；只有确认出库才扣除实际库存。'
            '实物退货回到原出库仓库和批次，不修改原销售金额或已收款。',
            style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          Text('销售行履约进度', style: Theme.of(context).textTheme.titleMedium),
          for (final line in progress)
            ListTile(
              title: Text('${line.code} · 销售行 #${line.lineId}'),
              subtitle: Text('已出 ${_meters(line.dispatchedLengthMilli)} / '
                '${_meters(line.orderedLengthMilli)} 米，'
                '待出 ${_meters(line.remainingLengthMilli)} 米')),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: hasRemaining ? _dispatch : null,
            icon: const Icon(Icons.local_shipping_outlined),
            label: Text(hasRemaining ? '登记本单出库' : '此销售单已经全部出库')),
          const Divider(height: 32),
          Text('出库单和关联退货', style: Theme.of(context).textTheme.titleMedium),
          if (dispatches.isEmpty) const ListTile(title: Text('尚无实际出库单')),
          for (final dispatch in dispatches) ...[
            Card(child: Padding(padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${dispatch.number} · ${_area(dispatch.totalAreaMicro)} ㎡',
                  style: Theme.of(context).textTheme.titleMedium),
                Text('出库日期：${dispatch.createdAt}'),
                for (final ret in returns[dispatch.id] ?? [])
                  ListTile(
                    title: Text('${ret.number} · 已实物退回 ${_area(ret.totalAreaMicro)} ㎡'),
                    subtitle: Text(ret.createdAt)),
                OutlinedButton.icon(
                  onPressed: () => _return(dispatch.id),
                  icon: const Icon(Icons.assignment_return),
                  label: const Text('登记关联实物退货')),
              ]),
            )),
          ],
          const SizedBox(height: 32),
        ]);
      },
    ),
  );
}

class DispatchEditorPage extends StatefulWidget {
  const DispatchEditorPage({super.key, required this.saleId,
    required this.fulfillment, required this.inventory});
  final int saleId;
  final FulfillmentStore fulfillment;
  final InventoryStore inventory;
  @override
  State<DispatchEditorPage> createState() => _DispatchEditorPageState();
}

class _DispatchEditorPageState extends State<DispatchEditorPage> {
  late final Future<(List<Warehouse>, List<DispatchLineProgress>)> _data = _load();
  final _lengths = <int, TextEditingController>{};
  final _batches = <int, TextEditingController>{};
  final _selectedWarehouse = <int, int?>{};
  final _note = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _request = _requestKey('dispatch');
  bool _saving = false;

  Future<(List<Warehouse>, List<DispatchLineProgress>)> _load() async {
    final warehouses = (await widget.inventory.warehouses()).where((w) => w.active).toList();
    final progress = await widget.fulfillment.dispatchableLines(widget.saleId);
    for (final p in progress) {
      _lengths[p.lineId] = TextEditingController();
      _batches[p.lineId] = TextEditingController();
      _selectedWarehouse[p.lineId] = warehouses.isEmpty ? null : warehouses.first.id;
    }
    return (warehouses, progress);
  }

  @override
  void dispose() {
    for (final t in _lengths.values) { t.dispose(); }
    for (final t in _batches.values) { t.dispose(); }
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit(List<DispatchLineProgress> progress) async {
    if (_saving || !_form.currentState!.validate()) return;
    final lines = <DispatchInputLine>[];
    try {
      for (final p in progress) {
        if (p.remainingLengthMilli == 0) continue;
        final input = _lengths[p.lineId]!.text.trim();
        if (input.isEmpty || input == '0') continue;
        final length = Fixed.parse(input, decimals: 3);
        if (length <= 0 || length > p.remainingLengthMilli) {
          throw ArgumentError('${p.code} 出库数量超过剩余可出货量');
        }
        final warehouse = _selectedWarehouse[p.lineId];
        if (warehouse == null) throw ArgumentError('请选择出货仓库');
        lines.add(DispatchInputLine(
          saleLineId: p.lineId, warehouseId: warehouse,
          lengthMilli: length, batchCode: _batches[p.lineId]!.text.trim()));
      }
      if (lines.isEmpty) throw ArgumentError('至少输入一条实际出库米数');
      setState(() => _saving = true);
      final id = await widget.fulfillment.postSaleDispatch(
        saleId: widget.saleId, requestKey: _request,
        lines: lines, note: _note.text);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('出库未完成：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('销售出库')),
    body: FutureBuilder<(List<Warehouse>, List<DispatchLineProgress>)>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('无法读取出库明细：${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final (warehouses, progress) = snapshot.data!;
        if (warehouses.isEmpty) {
          return const Center(child: Text('先到库存管理新增有效仓库，才能执行销售出库'));
        }
        if (progress.every((p) => p.remainingLengthMilli == 0)) {
          return const Center(child: Text('销售单全部出库，没有可用明细'));
        }
        return Form(key: _form, child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('逐销售行指定实际出货米数、仓库和批次；出库将在数据库事务内验证库存并扣减。'),
          const SizedBox(height: 8),
          for (final p in progress) if (p.remainingLengthMilli > 0)
            Card(child: Padding(padding: const EdgeInsets.all(12), child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p.code} · 行 #${p.lineId}',
                  style: Theme.of(context).textTheme.titleMedium),
                Text('未出 ${_meters(p.remainingLengthMilli)} 米，门幅 ${_meters(p.widthMilli)} 米'),
                if (p.productId == 0)
                  const Text('此销售行未绑定库存产品，禁止直接出库',
                    style: TextStyle(color: Colors.red)),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _lengths[p.lineId],
                  decoration: const InputDecoration(labelText: '本次实际出库米数'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty || v.trim() == '0') return null;
                    try {
                      final n = Fixed.parse(v, decimals: 3);
                      return n > 0 && n <= p.remainingLengthMilli && p.productId != 0
                        ? null : '无库存产品关联，或出库米数非法';
                    } catch (_) { return '米数最多三位小数'; }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _selectedWarehouse[p.lineId],
                  decoration: const InputDecoration(labelText: '出库仓库'),
                  items: warehouses.map((w) => DropdownMenuItem(
                    value: w.id, child: Text('${w.code} · ${w.name}'))).toList(),
                  onChanged: (v) => _selectedWarehouse[p.lineId] = v),
                const SizedBox(height: 12),
                TextFormField(controller: _batches[p.lineId],
                  decoration: const InputDecoration(labelText: '库存批次（需与已有库存一致）')),
              ]),
            )),
          TextFormField(controller: _note,
            decoration: const InputDecoration(labelText: '出库备注')),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : () => _submit(progress),
            icon: const Icon(Icons.local_shipping),
            label: Text(_saving ? '提交中…' : '确认销售出库')),
          const SizedBox(height: 12),
          const Text('出库只调整物理库存，不重复登记销售金额或收款。',
            style: TextStyle(color: Colors.grey)),
        ]));
      },
    ),
  );
}

class SaleReturnEditorPage extends StatefulWidget {
  const SaleReturnEditorPage({super.key, required this.dispatchId,
    required this.fulfillment});
  final int dispatchId;
  final FulfillmentStore fulfillment;
  @override
  State<SaleReturnEditorPage> createState() => _SaleReturnEditorPageState();
}

class _SaleReturnEditorPageState extends State<SaleReturnEditorPage> {
  late final Future<List<ReturnLineProgress>> _progress = _load();
  final _lengths = <int, TextEditingController>{};
  final _note = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _request = _requestKey('sale-return');
  bool _saving = false;

  Future<List<ReturnLineProgress>> _load() async {
    final rows = await widget.fulfillment.returnableLines(widget.dispatchId);
    for (final row in rows) {
      _lengths[row.lineId] = TextEditingController();
    }
    return rows;
  }

  @override
  void dispose() {
    for (final ctrl in _lengths.values) { ctrl.dispose(); }
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit(List<ReturnLineProgress> progress) async {
    if (_saving || !_form.currentState!.validate()) return;
    final lines = <ReturnInputLine>[];
    try {
      for (final row in progress) {
        if (row.remainingLengthMilli == 0) continue;
        final value = _lengths[row.lineId]!.text.trim();
        if (value.isEmpty || value == '0') continue;
        final length = Fixed.parse(value, decimals: 3);
        if (length <= 0 || length > row.remainingLengthMilli) {
          throw ArgumentError('退货米数超出原出库行可退数量');
        }
        lines.add(ReturnInputLine(
          dispatchLineId: row.lineId, lengthMilli: length));
      }
      if (lines.isEmpty) throw ArgumentError('请输入实际收到的退回米数');
      setState(() => _saving = true);
      final id = await widget.fulfillment.postSaleReturn(
        dispatchId: widget.dispatchId, requestKey: _request,
        lines: lines, note: _note.text);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('实物退货未完成：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('销售实物退货')),
    body: FutureBuilder<List<ReturnLineProgress>>(
      future: _progress,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('无法读取原出库：${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final progress = snapshot.data!;
        if (progress.every((p) => p.remainingLengthMilli == 0)) {
          return const Center(child: Text('此出库单全部退回，无可退数量'));
        }
        return Form(key: _form, child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('仅登记已经实际收到、可以重新入库的货品。'
            '退货回到原出库仓库/批次；财务退款或减免应收必须另走贷项/冲销流程。',
            style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          for (final row in progress) if (row.remainingLengthMilli > 0)
            Card(child: Padding(padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${row.code} · 原出库行 #${row.lineId}',
                  style: Theme.of(context).textTheme.titleMedium),
                Text('可退 ${_meters(row.remainingLengthMilli)} 米；'
                  '原门幅 ${_meters(row.widthMilli)} 米'),
                Text('退回 ${row.warehouseCode} / '
                  '${row.batchCode.isEmpty ? '无批次' : row.batchCode}'),
                const SizedBox(height: 12),
                TextFormField(controller: _lengths[row.lineId],
                  decoration: const InputDecoration(labelText: '本次实际退货米数'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty || v.trim() == '0') return null;
                    try {
                      final n = Fixed.parse(v, decimals: 3);
                      return n > 0 && n <= row.remainingLengthMilli
                        ? null : '退货米数超过可退量';
                    } catch (_) { return '米数最多三位小数'; }
                  }),
              ]),
            )),
          TextFormField(controller: _note,
            decoration: const InputDecoration(labelText: '退货原因与备注')),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : () => _submit(progress),
            icon: const Icon(Icons.assignment_return),
            label: Text(_saving ? '提交中…' : '确认实物退货入库')),
          const SizedBox(height: 12),
          const Text('该操作不创建退款记录，不自动调整客户应收账款。',
            style: TextStyle(color: Colors.grey)),
        ]));
      },
    ),
  );
}
