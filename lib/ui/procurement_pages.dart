import 'package:flutter/material.dart';

import '../application/procurement_store.dart';
import '../application/inventory_store.dart';
import '../domain/inventory.dart';
import 'inventory_pages.dart';
import '../application/sales_store.dart';
import '../domain/money.dart';
import '../domain/models.dart';
import '../domain/procurement.dart';

void showProcurementError(BuildContext context, Object error) {
  if (!context.mounted) return;
  final message = error.toString().replaceFirst('Invalid argument(s): ', '');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Supplier master: add, edit and disable. Existing PO snapshots are immutable.
class SuppliersPage extends StatefulWidget {
  const SuppliersPage({super.key, required this.store});
  final ProcurementStore store;

  @override
  State<SuppliersPage> createState() => _SuppliersPageState();
}

class _SuppliersPageState extends State<SuppliersPage> {
  late Future<List<Supplier>> _items = widget.store.suppliers();

  void _reload() {
    final pending = widget.store.suppliers();
    setState(() { _items = pending; });
  }

  Future<void> _openForm([Supplier? supplier]) async {
    var name = supplier?.name ?? '';
    var phone = supplier?.phone ?? '';
    var address = supplier?.address ?? '';
    var note = supplier?.note ?? '';
    var active = supplier?.active ?? true;
    final key = GlobalKey<FormState>();

    final saved = await showDialog<bool>(context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, changeDialog) => AlertDialog(
          title: Text(supplier == null ? '新增供应商' : '修改供应商'),
          content: SizedBox(width: 420, child: SingleChildScrollView(
            child: Form(key: key, child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(initialValue: name,
                  decoration: const InputDecoration(labelText: '供应商名称 *'),
                  onChanged: (v) => name = v,
                  validator: (v) => v == null || v.trim().isEmpty ? '名称不能为空' : null),
                TextFormField(initialValue: phone,
                  decoration: const InputDecoration(labelText: '电话'),
                  onChanged: (v) => phone = v),
                TextFormField(initialValue: address,
                  decoration: const InputDecoration(labelText: '地址'),
                  onChanged: (v) => address = v),
                TextFormField(initialValue: note,
                  decoration: const InputDecoration(labelText: '备注'),
                  onChanged: (v) => note = v),
                if (supplier != null)
                  SwitchListTile(title: const Text('允许新采购订单'),
                    value: active, onChanged: (v) => changeDialog(() => active = v)),
              ],
            )),
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                if (!key.currentState!.validate()) return;
                final item = Supplier(id: supplier?.id, name: name.trim(),
                  phone: phone.trim(), address: address.trim(),
                  note: note.trim(), active: active);
                try {
                  if (supplier == null) {
                    await widget.store.addSupplier(item);
                  } else {
                    await widget.store.updateSupplier(item);
                  }
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  if (ctx.mounted) showProcurementError(ctx, e);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('供应商管理')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _openForm(), icon: const Icon(Icons.add),
      label: const Text('新增供应商')),
    body: FutureBuilder<List<Supplier>>(
      future: _items,
      builder: (ctx, snapshot) {
        if (snapshot.hasError) return Center(child: Text('读取失败：${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        if (snapshot.data!.isEmpty) {
          return const Center(child: Text('暂无供应商，点击右下角新增'));
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 100),
          itemCount: snapshot.data!.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, index) {
            final supplier = snapshot.data![index];
            return ListTile(
              leading: Icon(supplier.active ? Icons.local_shipping : Icons.block),
              title: Text(supplier.name),
              subtitle: Text('${supplier.phone}  ${supplier.address}\n${supplier.note}',
                maxLines: 2),
              trailing: Text(supplier.active ? '启用' : '停用',
                style: TextStyle(color: supplier.active ? null : Colors.grey)),
              onTap: () => _openForm(supplier),
            );
          },
        );
      },
    ),
  );
}

class _PurchaseLineInput {
  int? productId;
  final length = TextEditingController();
  final width = TextEditingController(text: '2.8');
  final cost = TextEditingController();
  final note = TextEditingController();

  PurchaseLine build(List<Product> products) {
    final id = productId;
    if (id == null) throw ArgumentError('请选择采购产品');
    final product = products.firstWhere((p) => p.id == id);
    final len = Fixed.parse(length.text, decimals: 3);
    final widthMilli = Fixed.parse(width.text, decimals: 3);
    final unitCost = Fixed.parse(cost.text, decimals: 2);
    if (len <= 0 || widthMilli <= 0 || unitCost <= 0) {
      throw ArgumentError('米数、门幅和采购单价必须大于零');
    }
    return PurchaseLine(
      productId: id, code: product.code, specification: product.specification,
      lengthMilli: len, widthMilli: widthMilli, unitCostCents: unitCost,
      note: note.text.trim(),
    );
  }

  void dispose() {
    length.dispose();
    width.dispose();
    cost.dispose();
    note.dispose();
  }
}

/// A purchase order commits prices and quantities. It does not receive goods
/// or create supplier payable records.
class PurchaseEditorPage extends StatefulWidget {
  const PurchaseEditorPage({super.key, required this.store, required this.catalog});
  final ProcurementStore store;
  final SalesStore catalog;

  @override
  State<PurchaseEditorPage> createState() => _PurchaseEditorPageState();
}

class _PurchaseEditorPageState extends State<PurchaseEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _note = TextEditingController();
  final _lines = <_PurchaseLineInput>[_PurchaseLineInput()];
  late Future<void> _loading;
  List<Supplier> _suppliers = const [];
  List<Product> _products = const [];
  int? _supplierId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loading = _load();
  }

  Future<void> _load() async {
    final suppliers = await widget.store.suppliers(includeInactive: false);
    final products = await widget.catalog.products();
    _suppliers = suppliers;
    _products = products;
  }

  @override
  void dispose() {
    for (final input in _lines) { input.dispose(); }
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    if (_supplierId == null) {
      showProcurementError(context, ArgumentError('请选择供应商'));
      return;
    }
    setState(() => _saving = true);
    try {
      final lines = _lines.map((e) => e.build(_products)).toList();
      final id = await widget.store.createPurchaseOrder(
        supplierId: _supplierId!, lines: lines, note: _note.text.trim());
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) showProcurementError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _estimate() {
    try {
      final values = _lines.map((e) => e.build(_products));
      final cents = values.fold<int>(0, (sum, row) => sum + row.amountCents);
      return '¥${Fixed.format(cents, decimals: 2)}';
    } catch (_) {
      return '填写完整后计算';
    }
  }

  Widget _row(int index) {
    final input = _lines[index];
    final items = _products.map((p) => DropdownMenuItem<int>(
      value: p.id, child: Text(p.code))).toList();
    return Card(child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        Row(children: [
          Expanded(child: Text('产品行 ${index + 1}')),
          if (_lines.length > 1)
            IconButton(tooltip: '删除本行', icon: const Icon(Icons.delete_outline),
              onPressed: () {
                final old = _lines.removeAt(index);
                setState(() {});
                // Keep disposal after the frame so FormField unmounts first.
                WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
              }),
        ]),
        DropdownButtonFormField<int>(
          initialValue: input.productId,
          decoration: const InputDecoration(labelText: '产品型号 *'),
          items: items,
          validator: (v) => v == null ? '请选择产品' : null,
          onChanged: (v) => setState(() => input.productId = v),
        ),
        TextFormField(
          controller: input.length,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '米数（米）*'),
          onChanged: (_) => setState(() {}),
          validator: (v) => _positive(v, 3),
        ),
        TextFormField(
          controller: input.width,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '门幅（米）*'),
          onChanged: (_) => setState(() {}),
          validator: (v) => _positive(v, 3),
        ),
        TextFormField(
          controller: input.cost,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '采购单价（元/㎡）*'),
          onChanged: (_) => setState(() {}),
          validator: (v) => _positive(v, 2),
        ),
        TextFormField(
          controller: input.note,
          decoration: const InputDecoration(labelText: '明细备注'),
        ),
      ]),
    ));
  }

  String? _positive(String? value, int digits) {
    try {
      if (Fixed.parse(value ?? '', decimals: digits) <= 0) return '必须大于零';
      return null;
    } catch (_) {
      return '请输入正确数字';
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('新增采购订单')),
    body: FutureBuilder<void>(future: _loading, builder: (ctx, snapshot) {
      if (snapshot.hasError) return Center(child: Text('读取失败：${snapshot.error}'));
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_suppliers.isEmpty || _products.isEmpty) {
        return const Center(child: Text('请先新增启用的供应商与产品'));
      }
      return Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<int>(
            initialValue: _supplierId,
            decoration: const InputDecoration(labelText: '供应商 *'),
            items: _suppliers.map((s) => DropdownMenuItem<int>(
              value: s.id, child: Text(s.name))).toList(),
            validator: (value) => value == null ? '请选择供应商' : null,
            onChanged: (value) => setState(() => _supplierId = value),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < _lines.length; i++) _row(i),
          OutlinedButton.icon(onPressed: () => setState(() => _lines.add(_PurchaseLineInput())),
            icon: const Icon(Icons.add), label: const Text('增加一行')),
          TextFormField(controller: _note,
            decoration: const InputDecoration(labelText: '采购订单备注'),
            maxLines: 2),
          const SizedBox(height: 12),
          Text('预计采购金额：${_estimate()}',
            style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(_saving ? '提交中…' : '确认采购订单'),
          ),
          const SizedBox(height: 12),
          const Text('采购订单只记录承诺。不会立即入库、增加应付账款或支付款项。',
            style: TextStyle(color: Colors.grey)),
        ]),
      );
    }),
  );
}

