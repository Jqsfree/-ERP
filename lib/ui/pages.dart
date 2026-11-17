import '../application/refund_store.dart';
import '../application/master_data_store.dart';
import 'refund_page.dart';
import '../application/data_integrity_store.dart';
import 'data_integrity_page.dart';
import '../services/image_album.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'database_scope.dart';
import 'payment_page.dart';
import 'backup_page.dart';
import 'customer_credit_page.dart';
import 'credit_transfer_dialog.dart';
import '../application/customer_credit_store.dart';
import '../domain/customer_credit.dart';
import 'procurement_pages.dart';
import 'fulfillment_pages.dart';
import 'finance_pages.dart';
import '../application/finance_store.dart';
import '../application/fulfillment_store.dart';
import 'inventory_pages.dart';
import '../application/inventory_store.dart';
import '../application/procurement_store.dart';
import '../application/backup_store.dart';
import '../application/sale_revision_store.dart';
import '../domain/sale_revision.dart';
import '../domain/finance.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../services/invoice_pdf.dart';
import '../services/sales_csv.dart';

const _brand = '凯堡软装';

Future<void> _error(BuildContext context, Object e) async {
  if (!context.mounted) return;
  final message = e is FormatException ? e.message : e.toString().replaceFirst('Invalid argument(s): ', '');
  await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
    title: const Text('操作未完成'), content: Text(message),
    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
  ));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  int _tab = 0;
  Widget entry(String title, String subtitle, IconData icon, VoidCallback action) => Card(
    child: ListTile(contentPadding: const EdgeInsets.all(20), minVerticalPadding: 20,
      leading: Icon(icon, size: 36), title: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      subtitle: Padding(padding: const EdgeInsets.only(top: 8), child: Text(subtitle)),
      trailing: const Icon(Icons.chevron_right), onTap: action));
  @override Widget build(BuildContext context) {
    final store = DatabaseScope.of(context);
    final BackupStore? backupStore = store is BackupStore ? store as BackupStore : null;
    final ProcurementStore? procurement = store is ProcurementStore ? store as ProcurementStore : null;
    final InventoryStore? inventory = store is InventoryStore ? store as InventoryStore : null;
    final FinanceStore? finance = store is FinanceStore ? store as FinanceStore : null;
    final tiles = <({String name, IconData icon, VoidCallback? action})>[
      (name: '新开单', icon: Icons.receipt_long, action: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SaleEditorPage()))),
      (name: '销售记录', icon: Icons.history, action: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SalesPage()))),
      (name: '采购', icon: Icons.shopping_cart,
        action: procurement == null ? null : () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => PurchaseOrdersPage(
            store: procurement, catalog: store, inventory: inventory)))),
      (name: '客户', icon: Icons.people_alt, action: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CustomersPage()))),
      (name: '供应商', icon: Icons.local_shipping,
        action: procurement == null ? null : () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => SuppliersPage(store: procurement)))),
      (name: '产品', icon: Icons.inventory_2, action: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProductsPage()))),
      (name: '库存', icon: Icons.warehouse,
        action: inventory == null ? null : () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => InventoryPage(store: inventory)))),
      (name: '退货', icon: Icons.swap_horiz,
        action: store is FulfillmentStore ? () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const SalesPage())) : null),
      (name: '费用收支', icon: Icons.account_balance_wallet,
        action: finance == null ? null : () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => CashbookPage(store: finance)))),
      (name: '日结对账', icon: Icons.fact_check_outlined,
        action: finance == null ? null : () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => DayClosePage(store: finance)))),
    ];
    return PopScope(canPop: _tab == 0, onPopInvokedWithResult: (didPop, result) {
      if (!didPop) setState(() => _tab = 0);
    }, child: Scaffold(
      appBar: AppBar(title: Text(['凯堡软装 · 开单', '业务管理', '设置'][_tab])),
      bottomNavigationBar: NavigationBar(selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [NavigationDestination(icon: Icon(Icons.receipt_long), label: '开单'),
          NavigationDestination(icon: Icon(Icons.apps), label: '业务'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置')]),
      body: IndexedStack(index: _tab, children: [
        ListView(padding: const EdgeInsets.all(16), children: [
          Text('今天 ${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          entry('快速开单', '选客户、填商品，保存后图片自动存入相册', Icons.add_circle_outline, tiles[0].action!),
          entry('找单／保存图片', '查看以前的单据，重新保存或分享图片', Icons.photo_library_outlined, tiles[1].action!),
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          for (final group in <(String,List<int>)>[('客户与商品',[3,5]),('采购与库存',[2,4,6,7]),('收款与对账',[1,8,9])]) ...[
            Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(group.$1, style: Theme.of(context).textTheme.titleLarge)),
            for (final i in group.$2) if (tiles[i].action != null)
              Card(child: ListTile(minVerticalPadding: 16, leading: Icon(tiles[i].icon),
                title: Text(i == 1 ? '按单收款' : tiles[i].name), trailing: const Icon(Icons.chevron_right), onTap: tiles[i].action)),
          ],
        ]),
        ListView(padding: const EdgeInsets.all(16), children: [
          if (backupStore != null) entry('数据备份与恢复', '把账单备份到手机外，妥善保留备份密码', Icons.backup_outlined,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => BackupPage(store: backupStore)))),
          if (store is DataIntegrityStore) entry('数据检查', '只读核对金额、流水和商品关联，不自动改账', Icons.fact_check_outlined,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => DataIntegrityPage(store: store as DataIntegrityStore)))),
          const ListTile(title: Text('凯堡软装'), subtitle: Text('版本 0.1.10\n新单自动存图片；改单和收款后可手动另存。')),
        ]),
      ]),
    ));
  }
}

Future<bool> _createCustomer(BuildContext context, {Customer? existing}) async {
    final database = DatabaseScope.of(context);
    final formKey = GlobalKey<FormState>();
    var name = existing?.name ?? '';
    var phone = existing?.phone ?? '';
    var address = existing?.address ?? '';
    var balance = Fixed.format(existing?.openingBalanceCents ?? 0, decimals: 2);
    var active = existing?.active ?? true;
    var saving = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => AlertDialog(
        title: Text(existing == null ? '新增客户' : '编辑客户'),
        content: SizedBox(width: 380, child: Form(
          key: formKey,
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: name,
                decoration: const InputDecoration(labelText: '客户名称 *'),
                onChanged: (v) => name = v,
                validator: (v) => v == null || v.trim().isEmpty ? '必填' : null),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: phone,
                decoration: const InputDecoration(labelText: '联系电话'),
                onChanged: (v) => phone = v),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: address,
                decoration: const InputDecoration(labelText: '收货地址'),
                onChanged: (v) => address = v),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: balance,
                readOnly: existing != null,
                decoration: const InputDecoration(labelText: '初始欠款（元）'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (v) => balance = v),
              if (existing != null) SwitchListTile(title: const Text('启用客户'),
                subtitle: const Text('停用后不可新选，历史记录和收款保留'),
                value: active, onChanged: saving ? null : (v) => refresh(() => active = v)),
            ],
          )),
        )),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: saving ? null : () async {
              if (!formKey.currentState!.validate()) return;
              refresh(() => saving = true);
              try {
                final item = Customer(id: existing?.id, name: name, phone: phone, address: address,
                  openingBalanceCents: Fixed.parse(balance, decimals: 2), active: active);
                if (existing == null) {
                  await database.addCustomer(item);
                } else if (database is MasterDataStore) {
                  await (database as MasterDataStore).updateCustomer(item);
                } else { throw StateError('当前存储不支持编辑客户'); }
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) await _error(ctx, e);
              } finally { if (ctx.mounted) refresh(() => saving = false); }
            },
            child: const Text('保存'),
          ),
        ],
      )),
    );
    return saved == true;
}

