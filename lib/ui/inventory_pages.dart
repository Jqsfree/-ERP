import 'dart:math';

import 'package:flutter/material.dart';

import '../application/inventory_store.dart';
import '../domain/inventory.dart';
import '../domain/money.dart';

String areaText(int micro) => Fixed.format(micro, decimals: 6, trim: true);

/// The stock screen is read-only except for warehouse master-data creation.
/// Inventory balances are ALWAYS derived from stock_movements.
class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key, required this.store});
  final InventoryStore store;
  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  late Future<(List<Warehouse>, List<StockBalance>, List<StockMovementRecord>)> _data = _load();

  Future<(List<Warehouse>, List<StockBalance>, List<StockMovementRecord>)> _load() async =>
    (await widget.store.warehouses(), await widget.store.stockBalances(),
      await widget.store.stockMovements());

  void _reload() {
    final next = _load();
    setState(() { _data = next; });
  }

  Future<void> _addWarehouse() async {
    var code = '';
    var name = '';
    final key = GlobalKey<FormState>();
    final result = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('新增仓库'),
      content: Form(key: key, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(decoration: const InputDecoration(labelText: '仓库编码 *'),
          onChanged: (v) => code = v,
          validator: (v) => v == null || v.trim().isEmpty ? '必填' : null),
        const SizedBox(height: 12),
        TextFormField(decoration: const InputDecoration(labelText: '仓库名称 *'),
          onChanged: (v) => name = v,
          validator: (v) => v == null || v.trim().isEmpty ? '必填' : null),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () async {
          if (!key.currentState!.validate()) return;
          try {
            await widget.store.addWarehouse(code: code, name: name);
            if (ctx.mounted) Navigator.pop(ctx, true);
          } catch (e) {
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text('仓库保存失败：$e')));
            }
          }
        }, child: const Text('保存')),
      ],
    ));
    if (result == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('库存与流水'),
      actions: [IconButton(tooltip: '刷新库存', onPressed: _reload,
        icon: const Icon(Icons.refresh))]),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _addWarehouse, icon: const Icon(Icons.add),
      label: const Text('新增仓库')),
    body: FutureBuilder<(List<Warehouse>, List<StockBalance>, List<StockMovementRecord>)>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('读取库存失败：${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final (warehouses, balances, movements) = snapshot.data!;
        return ListView(padding: const EdgeInsets.all(16), children: [
          const Text('库存由采购收货（+）、销售出库（−）、实物退货（+）流水汇总；不含库存估值或财务退款。',
            style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 18),
          Text('仓库（${warehouses.length}）', style: Theme.of(context).textTheme.titleMedium),
          if (warehouses.isEmpty) const ListTile(title: Text('请先新增仓库，才能登记采购收货')),
          for (final warehouse in warehouses)
            ListTile(title: Text('${warehouse.code} · ${warehouse.name}'),
              trailing: Text(warehouse.active ? '启用' : '停用')),
          const Divider(),
          Text('当前库存（㎡）', style: Theme.of(context).textTheme.titleMedium),
          if (balances.isEmpty) const ListTile(title: Text('尚无实际收货入库流水')),
          for (final balance in balances)
            ListTile(
              title: Text('${balance.productCode} · ${balance.warehouseCode}'),
              subtitle: Text(balance.batchCode.isEmpty ? '未指定批次' : '批次：${balance.batchCode}'),
              trailing: Text('${areaText(balance.areaMicro)} ㎡')),
          const Divider(),
          Text('库存流水（${movements.length}）', style: Theme.of(context).textTheme.titleMedium),
          for (final movement in movements)
            ListTile(
              title: Text('${movement.receiptNumber} · ${movement.productCode}'),
              subtitle: Text('${movement.warehouseCode} · '
                '${movement.batchCode.isEmpty ? '无批次' : movement.batchCode}'),
              trailing: Text('${movement.deltaAreaMicro > 0 ? '+' : ''}${areaText(movement.deltaAreaMicro)} ㎡')),
          const SizedBox(height: 96),
        ]);
      },
    ),
  );
}

/// Enter accepted length per PO LINE; width is inherited from the PO snapshot.
/// A single receipt is committed atomically along with its stock movements.
class PurchaseReceivePage extends StatefulWidget {
  const PurchaseReceivePage({
    super.key, required this.store, required this.purchaseOrderId,
  });
  final InventoryStore store;
  final int purchaseOrderId;
  @override
  State<PurchaseReceivePage> createState() => _PurchaseReceivePageState();
}

class _PurchaseReceivePageState extends State<PurchaseReceivePage> {
  late final Future<(List<Warehouse>, List<ReceiptLineProgress>)> _data = _load();
  final _lengths = <int, TextEditingController>{};
  final _batches = <int, TextEditingController>{};
  final _warehouses = <int, int?>{};
  final _note = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  final _requestKey = 'receive-${DateTime.now().microsecondsSinceEpoch}-'
      '${Random.secure().nextInt(1 << 32)}';