class PurchaseOrdersPage extends StatefulWidget {
  const PurchaseOrdersPage({super.key, required this.store, required this.catalog,
    this.inventory});
  final ProcurementStore store;
  final SalesStore catalog;
  final InventoryStore? inventory;

  @override
  State<PurchaseOrdersPage> createState() => _PurchaseOrdersPageState();
}

class _PurchaseOrdersPageState extends State<PurchaseOrdersPage> {
  late Future<List<PurchaseOrder>> _orders = widget.store.purchaseOrders();

  void _reload() {
    final pending = widget.store.purchaseOrders();
    setState(() { _orders = pending; });
  }

  Future<void> _create() async {
    final id = await Navigator.push<int>(
      context, MaterialPageRoute(builder: (_) =>
        PurchaseEditorPage(store: widget.store, catalog: widget.catalog)));
    if (id == null || !mounted) return;
    _reload();
    final order = await widget.store.purchaseOrderById(id);
    if (order != null && mounted) {
      await Navigator.push<void>(context, MaterialPageRoute(
        builder: (_) => PurchaseDetailPage(store: widget.store, order: order,
          inventory: widget.inventory)));
      if (mounted) _reload();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('采购订单')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _create, icon: const Icon(Icons.add),
      label: const Text('新增采购')),
    body: FutureBuilder<List<PurchaseOrder>>(
      future: _orders,
      builder: (ctx, snapshot) {
        if (snapshot.hasError) return Center(child: Text('读取失败：${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        if (snapshot.data!.isEmpty) {
          return const Center(child: Text('暂无采购订单'));
        }
        return ListView.builder(
          itemCount: snapshot.data!.length,
          itemBuilder: (ctx, index) {
            final order = snapshot.data![index];
            return ListTile(
              title: Text(order.number),
              subtitle: Text('${order.supplierName} · ${order.date} · '
                '${order.status == 'ordered' ? '待收货' : '已取消'}'),
              trailing: Text('¥${Fixed.format(order.totalCents, decimals: 2)}'),
              onTap: () async {
                await Navigator.push<void>(context, MaterialPageRoute(
                  builder: (_) => PurchaseDetailPage(
                    store: widget.store, order: order, inventory: widget.inventory)));
                if (mounted) _reload();
              },
            );
          },
        );
      },
    ),
  );
}

class PurchaseDetailPage extends StatefulWidget {
  const PurchaseDetailPage({super.key, required this.store, required this.order,
    this.inventory});
  final ProcurementStore store;
  final PurchaseOrder order;
  final InventoryStore? inventory;