class CustomersPage extends StatefulWidget {
  const CustomersPage({super.key});
  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  late Future<List<Customer>> _items;
  String _query = '';
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = DatabaseScope.of(context).customers();
  }
  void _refresh() {
    final pending = DatabaseScope.of(context).customers();
    setState(() { _items = pending; });
  }

  Future<void> _create() async {
    if (await _createCustomer(context) && mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('客户管理')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('新增客户')),
    body: FutureBuilder<List<Customer>>(future: _items, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('暂时无法读取，请重试'), TextButton(onPressed: _refresh, child: const Text('重新加载'))]));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.data!.isEmpty) return const Center(child: Text('暂无客户，请点击「新增客户」'));
      final filtered = snapshot.data!.where((c) => '${c.name} ${c.phone} ${c.address}'.toLowerCase().contains(_query)).toList();
      return Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: TextField(decoration: const InputDecoration(labelText: '搜索客户'), onChanged: (v) => setState(() => _query = v.trim().toLowerCase()))),
        Expanded(child: ListView.builder(itemCount: filtered.length, itemBuilder: (context, i) {
        final c = filtered[i];
        final store = DatabaseScope.of(context);
        final credit = store is CustomerCreditStore ? store as CustomerCreditStore : null;
        return ListTile(title: Text(c.active ? c.name : '${c.name}（停用）'), subtitle: Text('${c.phone}  ${c.address}'),
          leading: store is MasterDataStore ? IconButton(tooltip: '编辑客户', icon: const Icon(Icons.edit_outlined), onPressed: () async { if (await _createCustomer(context, existing: c) && mounted) _refresh(); }) : null,
          onTap: credit == null ? null : () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) =>
              CustomerCreditPage(customerId: c.id!, store: credit)));
            if (mounted) _refresh();
          },
          trailing: FutureBuilder<int>(future: DatabaseScope.of(context).customerOutstanding(c.id!),
            builder: (context, s) => Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(s.hasData ? '欠款 ¥${Fixed.format(s.data!, decimals: 2)}' : s.hasError ? '欠款读取失败' : '…'),
                if (credit != null) FutureBuilder<CustomerCreditAccount>(future: credit.customerCreditAccount(c.id!),
                  builder: (context, b) => Text(b.hasData ? '余额 ¥${Fixed.format(b.data!.balanceCents, decimals: 2)}' :
                    b.hasError ? '余额读取失败' : '余额读取中…')),
              ])));
      }))]);
    }),
  );
}

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  late Future<List<Product>> _items;
  String _query = '';
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = DatabaseScope.of(context).products();
  }
  void _refresh() {
    final pending = DatabaseScope.of(context).products();
    setState(() { _items = pending; });
  }

  Future<void> _create({Product? existing}) async {
    final database = DatabaseScope.of(context);
    final formKey = GlobalKey<FormState>();
    var code = existing?.code ?? '';
    var spec = existing?.specification ?? '';
    var price = existing == null ? '' : Fixed.format(existing.unitPriceCents, decimals: 2);
    var active = existing?.active ?? true;
    var saving = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => AlertDialog(
        title: Text(existing == null ? '新增产品' : '编辑产品'),
        content: SizedBox(width: 380, child: Form(
          key: formKey,
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: code,
                decoration: const InputDecoration(labelText: '产品型号 *'),
                onChanged: (v) => code = v,
                validator: (v) => v == null || v.trim().isEmpty ? '必填' : null),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: spec,
                decoration: const InputDecoration(labelText: '规格型号（可空）'),
                onChanged: (v) => spec = v),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: price,
                decoration: const InputDecoration(labelText: '默认单价（元/平方米）*'),
                onChanged: (v) => price = v,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) => v == null || v.isEmpty ? '必填' : null),
              if (existing != null) SwitchListTile(title: const Text('启用产品'),
                subtitle: const Text('停用后不可新选，既有出入库及历史单据保留'),
                value: active, onChanged: saving ? null : (v) => refresh(() => active = v)),
            ],
          )),
        )),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: saving ? null : () async {
              if (!formKey.currentState!.validate()) return;
              refresh(() => saving = true);
              try {
                final item = Product(id: existing?.id, code: code, specification: spec,
                  unitPriceCents: Fixed.parse(price, decimals: 2), active: active);
                if (existing == null) { await database.addProduct(item); }
                else if (database is MasterDataStore) { await (database as MasterDataStore).updateProduct(item); }
                else { throw StateError('当前存储不支持编辑商品'); }
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) await _error(ctx, e);
              } finally { if (ctx.mounted) refresh(() => saving = false); }
            },
            child: const Text('保存'),
          ),
        ],
      )),
    );
    if (saved == true && mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('产品管理')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('新增产品')),
    body: FutureBuilder<List<Product>>(future: _items, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('暂时无法读取，请重试'), TextButton(onPressed: _refresh, child: const Text('重新加载'))]));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.data!.isEmpty) return const Center(child: Text('暂无产品，请点击「新增产品」'));
      final filtered = snapshot.data!.where((p) => '${p.code} ${p.specification}'.toLowerCase().contains(_query)).toList();
      return Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: TextField(decoration: const InputDecoration(labelText: '搜索产品'), onChanged: (v) => setState(() => _query = v.trim().toLowerCase()))),
        Expanded(child: ListView.builder(itemCount: filtered.length, itemBuilder: (context, i) {
        final p = filtered[i];
        return ListTile(title: Text(p.active ? p.code : '${p.code}（停用）'), subtitle: Text(p.specification),
          leading: DatabaseScope.of(context) is MasterDataStore ? IconButton(tooltip: '编辑产品', icon: const Icon(Icons.edit_outlined), onPressed: () => _create(existing: p)) : null,
          trailing: Text('¥${Fixed.format(p.unitPriceCents, decimals: 2)}/㎡'));
      }))]);
    }),
  );
}

class _LineForm {
  _LineForm();
  int? id;
  factory _LineForm.fromSaleLine(SaleLine line) {
    final form = _LineForm();
    form.id = line.id;
    form.productId = line.productId;
    form.code.text = line.code;
    form.spec.text = line.specification;
    form.length.text = Fixed.format(line.lengthMilli, decimals: 3, trim: true);
    form.width.text = Fixed.format(line.widthMilli, decimals: 3, trim: true);
    form.price.text = Fixed.format(line.unitPriceCents, decimals: 2);
    form.note.text = line.note;
    return form;
  }
  final code = TextEditingController();
  final spec = TextEditingController();
  final length = TextEditingController();
  final width = TextEditingController(text: '2.8');
  final price = TextEditingController();
  final note = TextEditingController();
  int? productId;
  void useProduct(Product product) {
    productId = product.id;
    code.text = product.code;
    spec.text = product.specification;
    price.text = Fixed.format(product.unitPriceCents, decimals: 2);
  }
  Map<String, Object?> toDraftJson() => {
    'productId': productId, 'code': code.text, 'spec': spec.text,
    'length': length.text, 'width': width.text, 'price': price.text,
    'note': note.text,
  };
  factory _LineForm.fromDraftJson(Map<String, dynamic> json) {
    String val(String key, [String fallback = '']) =>
        json[key] is String ? json[key] as String : fallback;
    final form = _LineForm();
    form.productId = json['productId'] is int ? json['productId'] as int : null;
    form.code.text = val('code');
    form.spec.text = val('spec');
    form.length.text = val('length');
    form.width.text = val('width', '2.8');
    form.price.text = val('price');
    form.note.text = val('note');
    return form;
  }
  SaleLine toLine() => SaleLine(
    id: id,
    productId: productId, code: code.text.trim(), specification: spec.text.trim(),
    lengthMilli: Fixed.parse(length.text, decimals: 3),
    widthMilli: Fixed.parse(width.text, decimals: 3),
    unitPriceCents: Fixed.parse(price.text, decimals: 2),
    note: note.text.trim(),
  );
  void dispose() {
    code.dispose(); spec.dispose(); length.dispose(); width.dispose();
    price.dispose(); note.dispose();
  }
}

class SaleEditorPage extends StatefulWidget {
  const SaleEditorPage({super.key, this.sale});
  final Sale? sale;
  @override
  State<SaleEditorPage> createState() => _SaleEditorPageState();
}