  Future<(List<Warehouse>, List<ReceiptLineProgress>)> _load() async {
    final locations = (await widget.store.warehouses()).where((w) => w.active).toList();
    final lines = await widget.store.receivableLines(widget.purchaseOrderId);
    for (final line in lines) {
      _lengths[line.lineId] = TextEditingController();
      _batches[line.lineId] = TextEditingController();
      _warehouses[line.lineId] = locations.isEmpty ? null : locations.first.id;
    }
    return (locations, lines);
  }

  @override
  void dispose() {
    for (final ctrl in _lengths.values) { ctrl.dispose(); }
    for (final ctrl in _batches.values) { ctrl.dispose(); }
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit(List<ReceiptLineProgress> progress) async {
    if (_saving || !_form.currentState!.validate()) return;
    final lines = <ReceiptInputLine>[];
    try {
      for (final row in progress) {
        final raw = _lengths[row.lineId]!.text.trim();
        if (raw.isEmpty || raw == '0') continue;
        final quantity = Fixed.parse(raw, decimals: 3);
        if (quantity <= 0 || quantity > row.remainingLengthMilli) {
          throw ArgumentError('${row.code} 的收货量超过剩余数量');
        }
        final wh = _warehouses[row.lineId];
        if (wh == null) throw ArgumentError('请选择收货仓库');
        lines.add(ReceiptInputLine(purchaseLineId: row.lineId,
          warehouseId: wh, lengthMilli: quantity,
          batchCode: _batches[row.lineId]!.text.trim()));
      }
      if (lines.isEmpty) throw ArgumentError('至少输入一行实际收货米数');
      setState(() => _saving = true);
      final id = await widget.store.postPurchaseReceipt(
        purchaseOrderId: widget.purchaseOrderId,
        requestKey: _requestKey, lines: lines, note: _note.text);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('收货未完成：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('登记采购收货')),
    body: FutureBuilder<(List<Warehouse>, List<ReceiptLineProgress>)>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('读取待收货明细失败：${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final (locations, progress) = snapshot.data!;
        if (locations.isEmpty) {
          return const Center(child: Text('请先在“库存”模块新增仓库，再登记收货'));
        }
        if (progress.every((p) => p.remainingLengthMilli == 0)) {
          return const Center(child: Text('当前采购单已全部收货，无可收货数量'));
        }
        return Form(key: _form, child: ListView(
          padding: const EdgeInsets.all(16), children: [
            const Text('按采购明细逐行录入实际收货米数；门幅来自采购订单。'
                '留空表示本次不收该行，单次确认会同时生成收货单和入库流水。'),
            for (final line in progress) if (line.remainingLengthMilli > 0)
              Card(child: Padding(padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${line.code} · 行 #${line.lineId}',
                    style: Theme.of(context).textTheme.titleMedium),
                  Text('订购 ${Fixed.format(line.orderedLengthMilli, decimals: 3, trim: true)} 米；'
                    '已收 ${Fixed.format(line.receivedLengthMilli, decimals: 3, trim: true)} 米；'
                    '剩余 ${Fixed.format(line.remainingLengthMilli, decimals: 3, trim: true)} 米；'
                    '门幅 ${Fixed.format(line.widthMilli, decimals: 3, trim: true)} 米'),
                  const SizedBox(height: 12),
                  TextFormField(controller: _lengths[line.lineId],
                    decoration: const InputDecoration(labelText: '本次实际收货米数'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty || v.trim() == '0') return null;
                      try {
                        final n = Fixed.parse(v, decimals: 3);
                        return n > 0 && n <= line.remainingLengthMilli
                          ? null : '超过剩余米数或非法数量';
                      } catch (_) { return '请输入最多三位小数的米数'; }
                    }),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _warehouses[line.lineId],
                    decoration: const InputDecoration(labelText: '收货仓库'),
                    items: locations.map((w) => DropdownMenuItem(
                      value: w.id, child: Text('${w.code} · ${w.name}'))).toList(),
                    onChanged: (value) => _warehouses[line.lineId] = value),
                  const SizedBox(height: 12),
                  TextFormField(controller: _batches[line.lineId],
                    decoration: const InputDecoration(labelText: '批次编码（可空）')),
                ]))),
            TextFormField(controller: _note,
              decoration: const InputDecoration(labelText: '收货备注')),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : () => _submit(progress),
              icon: const Icon(Icons.inventory_2),
              label: Text(_saving ? '收货提交中…' : '确认收货并入库')),
            const SizedBox(height: 16),
            const Text('收货仅记录实物流转，不生成供应商应付或付款。'
              '已确认流水不能在当前版本直接删除。',
              style: TextStyle(color: Colors.grey)),
          ],
        ));
      },
    ),
  );
}