  @override
  State<PurchaseDetailPage> createState() => _PurchaseDetailPageState();
}

class _PurchaseDetailPageState extends State<PurchaseDetailPage> {
  late PurchaseOrder _order = widget.order;
  bool _busy = false;
  late Future<List<ReceiptLineProgress>> _receiptProgress = _loadProgress();

  Future<List<ReceiptLineProgress>> _loadProgress() async =>
    widget.inventory == null ? [] : widget.inventory!.receivableLines(_order.id);

  void _reloadProgress() {
    final next = _loadProgress();
    setState(() => _receiptProgress = next);
  }

  Future<void> _receive() async {
    final inventory = widget.inventory;
    if (inventory == null || !_order.isActive || _busy) return;
    final id = await Navigator.push<int>(context, MaterialPageRoute(
      builder: (_) => PurchaseReceivePage(
        store: inventory, purchaseOrderId: _order.id)));
    if (id != null && mounted) {
      _reloadProgress();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('收货与库存流水已同时保存')));
    }
  }

  Future<void> _cancel() async {
    if (_busy || !_order.isActive) return;
    final confirmed = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消采购订单'),
        content: const Text('此操作只取消未收货的采购承诺；已有收货时数据库将拒绝取消，历史明细保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认取消')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.store.cancelPurchaseOrder(_order.id);
      final updated = await widget.store.purchaseOrderById(_order.id);
      if (updated == null) throw StateError('采购单已取消，但详情查询失败');
      if (mounted) setState(() => _order = updated);
    } catch (e) {
      if (mounted) showProcurementError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_order.number)),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Text('供应商：${_order.supplierName}'),
      Text('日期：${_order.date}'),
      Text('状态：${_order.status == 'ordered' ? '待收货' : '已取消'}'),
      if (_order.note.isNotEmpty) Text('备注：${_order.note}'),
      const Divider(),
      for (final line in _order.lines)
        ListTile(
          title: Text(line.code),
          subtitle: Text('${Fixed.format(line.lengthMilli, decimals: 3, trim: true)} 米 × '
            '${Fixed.format(line.widthMilli, decimals: 3, trim: true)} 米 × '
            '¥${Fixed.format(line.unitCostCents, decimals: 2)}/㎡'),
          trailing: Text('¥${Fixed.format(line.amountCents, decimals: 2)}'),
        ),
      const Divider(),
      if (widget.inventory != null) ...[
        FutureBuilder<List<ReceiptLineProgress>>(
          future: _receiptProgress,
          builder: (context, snap) {
            if (snap.hasError) return Text('收货状态读取失败：${snap.error}');
            if (!snap.hasData) return const LinearProgressIndicator();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('累计采购收货', style: Theme.of(context).textTheme.titleMedium),
              for (final progress in snap.data!)
                ListTile(title: Text(progress.code),
                  subtitle: Text('已收 ${Fixed.format(progress.receivedLengthMilli,
                    decimals: 3, trim: true)} / '
                    '${Fixed.format(progress.orderedLengthMilli, decimals: 3, trim: true)} 米')),
            ]);
          },
        ),
        if (_order.isActive)
          FilledButton.icon(onPressed: _busy ? null : _receive,
            icon: const Icon(Icons.move_to_inbox), label: const Text('登记本单收货')),
      ],
      const Divider(),
      Text('采购总金额：¥${Fixed.format(_order.totalCents, decimals: 2)}',
        style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      if (_order.isActive)
        OutlinedButton.icon(
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.cancel_outlined),
          label: const Text('取消采购订单'),
        ),
      const SizedBox(height: 12),
      const Text('采购订单不直接入库；独立收货后才形成库存流水，但仍不形成供应商应付账款。',
        style: TextStyle(color: Colors.grey)),
    ]),
  );
}