class _SaleEditorPageState extends State<SaleEditorPage> {
  final _formKey = GlobalKey<FormState>();
  int _step = 0;
  bool _showErrors = false;
  final _scroll = ScrollController();
  final _discount = TextEditingController(text: '0');
  final _received = TextEditingController(text: '0');
  String _initialPaymentMethod = '其他';
  final _note = TextEditingController();
  final _date = TextEditingController();
  late Sale? _original = widget.sale;
  final _requestKey = 'sale-revision-${DateTime.now().microsecondsSinceEpoch}';
  Future<CustomerCreditAccount>? _creditAccount;
  int? _creditCustomerId;
  Future<CustomerCreditAccount>? _accountFor(int? customerId) {
    final store = DatabaseScope.of(context);
    if (customerId == null || store is! CustomerCreditStore) return null;
    if (_creditCustomerId != customerId) {
      _creditCustomerId = customerId;
      _creditAccount = (store as CustomerCreditStore).customerCreditAccount(customerId);
    }
    return _creditAccount;
  }
  final _lines = <_LineForm>[_LineForm()];
  List<Customer> _customers = [];
  List<Product> _products = [];
  int? _customerId;
  bool _saving = false;
  bool _allowExit = false;
  bool _leaving = false;
  bool _restored = false;
  String? _initialRevision;
  String get _fingerprint => jsonEncode({'draft': _draftPayload(), 'date': _date.text});
  Future<void> _leave() async {
    if (_saving || _leaving || _allowExit) return;
    setState(() => _leaving = true);
    try {
      if (_original != null) {
        if (_initialRevision != _fingerprint) {
          final discard = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
            title: const Text('放弃本次修改？'), content: const Text('原销售单不会改变。'), actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('继续修改')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('放弃修改'))]));
          if (discard != true) return;
        }
      } else {
        _draftDebounce?.cancel();
        try { await _persistDraft(); }
        catch (_) {
          if (!mounted) return;
          final discard = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
            title: const Text('草稿未保存'), content: const Text('最新输入尚未保存。可以返回重试，或放弃最新输入离开。'), actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回重试')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('放弃并离开'))]));
          if (discard != true) return;
        }
      }
      if (mounted) { setState(() => _allowExit = true); WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context); }); }
    } finally { if (mounted) setState(() => _leaving = false); }
  }
  Future<void> _restartDraft() async {
    final clear = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('重新填写这张草稿？'), content: const Text('只清除未确认的输入，已保存的销售单不会改变。'), actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('保留草稿')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重新填写'))]));
    if (clear != true || !mounted) return;
    _draftDebounce?.cancel();
    try {
      await _draftWrites.catchError((Object _) {});
      if (!mounted) return;
      await DatabaseScope.of(context).deleteDraft();
      if (!mounted) return;
      final old = List<_LineForm>.of(_lines);
      setState(() {
        _lines..clear()..add(_LineForm()); _customerId = null;
        _discount.text = '0'; _received.text = '0'; _initialPaymentMethod = '其他';
        _note.clear(); _restored = false; _step = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) { for (final line in old) { line.dispose(); } });
    } catch (e) { if (mounted) await _error(context, e); }
  }

  bool _loading = true;
  Timer? _draftDebounce;
  Future<void> _draftWrites = Future<void>.value();

  String _draftPayload() => jsonEncode({
    'schema': 1, 'step': _step, 'customerId': _customerId, 'discount': _discount.text,
    'received': _received.text, 'initialPaymentMethod': _initialPaymentMethod,
    'note': _note.text,
    'lines': _lines.map((line) => line.toDraftJson()).toList(),
  });

  Future<void> _persistDraft() {
    final payload = _draftPayload();
    final database = DatabaseScope.of(context);
    final previous = _draftWrites.catchError((Object _) {});
    final pending = previous.then((_) => database.saveDraft(payload));
    _draftWrites = pending;
    return pending;
  }

  void _touchDraft() {
    if (_original != null || _loading || _saving) return;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 650), () {
      if (!mounted || _saving) return;
      unawaited(_persistDraft().catchError((Object e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('草稿保存失败：$e')));
        }
      }));
    });
  }

  Future<void> _saveDraftNow() async {
    _draftDebounce?.cancel();
    try {
      await _persistDraft();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('草稿已写入本机数据库')));
      }
    } catch (e) {
      if (mounted) await _error(context, e);
    }
  }

  void _restoreDraft(String raw, List<Customer> customers) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
      throw const FormatException('草稿格式版本不兼容');
    }
    _step = decoded['step'] is int ? (decoded['step'] as int).clamp(0, 2) : 0;
    final items = decoded['lines'];
    if (items is! List || items.isEmpty) throw const FormatException('草稿缺少明细行');
    final restored = items.map((item) {
      if (item is! Map) throw const FormatException('草稿明细格式错误');
      return _LineForm.fromDraftJson(Map<String, dynamic>.from(item));
    }).toList();
    for (final old in _lines) { old.dispose(); }
    _lines..clear()..addAll(restored);
    final savedCustomer = decoded['customerId'];
    _customerId = savedCustomer is int &&
        customers.any((c) => c.id == savedCustomer) ? savedCustomer : null;
    _discount.text = decoded['discount'] is String ? decoded['discount'] as String : '0';
    _received.text = decoded['received'] is String ? decoded['received'] as String : '0';
    final savedMethod = decoded['initialPaymentMethod'];
    _initialPaymentMethod = savedMethod is String && FinanceMath.methods.contains(savedMethod)
        ? savedMethod : '其他';
    _note.text = decoded['note'] is String ? decoded['note'] as String : '';
  }

  bool _didLoad = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didLoad) {
      _didLoad = true;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final database = DatabaseScope.of(context);
      final original = widget.sale == null ? null : await database.saleById(widget.sale!.id);
      final customers = (await database.customers()).where((c) => c.active || c.id == original?.customerId).toList();
      final products = (await database.products()).where((p) => p.active || (original?.lines.any((l) => l.productId == p.id) ?? false)).toList();
      if (widget.sale != null && original == null) throw StateError('销售单不存在');
      final draft = original == null ? await database.loadDraft() : null;
      if (!mounted) return;
      if (original != null) {
        _original = original;
        for (final old in _lines) { old.dispose(); }
        _lines..clear()..addAll(original.lines.map(_LineForm.fromSaleLine));
        _customerId = original.customerId;
        _date.text = original.date;
        _discount.text = Fixed.format(original.discountCents, decimals: 2);
        _note.text = original.note;
      }
      var draftError = false;
      if (draft != null) {
        try {
          _restoreDraft(draft, customers);
          for (final line in _lines) {
            if (line.productId != null && !products.any((p) => p.id == line.productId && p.code == line.code.text)) line.productId = null;
          }
          _restored = true;
        }
        catch (e) {
          draftError = true;
          debugPrint('Draft recovery failed; original retained in SQLite: $e');
        }
      }
      _initialRevision = _fingerprint;
      setState(() { _customers = customers; _products = products; _loading = false; });
      if (draftError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('草稿无法解析，原始数据已保留在本机')));
      }
    } catch (e) { if (mounted) { setState(() => _loading = false); await _error(context, e); } }
  }

  Future<void> _addCustomer() async {
    final existingIds = _customers.map((customer) => customer.id).toSet();
    if (!await _createCustomer(context) || !mounted) return;
    try {
      final customers = (await DatabaseScope.of(context).customers()).where((c) => c.active || c.id == _original?.customerId).toList();
      if (!mounted) return;
      final added = customers.where((customer) => !existingIds.contains(customer.id)).toList();
      setState(() {
        _customers = customers;
        if (added.length == 1) _customerId = added.single.id;
      });
      _touchDraft();
    } catch (e) { if (mounted) await _error(context, e); }
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _scroll.dispose();
    _discount.dispose(); _received.dispose(); _note.dispose(); _date.dispose();
    for (final line in _lines) { line.dispose(); }
    super.dispose();
  }

  String get _contractSummary {
    try {
      if (_subtotal == null) return '请先填写商品数量和价格';
      return '合同金额 ¥${Fixed.format(BillingMath.payable(_subtotal!, Fixed.parse(_discount.text, decimals: 2)), decimals: 2)}';
    } catch (_) { return '请核对商品金额和优惠'; }
  }
  int? get _subtotal {
    try {
      return _lines.fold<int>(0, (sum, input) => sum + input.toLine().totalCents);
    } catch (_) { return null; }
  }

  Future<void> _removeLine(int index) async {
    if (_lines.length == 1) return;
    final input = _lines[index];
    if (_original == null && (input.code.text.isNotEmpty || input.length.text.isNotEmpty || input.price.text.isNotEmpty)) {
      final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('删除这行商品？'), content: Text('第${index + 1}行 ${input.code.text}，删除后需重新填写。'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('保留')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认删除'))]));
      if (confirmed != true || !mounted) return;
    }
    final removed = _lines.removeAt(index);
    setState(() {});
    _touchDraft();
    // Keep the text controllers alive until the current frame is detached.
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  Future<void> _chooseCustomer() async {
    var query = '';
    final chosen = await showModalBottomSheet<Customer>(context: context,
      isScrollControlled: true, builder: (ctx) => StatefulBuilder(builder: (ctx, update) =>
        SafeArea(child: Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.6, child: Column(children: [
            TextField(decoration: const InputDecoration(labelText: '搜索客户姓名或电话'),
              onChanged: (v) => update(() => query = v.trim().toLowerCase())),
            Expanded(child: ListView(children: [
              for (final customer in _customers.where((c) => '${c.name} ${c.phone}'.toLowerCase().contains(query)))
                ListTile(title: Text(customer.name), subtitle: Text(customer.phone),
                  onTap: () => Navigator.pop(ctx, customer)),
            ])),
          ]))))));
    if (chosen != null && mounted) {
      setState(() => _customerId = chosen.id);
      _touchDraft();
    }
  }

  Future<void> _nextStep() async {
    FocusScope.of(context).unfocus();
    setState(() => _showErrors = true);
    final errors = _formKey.currentState!.validateGranularly();
    if (errors.isNotEmpty) {
      await Scrollable.ensureVisible(errors.first.context,
        duration: const Duration(milliseconds: 250), alignment: 0.15);
      return;
    }
    setState(() { _step++; _showErrors = false; });
    _touchDraft();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _save() async {
    if (_saving || _leaving || _allowExit) return;
    setState(() => _showErrors = true);
    final errors = _formKey.currentState!.validateGranularly();
    if (errors.isNotEmpty) { await Scrollable.ensureVisible(errors.first.context, alignment: 0.15); return; }
    if (_customerId == null) { await _error(context, ArgumentError('请先选择客户')); return; }
    setState(() => _saving = true);
    _draftDebounce?.cancel();
    final database = DatabaseScope.of(context);
    int? savedId;
    try {
      await _draftWrites;
      if (!mounted) return;
      if (_original == null && _accountFor(_customerId) != null) {
        try { await _accountFor(_customerId); }
        catch (_) {
          _creditCustomerId = null;
          _creditAccount = null;
          throw StateError('余额读取失败，请重试后再确认开单。');
        }
      }
      if (!mounted) return;
      final customer = _customers.firstWhere((c) => c.id == _customerId);
      int id;
      final original = _original;
      if (original != null) {
        if (database is! SaleRevisionStore) throw StateError('当前存储不支持改单');
        final lines = _lines.map((e) => e.toLine()).toList();
        final discount = Fixed.parse(_discount.text, decimals: 2);
        final preview = SaleRevisionPreview.calculate(original: original,
          lines: lines, discountCents: discount);
        final changedCustomer = customer.id != original.customerId;
        final netCash = original.netReceivedCents;
        final overpaid = changedCustomer ? netCash :
          (netCash > preview.payableCents ? netCash - preview.payableCents : 0);
        final capacity = preview.payableCents > netCash ? preview.payableCents - netCash : 0;
        final keepCredit = changedCustomer ? 0 :
          (original.creditAppliedCents < capacity ? original.creditAppliedCents : capacity);
        final releaseCredit = original.creditAppliedCents - keepCredit;
        final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('确认修改销售单'),
          content: SingleChildScrollView(child: Text('单号 ${original.number}，版本 ${original.revision} → ${original.revision + 1}\n'
            '修改前 ¥${Fixed.format(original.payableCents, decimals: 2)}\n'
            '修改后 ¥${Fixed.format(preview.payableCents, decimals: 2)}\n'
            '金额差额 ¥${Fixed.format(preview.amountDeltaCents, decimals: 2)}\n'
            '${changedCustomer ? '原客户已收待退' : '本次超收待退'} ¥${Fixed.format(overpaid, decimals: 2)}\n'
            '${changedCustomer ? '新客户应收 ¥${Fixed.format(preview.payableCents, decimals: 2)}\n' : ''}'
            '释放原客户余额抵扣 ¥${Fixed.format(releaseCredit, decimals: 2)}\n'
            '不会自动退款、转余额或入库。超出新订购量的实物需关联原出库退回。')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回修改')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认保存修改'))]));
        if (confirmed != true) return;
        await (database as SaleRevisionStore).reviseSale(saleId: original.id,
          expectedRevision: original.revision, requestKey: _requestKey,
          customerId: customer.id!, date: _date.text.trim(), lines: lines,
          discountCents: discount, note: _note.text);
        id = original.id;
      } else {
        final lines = _lines.map((e) => e.toLine()).toList();
        final discount = Fixed.parse(_discount.text, decimals: 2);
        final received = Fixed.parse(_received.text, decimals: 2);
        if (database is CustomerCreditStore) {
          id = await (database as CustomerCreditStore).createSaleWithCredit(customer: customer,
            lines: lines, discountCents: discount, initialReceivedCents: received,
            initialPaymentMethod: _initialPaymentMethod,
            requestKey: _requestKey, note: _note.text);
        } else {
          id = await database.createSale(customer: customer, lines: lines,
            discountCents: discount, initialReceivedCents: received,
            initialPaymentMethod: _initialPaymentMethod, note: _note.text);
        }
      }
      savedId = id;
      _allowExit = true;
      final sale = await database.saleById(id);
      if (!mounted) return;
      if (sale == null) {
        Navigator.pop(context);
        return;
      }
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => SaleDetailPage(sale: sale, justSaved: true, autoSaveImages: original == null)));
    } catch (e) {
      if (mounted && savedId != null) {
        await _error(context, StateError('销售单已保存，但加载详情失败。请在销售记录中查看，避免重复开单。\n$e'));
        if (mounted) Navigator.pop(context);
      } else if (mounted) {
        await _error(context, e);
      }
    } finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) => PopScope(canPop: _allowExit, onPopInvokedWithResult: (didPop, result) { if (!didPop) _leave(); }, child: Scaffold(
    appBar: AppBar(leadingWidth: 92, leading: TextButton.icon(onPressed: _leave, icon: const Icon(Icons.arrow_back), label: const Text('返回')), title: Text(_original == null ? '新开销售单' : '修改销售单 · 版本 ${_original!.revision}')),
    bottomNavigationBar: _loading ? null : SafeArea(child: Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_contractSummary, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 8),
        if (_original == null && _step > 0) OutlinedButton(onPressed: _saving || _leaving ? null : () { setState(() => _step--); _touchDraft(); if (_scroll.hasClients) _scroll.jumpTo(0); }, child: const Text('上一步')),
        FilledButton.icon(onPressed: _saving || _leaving ? null : (_original == null && _step < 2 ? _nextStep : _save), icon: const Icon(Icons.check_circle_outline),
          label: Text(_saving ? '保存中…' : _original == null ? (_step < 2 ? '下一步' : '确认开单并保存图片') : '核对并保存修改')),
      ]))),
    body: _loading ? const Center(child: CircularProgressIndicator()) :
      AbsorbPointer(absorbing: _saving || _leaving, child: Form(key: _formKey, autovalidateMode: _showErrors ? AutovalidateMode.always : AutovalidateMode.disabled, child: ListView(controller: _scroll, padding: const EdgeInsets.all(16), children: [
        if (_original == null) Text('第 ${_step + 1} 步，共3步 · ${['选客户', '填商品', '核对金额'][_step]}', style: Theme.of(context).textTheme.titleLarge),
        if (_restored) Card(child: ListTile(title: const Text('已恢复上次未完成内容'), subtitle: const Text('这是草稿，还没有正式开单。'), trailing: TextButton(onPressed: _restartDraft, child: const Text('重新填写')))),
        if (_original != null || _step == 0) ...[
        Text('1. 选择客户', style: Theme.of(context).textTheme.titleLarge),
        const Text('带 * 的项目为必填。'),
        if (_customers.isEmpty) const Text('尚无客户，请先新增客户。'),
        TextButton.icon(onPressed: _saving ? null : _addCustomer, icon: const Icon(Icons.person_add_alt), label: const Text('新增客户')),
        OutlinedButton.icon(onPressed: _chooseCustomer, icon: const Icon(Icons.search), label: const Text('搜索客户')),
        DropdownButtonFormField<int>(
          key: ValueKey(_customerId),
          initialValue: _customerId, isExpanded: true,
          decoration: const InputDecoration(labelText: '客户 *'),
          items: _customers.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis))).toList(),
          onChanged: (value) {
            setState(() => _customerId = value);
            _touchDraft();
          },
          validator: (value) => value == null ? '请选择客户' : null,
        ),
        const SizedBox(height: 12),
        if (_original != null) TextFormField(controller: _date,
          decoration: InputDecoration(labelText: '销售日期（YYYY-MM-DD）',
            suffixIcon: IconButton(tooltip: '选择销售日期', icon: const Icon(Icons.calendar_month), onPressed: () async {
              final initial = DateTime.tryParse(_date.text) ?? DateTime.now();
              final picked = await showDatePicker(context: context, initialDate: initial,
                firstDate: DateTime(1900), lastDate: DateTime(2100, 12, 31));
              if (picked != null && mounted) {
                setState(() => _date.text = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
              }
            })),
          validator: (v) {
            try { FinanceMath.validDay(v?.trim() ?? ''); return null; }
            catch (_) { return '请输入有效日期 YYYY-MM-DD'; }
          })
        else Text('销售日期：${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}',
          style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        ],
        if (_original != null || _step == 1) ...[
        Text('2. 填写产品', style: Theme.of(context).textTheme.titleLarge),
        const Text('可手动填写，或从产品库选择；米数和门幅单位为米。'),
        for (var i = 0; i < _lines.length; i++) _lineCard(i),
        OutlinedButton.icon(onPressed: () {
          setState(() => _lines.add(_LineForm()));
          _touchDraft();
        }, icon: const Icon(Icons.add), label: const Text('新增一行产品')),
        const SizedBox(height: 16),
        ],
        if (_original != null || _step == 2) ...[
        if (_original == null) ...[
          Text('客户：${_customers.where((c) => c.id == _customerId).map((c) => c.name).join()}'),
          for (final line in _lines) Text('${line.code.text} · ${line.length.text}米 × ${line.width.text}米 · 单价 ¥${line.price.text}'),
        ],
        Text('3. 核对金额', style: Theme.of(context).textTheme.titleLarge),
        Text('产品金额：${_subtotal == null ? '请输入有效数量、门幅和单价' : '¥${Fixed.format(_subtotal!, decimals: 2)}'}',
          style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextFormField(controller: _discount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '优惠金额（元）'),
          validator: (value) {
            try { BillingMath.payable(_subtotal ?? 0, Fixed.parse(value ?? '', decimals: 2)); return null; }
            catch (_) { return '请输入有效优惠，且不能超过产品金额'; }
          },
          onChanged: (_) { setState(() {}); _touchDraft(); }),
        const SizedBox(height: 12),
        if (_original == null) TextFormField(controller: _received, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '开单已收款（元）'),
          validator: (value) {
            try {
              final received = Fixed.parse(value ?? '', decimals: 2);
              final payable = BillingMath.payable(_subtotal ?? 0, Fixed.parse(_discount.text, decimals: 2));
              return received > payable ? '收款不能超过应收金额' : null;
            } catch (_) { return '请输入有效收款金额'; }
          },
          onChanged: (_) { setState(() {}); _touchDraft(); }),
        if (_original == null) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _initialPaymentMethod,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '开单首收渠道'),
            items: FinanceMath.methods.map((method) => DropdownMenuItem(
              value: method, child: Text(method))).toList(),
            onChanged: (method) {
              if (method == null) return;
              setState(() => _initialPaymentMethod = method);
              _touchDraft();
            },
          ),
          const Text('未收首款时不生成收款流水。'),
        ],
        const SizedBox(height: 12),
        TextFormField(controller: _note, decoration: const InputDecoration(labelText: '订单备注'),
          maxLines: 2, onChanged: (_) => _touchDraft()),
        const SizedBox(height: 14),
        if (_subtotal != null) Builder(builder: (context) {
          try {
            final payable = BillingMath.payable(_subtotal!, Fixed.parse(_discount.text, decimals: 2));
            final received = _original == null ? Fixed.parse(_received.text, decimals: 2) :
              (_customerId == _original!.customerId ? _original!.receivedCents : 0);
            return Text('应收金额：¥${Fixed.format(payable, decimals: 2)}  ·  已收款：¥${Fixed.format(received, decimals: 2)}',
              style: Theme.of(context).textTheme.titleMedium);
          } catch (_) { return const Text('请检查优惠金额'); }
        }),
        if (_accountFor(_customerId) != null) FutureBuilder<CustomerCreditAccount>(
          future: _accountFor(_customerId), builder: (context, state) {
            if (state.hasError) return Text('余额读取失败：${state.error}');
            if (!state.hasData) return const Text('余额读取中…');
            final available = state.data!.balanceCents;
            if (_original != null) {
              return Text('可用余额 ¥${Fixed.format(available, decimals: 2)}；'
                '本单已抵扣 ¥${Fixed.format(_original!.creditAppliedCents, decimals: 2)}。改单不自动追加抵扣。');
            }
            try {
              final payable = BillingMath.payable(_subtotal ?? 0, Fixed.parse(_discount.text, decimals: 2));
              final cash = Fixed.parse(_received.text, decimals: 2);
              final capacity = payable > cash ? payable - cash : 0;
              final apply = available < capacity ? available : capacity;
              return Text('可用余额 ¥${Fixed.format(available, decimals: 2)}\n'
                '预计余额抵扣 ¥${Fixed.format(apply, decimals: 2)} · 预计未收 ¥${Fixed.format(capacity - apply, decimals: 2)}\n'
                '现金首收优先，余额抵扣剩余应收；实际抵扣以保存时可用余额为准。');
            } catch (_) { return Text('可用余额 ¥${Fixed.format(available, decimals: 2)}；请先核对金额。'); }
          }),
        const SizedBox(height: 20),

        if (_original == null) OutlinedButton.icon(onPressed: _saving ? null : _saveDraftNow,
          icon: const Icon(Icons.save_outlined), label: const Text('立即保存草稿')),
        const SizedBox(height: 10),
        if (_original != null) const Text('修改保留历史版本；原收款不变，库存仅在实际出库/退货时变化。')
        else const Padding(padding: EdgeInsets.only(top: 12),
          child: Text('输入暂停后会自动保存草稿，重新进入可继续填写；确认保存后才生成销售单。保存销售单不会自动扣减库存。',
            style: TextStyle(color: Colors.grey))),
        const SizedBox(height: 30),
        ],
      ]))),
  ));

  Widget _lineCard(int index) {
    final input = _lines[index];
    return Card(margin: const EdgeInsets.only(bottom: 12), child: Padding(
      padding: const EdgeInsets.all(12), child: Column(children: [
        Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('产品 ${index + 1}', style: Theme.of(context).textTheme.titleMedium),
          Tooltip(message: '删除本行', child: TextButton.icon(onPressed: () => _removeLine(index), icon: const Icon(Icons.delete_outline), label: const Text('删除这行'))),
        ]),
        if (_products.isNotEmpty) DropdownButtonFormField<int>(
          key: ValueKey((input, input.productId)),
          initialValue: input.productId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '从产品库选择（可选）'),
          items: _products.where((p) => p.active || p.id == input.productId).map((p) => DropdownMenuItem(value: p.id, child: Text(p.active ? p.code : '${p.code}（停用）'), enabled: p.active)).toList(),
          onChanged: (id) {
            if (id == null) return;
            setState(() => input.useProduct(_products.firstWhere((p) => p.id == id)));
            _touchDraft();
          },
        ),
        const SizedBox(height: 10),
        TextFormField(controller: input.code, decoration: const InputDecoration(labelText: '产品型号 *'),
          validator: (v) => v == null || v.trim().isEmpty ? '必填' : null,
          onChanged: (_) {
            if (input.productId != null) setState(() => input.productId = null);
            _touchDraft();
          }),
        if (input.productId == null) const Text('手填商品：未关联库存。需要出库时请从产品库重新选择。'),
        const SizedBox(height: 10),

        Row(children: [
          Expanded(child: _amountInput(input.length, '米数 *')),
          const SizedBox(width: 8),
          Expanded(child: _amountInput(input.width, '门幅 *')),
        ]),
        const SizedBox(height: 10),
        _amountInput(input.price, '单价（元/㎡）*'),
        const SizedBox(height: 10),
        ExpansionTile(title: const Text('规格与备注（选填）'), children: [
        TextField(controller: input.spec, decoration: const InputDecoration(labelText: '规格型号'),
          onChanged: (_) => _touchDraft()),
        TextField(controller: input.note, decoration: const InputDecoration(labelText: '本行备注'),
          onChanged: (_) => _touchDraft()),
        ]),
        const SizedBox(height: 10),
        Builder(builder: (_) {
          try {
            final line = input.toLine();
            return Align(alignment: Alignment.centerRight, child: Text(
              '总数量 ${line.areaText} ㎡  ·  金额 ¥${Fixed.format(line.totalCents, decimals: 2)}',
              style: const TextStyle(fontWeight: FontWeight.w600)));
          } catch (_) { return const SizedBox.shrink(); }
        }),
      ]),
    ));
  }

  Widget _amountInput(TextEditingController controller, String label) => TextFormField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label, helperText: label.contains('单价') ? '每平方米的价格' : '单位：米'),
    textInputAction: TextInputAction.done, onFieldSubmitted: (_) => FocusScope.of(context).unfocus(),
    onChanged: (_) { setState(() {}); _touchDraft(); },
    validator: (value) {
      final name = label.replaceAll(' *', '');
      if (value == null || value.trim().isEmpty) return '请填写$name';
      try {
        final price = label.contains('单价');
        final parsed = Fixed.parse(value, decimals: price ? 2 : 3);
        if (!price && parsed <= 0) return '$name必须大于0';
        return null;
      } on FormatException catch (e) { return '$name：${e.message}'; }
    },
    autovalidateMode: AutovalidateMode.onUserInteraction,
  );
}

class SalesPage extends StatefulWidget {
  const SalesPage({super.key});
  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  late Future<List<Sale>> _items;
  String _query = '';
  bool _exporting = false;
  final _search = TextEditingController();
  @override void dispose() { _search.dispose(); super.dispose(); }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = DatabaseScope.of(context).sales();
  }
  void _refresh() {
    final pending = DatabaseScope.of(context).sales();
    setState(() { _items = pending; });
  }

  Future<void> _exportCsv(List<Sale> sales) async {
    final bundle = SalesCsvExporter.generate(sales);
    final dir = await getTemporaryDirectory();
    final orders = File('${dir.path}/凯堡软装-销售单.csv');
    final lines = File('${dir.path}/凯堡软装-销售明细.csv');
    await Future.wait([
      orders.writeAsString(bundle.orders, flush: true),
      lines.writeAsString(bundle.lines, flush: true),
    ]);
    await SharePlus.instance.share(ShareParams(
      files: [
        XFile(orders.path, mimeType: 'text/csv'),
        XFile(lines.path, mimeType: 'text/csv'),
      ],
      subject: '凯堡软装销售记录（销售单与明细分表）',
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('找单／保存图片'), actions: [
      IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: '刷新'),
    ]),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const SaleEditorPage()));
        if (mounted) _refresh();
      }, icon: const Icon(Icons.add), label: const Text('新开单')),
    body: FutureBuilder<List<Sale>>(future: _items, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('暂时无法读取，请重试'), TextButton(onPressed: _refresh, child: const Text('重新加载'))]));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      final sales = snapshot.data!.where((sale) => '${sale.customerName} ${sale.customerPhone} ${sale.number}'.toLowerCase().contains(_query.toLowerCase())).toList();

      return Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: TextField(controller: _search, decoration: InputDecoration(labelText: '找客户、电话或单号', prefixIcon: const Icon(Icons.search), suffixIcon: _query.isEmpty ? null : IconButton(tooltip: '清空搜索', icon: const Icon(Icons.close), onPressed: () { _search.clear(); setState(() => _query = ''); })), onChanged: (value) => setState(() => _query = value.trim()))),
        if (sales.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(_query.isEmpty ? '还没有销售单，点击“新开单”开始。' : '没有找到匹配单据，请修改或清空搜索。')),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('共 ${sales.length} 单'),
          TextButton.icon(onPressed: sales.isEmpty || _exporting ? null : () async {
            setState(() => _exporting = true);
            try { await _exportCsv(sales); } catch (e) { if (context.mounted) await _error(context, e); }
            finally { if (mounted) setState(() => _exporting = false); }
          }, icon: const Icon(Icons.table_view), label: Text(_exporting ? '正在导出…' : '导出订单与明细 CSV')),
        ])),
        Expanded(child: ListView.builder(itemCount: sales.length, itemBuilder: (ctx, i) {
          final sale = sales[i];
          return Card(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: InkWell(
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleDetailPage(sale: sale)));
              if (mounted) _refresh();
            }, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(sale.customerName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              Text('${sale.number}  ${sale.date}'),
              Text('当前版本 ${sale.revision}'),
              Wrap(spacing: 16, children: [Text('合同 ¥${Fixed.format(sale.payableCents, decimals: 2)}'),
                Text(sale.currentDueCents == 0 ? '本单已结清' : '未收 ¥${Fixed.format(sale.currentDueCents, decimals: 2)}', style: const TextStyle(fontWeight: FontWeight.bold))]),
              const Text('查看单据与保存图片 ›'),
            ]))));
        })),
      ]);
    }),
  );
}

class SaleDetailPage extends StatefulWidget {
  final Sale sale;
  const SaleDetailPage({super.key, required this.sale, this.justSaved = false, this.historical = false, this.autoSaveImages = false});
  final bool autoSaveImages;
  final bool justSaved;
  final bool historical;
  @override
  State<SaleDetailPage> createState() => _SaleDetailPageState();
}

class _SaleDetailPageState extends State<SaleDetailPage> {
  late Sale _sale = widget.sale;
  bool _busy = false;

  Future<void> _transferCredit(PendingSaleRefund refund, CustomerCreditStore store) async {
    if (_busy) return;
    setState(() => _busy = true);
    var posted = false;
    try {
      final confirmed = await showDialog<bool>(context: context, barrierDismissible: false,
        builder: (ctx) => CreditTransferDialog(customerName: refund.customerName,
          maximumCents: refund.amountCents, post: (amount, key) async {
            await store.transferSaleRefundToCredit(saleId: _sale.id, expectedRevision: _sale.revision,
              customerId: refund.customerId, epoch: refund.epoch, amountCents: amount, requestKey: key);
          }));
      if (confirmed != true) return;
      posted = true;
      if (!mounted) return;
      final updated = await DatabaseScope.of(context).saleById(_sale.id);
      if (updated == null) throw StateError('销售单刷新失败');
      if (mounted) {
        setState(() => _sale = updated);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已转入客户余额')));
      }
    } catch (e) {
      if (mounted) {
        final error = posted ? StateError('余额已转入，刷新失败，请重新查询，避免重复操作。') :
          (e is StateError || e is ArgumentError || e is FormatException)
            ? e : StateError('转入结果未能确认，请刷新待退款与余额后重试。');
        await _error(context, error);
      }
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoSaveImages) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _saveImages(); });
    }
  }

  String _imageStatus = '可将这张单据保存到手机相册';
  bool _savingImages = false;
  final _savedImagePages = <int>{};
  String? _imageSnapshotKey;
  Future<void> _saveImages() async {
    if (_busy) return;
    setState(() { _busy = true; _savingImages = true; _imageStatus = '销售单已保存，正在保存图片…'; });
    try {
      final key = '${_sale.id}:${_sale.revision}:${_sale.receivedCents}:${_sale.creditAppliedCents}:${_sale.transferredCents}:${_sale.refundedCents}:${_sale.returnedLengthMilli}:${_sale.returnedAreaMicro}';
      if (_imageSnapshotKey != key) { _savedImagePages.clear(); _imageSnapshotKey = key; }
      final pages = await InvoicePdf.images(_sale);
      final remaining = List.generate(pages.length, (i) => i).where((i) => !_savedImagePages.contains(i)).toList();
      final result = await ImageAlbum.save(pages, '${_sale.number}-v${_sale.revision}', indices: remaining);
      _savedImagePages.addAll(result.saved.where(remaining.contains));
      if (_savedImagePages.length != pages.length) {
        _imageStatus = '已保存 ${_savedImagePages.length}/${pages.length} 张，请重试未完成图片';
        if (mounted) await _error(context, StateError('销售单已保存，图片已保存 ${_savedImagePages.length}/${pages.length} 张。请点击保存图片重试未完成页面。'));
        return;
      }
      _savedImagePages.clear();
      _imageStatus = '图片已保存到相册“凯堡软装”';
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('图片已保存到相册“凯堡软装”')));
    } catch (_) {
      _imageStatus = '销售单已保存，图片未保存完成，请重试';
      if (mounted) await _error(context, StateError('销售单已保存，图片未保存完成。请检查存储权限和空间后点击“保存图片”重试。'));
    } finally { if (mounted) setState(() { _busy = false; _savingImages = false; }); }
  }

  Future<void> _edit() async {
    if (_busy) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleEditorPage(sale: _sale)));
    if (!mounted) return;
    try {
      final updated = await DatabaseScope.of(context).saleById(_sale.id);
      if (mounted && updated != null) setState(() { _sale = updated; _imageStatus = '单据已更新，请保存当前版本图片'; });
    } catch (e) { if (mounted) await _error(context, e); }
  }

  Future<void> _receive() async {
    if (_busy) return;
    final updated = await Navigator.push<Sale>(context, MaterialPageRoute(builder: (_) =>
      PaymentPage(sale: _sale, store: DatabaseScope.of(context))));
    if (!mounted) return;
    try {
      final current = await DatabaseScope.of(context).saleById(_sale.id);
      if (!mounted) return;
      if (current == null) throw StateError('单据暂时无法读取，请重新查询。');
      setState(() {
        if (current.receivedCents != _sale.receivedCents) _imageStatus = '收款已更新，请保存最新图片';
        _sale = current;
      });
      if (updated != null) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('收款已保存')));
    } catch (_) {
      if (mounted) await _error(context, StateError('暂时无法刷新单据，请重新查询，不要重复登记收款。'));
    }
  }

  Future<void> _shareVersionCsv() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bundle = SalesCsvExporter.generate([_sale]);
      final dir = await getTemporaryDirectory();
      final prefix = '${_sale.number}-v${_sale.revision}';
      final orders = File('${dir.path}/$prefix-销售单.csv');
      final lines = File('${dir.path}/$prefix-销售明细.csv');
      await orders.writeAsString(bundle.orders, flush: true);
      await lines.writeAsString(bundle.lines, flush: true);
      await SharePlus.instance.share(ShareParams(files: [
        XFile(orders.path, mimeType: 'text/csv'), XFile(lines.path, mimeType: 'text/csv'),
      ], subject: '销售单 $prefix'));
    } catch (e) { if (mounted) await _error(context, e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _sharePdf() async {
    setState(() => _busy = true);
    try {
      await InvoicePdf.shareInvoice(_sale);
    } catch (e) { if (mounted) await _error(context, e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _shareImages() async {
    setState(() => _busy = true);
    try {
      final images = await InvoicePdf.images(_sale);
      final directory = await getTemporaryDirectory();
      final files = <XFile>[];
      for (var i = 0; i < images.length; i++) {
        final suffix = images.length == 1 ? '' : '-${i + 1}';
        final file = File('${directory.path}/${_sale.number}-v${_sale.revision}$suffix.png');
        await file.writeAsBytes(images[i], flush: true);
        files.add(XFile(file.path, mimeType: 'image/png'));
      }
      await SharePlus.instance.share(ShareParams(files: files, subject: '销售单 ${_sale.number}'));
    } catch (e) { if (mounted) await _error(context, e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final sale = _sale;
    final store = DatabaseScope.of(context);
    final FulfillmentStore? fulfillment =
      store is FulfillmentStore ? store as FulfillmentStore : null;
    final InventoryStore? inventory =
      store is InventoryStore ? store as InventoryStore : null;
    final SaleRevisionStore? revisions = store is SaleRevisionStore ? store as SaleRevisionStore : null;
    final CustomerCreditStore? creditStore = store is CustomerCreditStore ? store as CustomerCreditStore : null;
    return Scaffold(
      appBar: AppBar(title: const Text('销售单详情')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (widget.historical) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('历史版本 · 只读\n金额与收款为当时快照；保存图片也使用这个历史版本。'))),
        if (_savingImages) const Card(child: ListTile(title: Text('销售单已保存，正在保存图片…'))),
        if (widget.justSaved) const Card(child: ListTile(leading: Icon(Icons.check_circle_outline), title: Text('销售单保存成功'))),
        Center(child: Text('$_brand销售单', style: Theme.of(context).textTheme.headlineSmall)),
        const SizedBox(height: 10),
        Text('NO.${sale.number}'),
        Text('版本 ${sale.revision}${widget.historical ? '（历史快照，只读）' : '（当前有效）'}'),
        Text('客户：${sale.customerName}'),
        Text('销售日期：${sale.date}'),
        Text('合同金额 ¥${Fixed.format(sale.payableCents, decimals: 2)} · 未收 ¥${Fixed.format(sale.currentDueCents, decimals: 2)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        Card(child: ListTile(title: Text(_imageStatus))),
        FilledButton.icon(onPressed: _busy ? null : _saveImages, icon: const Icon(Icons.save_alt), label: Text(_savedImagePages.isEmpty ? '保存图片' : '重试未保存图片')),
        FilledButton.tonalIcon(onPressed: _busy ? null : _shareImages,
          icon: const Icon(Icons.image_outlined), label: const Text('分享销售单图片')),
        const SizedBox(height: 8),
        if (!widget.historical) OutlinedButton.icon(onPressed: _busy ? null : () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SaleEditorPage())), icon: const Icon(Icons.add), label: const Text('再开一单')),
        const SizedBox(height: 12),
        for (final line in sale.lines) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(line.code, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            if (line.specification.isNotEmpty) Text(line.specification),
            Text('米数 ${Fixed.format(line.lengthMilli, decimals: 3, trim: true)} 米 · 门幅 ${Fixed.format(line.widthMilli, decimals: 3, trim: true)} 米'),
            Text('面积 ${line.areaText} 平方米'),
            Text('单价 ¥${Fixed.format(line.unitPriceCents, decimals: 2)} /平方米'),
            Text('金额 ¥${Fixed.format(line.totalCents, decimals: 2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
          ]))),
        const SizedBox(height: 10),
        _total('产品合计', sale.subtotalCents),
        _total('优惠金额', sale.discountCents),
        _total('合同金额', sale.payableCents, emphasize: true),
        const Divider(height: 30),
        _total('已收款', sale.receivedCents),
        if (sale.transferredCents > 0) _total('本客户收款已转余额', sale.transferredCents),
        if (sale.refundedCents > 0) _total('本客户净实际退款', sale.refundedCents),
        _total('余额抵扣', sale.creditAppliedCents),
        if (sale.returnedLengthMilli > 0) Text('累计实物退货：${Fixed.format(sale.returnedLengthMilli, decimals: 3)} 米 / ${Fixed.format(sale.returnedAreaMicro, decimals: 6)} ㎡（独立于资金退款）'),
        if (sale.overpaidCents > 0) _total('超收待处理（未退款）', sale.overpaidCents),
        _total('本单未收', sale.currentDueCents, emphasize: true),
        _total('上期欠款（本版本客户快照）', sale.priorDueCents),
        if (!widget.historical) FutureBuilder<int>(
          future: DatabaseScope.of(context).customerOutstanding(sale.customerId),
          builder: (context, snapshot) => snapshot.hasData
            ? _total('客户当前总欠款', snapshot.data!, emphasize: true)
            : Text(snapshot.hasError ? '当前欠款查询失败' : '当前欠款查询中…'),
        ),
        const SizedBox(height: 10),
        if (sale.note.isNotEmpty) Text('备注：${sale.note}'),
        const SizedBox(height: 18),
        if (revisions != null && !widget.historical) ...[
          FutureBuilder<List<PendingSaleRefund>>(future: revisions.pendingSaleRefunds(sale.id),
            builder: (context, s) {
              if (s.hasError) return Text('待退款读取失败：${s.error}');
              if (!s.hasData) return const Text('待退款读取中…');
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final r in s.data!) ...[
                  Text('待退款：${r.customerName} · 归属段 ${r.epoch} · ¥${Fixed.format(r.amountCents, decimals: 2)}'),
                  if (creditStore != null) OutlinedButton(onPressed: _busy ? null : () => _transferCredit(r, creditStore),
                    child: Text('转入${r.customerName}余额 ¥${Fixed.format(r.amountCents, decimals: 2)}')),
                ],
                if (s.data!.isNotEmpty) const Text('可分次登记已实际退款，或将部分金额转入客户余额。'),
              ]);
            }),
          FutureBuilder<List<PendingSaleReturn>>(future: revisions.pendingSaleReturns(sale.id),
            builder: (context, s) {
              if (s.hasError) return Text('待退货读取失败：${s.error}');
              if (!s.hasData) return const Text('待退货读取中…');
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final r in s.data!) Text('待退货：${r.code} · 原行 ${r.saleLineId} · '
                  '${Fixed.format(r.lengthMilli, decimals: 3, trim: true)}米 / 门幅${Fixed.format(r.widthMilli, decimals: 3, trim: true)}米'),
                if (s.data!.isNotEmpty) const Text('请在“销售出库 / 关联实物退货”中选择原出库确认实际退回。'),
              ]);
            }),
        ],
        if (!widget.historical && store is RefundStore) FilledButton.tonalIcon(
          onPressed: _busy ? null : () async {
            setState(() => _busy = true);
            try {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => RefundPage(
                saleId: sale.id, store: store as RefundStore, sales: store)));
              final updated = await store.saleById(sale.id);
              if (updated == null) throw StateError('退款后销售单刷新失败');
              if (mounted) setState(() => _sale = updated);
            } catch (_) { if (context.mounted) await _error(context, StateError('退款后刷新失败，请重新查询，不要重复登记。')); }
            finally { if (mounted) setState(() => _busy = false); }
          }, icon: const Icon(Icons.currency_exchange), label: const Text('实际退款与冲销')),
        ExpansionTile(title: const Text('更多操作'), children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _sharePdf,
          icon: const Icon(Icons.share), label: const Text('分享 PDF')),
        OutlinedButton.icon(onPressed: _busy ? null : _shareVersionCsv,
          icon: const Icon(Icons.table_chart_outlined), label: const Text('分享本版本 CSV')),
        const SizedBox(height: 8),

        if (revisions != null && !widget.historical) ...[
          FilledButton.tonalIcon(onPressed: _busy ? null : _edit,
            icon: const Icon(Icons.edit_outlined), label: const Text('修改已确认销售单')),
          OutlinedButton.icon(onPressed: _busy ? null : () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => SaleRevisionHistoryPage(saleId: sale.id, store: revisions))),
            icon: const Icon(Icons.history), label: const Text('查看历史版本')),
        ],
        if (!widget.historical && creditStore != null) OutlinedButton.icon(
          onPressed: _busy ? null : () => Navigator.push(context, MaterialPageRoute(builder: (_) =>
            CustomerCreditPage(customerId: sale.customerId, store: creditStore))),
          icon: const Icon(Icons.account_balance_wallet_outlined), label: const Text('查看客户余额与明细')),
        if (!widget.historical) FilledButton.tonalIcon(onPressed: _busy || sale.currentDueCents == 0 ? null : _receive,
          icon: const Icon(Icons.payments), label: const Text('登记后续收款')),
        if (!widget.historical && fulfillment != null && inventory != null) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : () async {
              await Navigator.push(context, MaterialPageRoute(
              builder: (_) => SaleFulfillmentPage(
                saleId: sale.id, fulfillment: fulfillment, inventory: inventory)));
              if (!mounted) return;
              try {
                final refreshed = await store.saleById(sale.id);
                if (refreshed == null) throw StateError('销售单刷新失败');
                if (mounted) setState(() { _sale = refreshed; _imageStatus = '履约已刷新，请保存最新图片'; });
              } catch (e) { if (mounted) await _error(context, e); }
            },
            icon: const Icon(Icons.local_shipping_outlined),
            label: const Text('销售出库 / 关联实物退货')),
        ],
        ]),
        const SizedBox(height: 12),
        const Text('本单金额和客户信息以保存时快照为准；后续收款不会修改原始销售行。',
          style: TextStyle(color: Colors.grey)),
      ]),
    );
  }

  Widget _total(String label, int cents, {bool emphasize = false}) =>
    Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontWeight: emphasize ? FontWeight.bold : null))),
      Text('¥${Fixed.format(cents, decimals: 2)}',
        style: TextStyle(fontSize: emphasize ? 18 : 15,
          fontWeight: emphasize ? FontWeight.bold : null)),
    ]));
}

class SaleRevisionHistoryPage extends StatelessWidget {
  const SaleRevisionHistoryPage({super.key, required this.saleId, required this.store});
  final int saleId;
  final SaleRevisionStore store;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('销售单历史版本')),
    body: FutureBuilder<List<SaleRevisionRecord>>(future: store.saleRevisions(saleId),
      builder: (context, s) {
        if (s.hasError) return Center(child: Text('读取失败：${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        if (s.data!.isEmpty) return const Center(child: Text('尚无修改记录'));
        return ListView(children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('收款及待办为该版本保存时快照；原始版本在首次改单时归档。')),
          for (final r in s.data!) Card(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: InkWell(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) =>
              SaleDetailPage(sale: r.sale, historical: true))),
            child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('版本 ${r.sale.revision} · ${r.sale.customerName} · ¥${Fixed.format(r.sale.payableCents, decimals: 2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(r.createdAt),
              Text('金额差额 ¥${Fixed.format(r.amountDeltaCents, decimals: 2)}'),
              Text('待退款 ¥${Fixed.format(r.refunds.fold<int>(0, (n,f) => n + f.amountCents), decimals: 2)} · 待退货 ${r.returns.length}行'),
              const Text('查看此历史版本 ›'),
            ])))),

        ]);
      }),
  );
}
