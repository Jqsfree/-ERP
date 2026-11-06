import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'database_scope.dart';
import 'backup_page.dart';
import '../application/backup_store.dart';
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

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = DatabaseScope.of(context);
    final BackupStore? backupStore = store is BackupStore ? store as BackupStore : null;
    final tiles = <({String name, IconData icon, VoidCallback? action})>[
      (name: '销售', icon: Icons.receipt_long, action: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SaleEditorPage()))),
      (name: '采购', icon: Icons.shopping_cart, action: null),
      (name: '客户', icon: Icons.people_alt, action: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CustomersPage()))),
      (name: '供应商', icon: Icons.local_shipping, action: null),
      (name: '产品', icon: Icons.inventory_2, action: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProductsPage()))),
      (name: '库存', icon: Icons.warehouse, action: null),
      (name: '退货', icon: Icons.swap_horiz, action: null),
      (name: '费用收入', icon: Icons.account_balance_wallet, action: null),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('$_brand · 开单管理'), actions: [
        if (backupStore != null)
          IconButton(tooltip: '数据备份与恢复', icon: const Icon(Icons.backup_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => BackupPage(store: backupStore)))),
        IconButton(tooltip: '销售记录', icon: const Icon(Icons.history),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SalesPage()))),
      ]),
      body: Column(children: [
        const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Card(child: ListTile(
            leading: Icon(Icons.offline_bolt_outlined),
            title: Text('单机离线开单 · v0.1'),
            subtitle: Text('先录入客户和产品，再创建销售出货单。数据保存在本机。'),
          ))),
        Expanded(child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, childAspectRatio: 1.2, crossAxisSpacing: 12, mainAxisSpacing: 12),
          itemCount: tiles.length,
          itemBuilder: (context, i) {
            final tile = tiles[i];
            return Card(color: tile.action == null ? Theme.of(context).colorScheme.surfaceContainer : null,
              child: InkWell(borderRadius: BorderRadius.circular(12),
                onTap: tile.action ?? () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('此模块在第二阶段实现；首版优先保证开单与收款准确。'))),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(tile.icon, size: 38, color: tile.action == null ? Colors.grey : Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12), Text(tile.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  if (tile.action == null) const Padding(padding: EdgeInsets.only(top: 4),
                    child: Text('规划中', style: TextStyle(fontSize: 12, color: Colors.grey))),
                ])),
            );
          },
        )),
      ]),
    );
  }
}

class CustomersPage extends StatefulWidget {
  const CustomersPage({super.key});
  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  late Future<List<Customer>> _items;
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
    final database = DatabaseScope.of(context);
    final formKey = GlobalKey<FormState>();
    var name = '';
    var phone = '';
    var address = '';
    var balance = '0';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增客户'),
        content: SizedBox(width: 380, child: Form(
          key: formKey,
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                decoration: const InputDecoration(labelText: '客户名称 *'),
                onChanged: (v) => name = v,
                validator: (v) => v == null || v.trim().isEmpty ? '必填' : null),
              const SizedBox(height: 12),
              TextFormField(
                decoration: const InputDecoration(labelText: '联系电话'),
                onChanged: (v) => phone = v),
              const SizedBox(height: 12),
              TextFormField(
                decoration: const InputDecoration(labelText: '收货地址'),
                onChanged: (v) => address = v),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: '0',
                decoration: const InputDecoration(labelText: '初始欠款（元）'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (v) => balance = v),
            ],
          )),
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              try {
                await database.addCustomer(Customer(
                  name: name, phone: phone, address: address,
                  openingBalanceCents: Fixed.parse(balance, decimals: 2),
                ));
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) await _error(ctx, e);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true && mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('客户管理')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('新增客户')),
    body: FutureBuilder<List<Customer>>(future: _items, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Text('读取失败：${snapshot.error}'));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.data!.isEmpty) return const Center(child: Text('暂无客户，请点击「新增客户」'));
      return ListView.builder(itemCount: snapshot.data!.length, itemBuilder: (context, i) {
        final c = snapshot.data![i];
        return ListTile(title: Text(c.name), subtitle: Text('${c.phone}  ${c.address}'),
          trailing: FutureBuilder<int>(future: DatabaseScope.of(context).customerOutstanding(c.id!),
            builder: (context, s) => Text(s.hasData ? '欠款 ¥${Fixed.format(s.data!, decimals: 2)}' : '…')));
      });
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
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = DatabaseScope.of(context).products();
  }
  void _refresh() {
    final pending = DatabaseScope.of(context).products();
    setState(() { _items = pending; });
  }

  Future<void> _create() async {
    final database = DatabaseScope.of(context);
    final formKey = GlobalKey<FormState>();
    var code = '';
    var spec = '';
    var price = '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增产品'),
        content: SizedBox(width: 380, child: Form(
          key: formKey,
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                decoration: const InputDecoration(labelText: '产品型号 *'),
                onChanged: (v) => code = v,
                validator: (v) => v == null || v.trim().isEmpty ? '必填' : null),
              const SizedBox(height: 12),
              TextFormField(
                decoration: const InputDecoration(labelText: '规格型号（可空）'),
                onChanged: (v) => spec = v),
              const SizedBox(height: 12),
              TextFormField(
                decoration: const InputDecoration(labelText: '默认单价（元/平方米）*'),
                onChanged: (v) => price = v,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) => v == null || v.isEmpty ? '必填' : null),
            ],
          )),
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              try {
                await database.addProduct(Product(
                  code: code, specification: spec,
                  unitPriceCents: Fixed.parse(price, decimals: 2),
                ));
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) await _error(ctx, e);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true && mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('产品管理')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('新增产品')),
    body: FutureBuilder<List<Product>>(future: _items, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Text('读取失败：${snapshot.error}'));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      if (snapshot.data!.isEmpty) return const Center(child: Text('暂无产品，请点击「新增产品」'));
      return ListView.builder(itemCount: snapshot.data!.length, itemBuilder: (context, i) {
        final p = snapshot.data![i];
        return ListTile(title: Text(p.code), subtitle: Text(p.specification),
          trailing: Text('¥${Fixed.format(p.unitPriceCents, decimals: 2)}/㎡'));
      });
    }),
  );
}

class _LineForm {
  _LineForm();
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
  const SaleEditorPage({super.key});
  @override
  State<SaleEditorPage> createState() => _SaleEditorPageState();
}

class _SaleEditorPageState extends State<SaleEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _discount = TextEditingController(text: '0');
  final _received = TextEditingController(text: '0');
  final _note = TextEditingController();
  final _lines = <_LineForm>[_LineForm()];
  List<Customer> _customers = [];
  List<Product> _products = [];
  int? _customerId;
  bool _saving = false;
  bool _loading = true;
  Timer? _draftDebounce;
  Future<void> _draftWrites = Future<void>.value();

  String _draftPayload() => jsonEncode({
    'schema': 1, 'customerId': _customerId, 'discount': _discount.text,
    'received': _received.text, 'note': _note.text,
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
    if (_loading || _saving) return;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 650), () {
      if (!mounted || _saving) return;
      unawaited(_persistDraft().catchError((Object e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('草稿保存失败：$e')));
      }));
    });
  }

  Future<void> _saveDraftNow() async {
    _draftDebounce?.cancel();
    try {
      await _persistDraft();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿已写入本机数据库')));
    } catch (e) {
      if (mounted) await _error(context, e);
    }
  }

  void _restoreDraft(String raw, List<Customer> customers) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
      throw const FormatException('草稿格式版本不兼容');
    }
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
      final customers = await database.customers();
      final products = await database.products();
      final draft = await database.loadDraft();
      if (!mounted) return;
      var draftError = false;
      if (draft != null) {
        try { _restoreDraft(draft, customers); }
        catch (e) {
          draftError = true;
          debugPrint('Draft recovery failed; original retained in SQLite: $e');
        }
      }
      setState(() { _customers = customers; _products = products; _loading = false; });
      if (draftError && mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿无法解析，原始数据已保留在本机')));
    } catch (e) { if (mounted) { setState(() => _loading = false); await _error(context, e); } }
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _discount.dispose(); _received.dispose(); _note.dispose();
    for (final line in _lines) { line.dispose(); }
    super.dispose();
  }

  int? get _subtotal {
    try {
      return _lines.fold<int>(0, (sum, input) => sum + input.toLine().totalCents);
    } catch (_) { return null; }
  }

  void _removeLine(int index) {
    if (_lines.length == 1) return;
    final removed = _lines.removeAt(index);
    setState(() {});
    _touchDraft();
    // Keep the text controllers alive until the current frame is detached.
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_customerId == null) { await _error(context, ArgumentError('请先选择客户')); return; }
    setState(() => _saving = true);
    _draftDebounce?.cancel();
    final database = DatabaseScope.of(context);
    try {
      await _draftWrites;
      final customer = _customers.firstWhere((c) => c.id == _customerId);
      final id = await database.createSale(
        customer: customer, lines: _lines.map((e) => e.toLine()).toList(),
        discountCents: Fixed.parse(_discount.text, decimals: 2),
        initialReceivedCents: Fixed.parse(_received.text, decimals: 2),
        note: _note.text,
      );
      final sale = await database.saleById(id);
      if (!mounted) return;
      if (sale == null) {
        Navigator.pop(context);
        return;
      }
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => SaleDetailPage(sale: sale)));
    } catch (e) { if (mounted) await _error(context, e); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('新建销售出货单')),
    body: _loading ? const Center(child: CircularProgressIndicator()) :
      Form(key: _formKey, child: ListView(padding: const EdgeInsets.all(16), children: [
        if (_customers.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(12),
          child: Text('尚无客户。请返回首页先新增客户。'))),
        DropdownButtonFormField<int>(
          initialValue: _customerId,
          decoration: const InputDecoration(labelText: '客户 *'),
          items: _customers.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
          onChanged: (value) {
            setState(() => _customerId = value);
            _touchDraft();
          },
          validator: (value) => value == null ? '请选择客户' : null,
        ),
        const SizedBox(height: 12),
        Text('销售日期：${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}',
          style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        for (var i = 0; i < _lines.length; i++) _lineCard(i),
        OutlinedButton.icon(onPressed: () {
          setState(() => _lines.add(_LineForm()));
          _touchDraft();
        }, icon: const Icon(Icons.add), label: const Text('新增一行产品')),
        const SizedBox(height: 16),
        Text('产品金额：${_subtotal == null ? '请输入有效数量、门幅和单价' : '¥${Fixed.format(_subtotal!, decimals: 2)}'}',
          style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextFormField(controller: _discount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '优惠金额（元）'),
          onChanged: (_) { setState(() {}); _touchDraft(); }),
        const SizedBox(height: 12),
        TextFormField(controller: _received, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: '开单已收款（元）'),
          onChanged: (_) => _touchDraft()),
        const SizedBox(height: 12),
        TextFormField(controller: _note, decoration: const InputDecoration(labelText: '订单备注'),
          maxLines: 2, onChanged: (_) => _touchDraft()),
        const SizedBox(height: 14),
        if (_subtotal != null) Builder(builder: (context) {
          try {
            return Text('合同金额：¥${Fixed.format(BillingMath.payable(_subtotal!, Fixed.parse(_discount.text, decimals: 2)), decimals: 2)}',
              style: Theme.of(context).textTheme.titleLarge);
          } catch (_) { return const Text('请检查优惠金额'); }
        }),
        const SizedBox(height: 20),
        OutlinedButton.icon(onPressed: _saving ? null : _saveDraftNow,
          icon: const Icon(Icons.save_outlined), label: const Text('立即保存草稿')),
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: _saving ? null : _save,
          icon: const Icon(Icons.check_circle_outline),
          label: Padding(padding: const EdgeInsets.all(12), child: Text(_saving ? '保存中…' : '确认销售并保存'))),
        const Padding(padding: EdgeInsets.only(top: 12),
          child: Text('输入停顿约 650ms 自动保存 SQLite 草稿；正式保存才生成订单。当前版本不扣库存。',
            style: TextStyle(color: Colors.grey))),
        const SizedBox(height: 30),
      ])),
  );

  Widget _lineCard(int index) {
    final input = _lines[index];
    return Card(margin: const EdgeInsets.only(bottom: 12), child: Padding(
      padding: const EdgeInsets.all(12), child: Column(children: [
        Row(children: [
          Text('产品 ${index + 1}', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          IconButton(onPressed: () => _removeLine(index), icon: const Icon(Icons.delete_outline),
            tooltip: '删除本行'),
        ]),
        if (_products.isNotEmpty) DropdownButtonFormField<int>(
          initialValue: input.productId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '从产品库选择（可选）'),
          items: _products.map((p) => DropdownMenuItem(value: p.id, child: Text(p.code))).toList(),
          onChanged: (id) {
            if (id == null) return;
            setState(() => input.useProduct(_products.firstWhere((p) => p.id == id)));
            _touchDraft();
          },
        ),
        const SizedBox(height: 10),
        TextFormField(controller: input.code, decoration: const InputDecoration(labelText: '产品型号 *'),
          validator: (v) => v == null || v.trim().isEmpty ? '必填' : null,
          onChanged: (_) => _touchDraft()),
        const SizedBox(height: 10),
        TextField(controller: input.spec, decoration: const InputDecoration(labelText: '规格型号'),
          onChanged: (_) => _touchDraft()),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _amountInput(input.length, '米数 *')),
          const SizedBox(width: 8),
          Expanded(child: _amountInput(input.width, '门幅 *')),
        ]),
        const SizedBox(height: 10),
        _amountInput(input.price, '单价（元/㎡）*'),
        const SizedBox(height: 10),
        TextField(controller: input.note, decoration: const InputDecoration(labelText: '本行备注'),
          onChanged: (_) => _touchDraft()),
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
    decoration: InputDecoration(labelText: label),
    onChanged: (_) { setState(() {}); _touchDraft(); },
    validator: (value) => value == null || value.trim().isEmpty ? '必填' : null,
  );
}

class SalesPage extends StatefulWidget {
  const SalesPage({super.key});
  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  late Future<List<Sale>> _items;
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
    appBar: AppBar(title: const Text('销售记录'), actions: [
      IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: '刷新'),
    ]),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const SaleEditorPage()));
        _refresh();
      }, icon: const Icon(Icons.add), label: const Text('新开单')),
    body: FutureBuilder<List<Sale>>(future: _items, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Text('读取失败：${snapshot.error}'));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      final sales = snapshot.data!;
      if (sales.isEmpty) return const Center(child: Text('暂无销售记录'));
      return Column(children: [
        ListTile(title: Text('共 ${sales.length} 单'),
          trailing: TextButton.icon(onPressed: () async {
            try { await _exportCsv(sales); } catch (e) { if (context.mounted) await _error(context, e); }
          }, icon: const Icon(Icons.table_view), label: const Text('导出订单与明细 CSV'))),
        Expanded(child: ListView.builder(itemCount: sales.length, itemBuilder: (ctx, i) {
          final sale = sales[i];
          return ListTile(
            title: Text('${sale.customerName} · ¥${Fixed.format(sale.payableCents, decimals: 2)}'),
            subtitle: Text('${sale.number}  ${sale.date}'),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [const Text('未收'), Text('¥${Fixed.format(sale.currentDueCents, decimals: 2)}',
                style: const TextStyle(fontWeight: FontWeight.bold))]),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleDetailPage(sale: sale)));
              _refresh();
            },
          );
        })),
      ]);
    }),
  );
}

class SaleDetailPage extends StatefulWidget {
  final Sale sale;
  const SaleDetailPage({super.key, required this.sale});
  @override
  State<SaleDetailPage> createState() => _SaleDetailPageState();
}

class _SaleDetailPageState extends State<SaleDetailPage> {
  late Sale _sale = widget.sale;
  bool _busy = false;

  Future<void> _receive() async {
    final database = DatabaseScope.of(context);
    var amount = Fixed.format(_sale.currentDueCents, decimals: 2);
    var method = '微信';
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) =>
      AlertDialog(
        title: const Text('登记收款'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('本单剩余未收：¥${Fixed.format(_sale.currentDueCents, decimals: 2)}'),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: amount,
            onChanged: (v) => amount = v,
            decoration: const InputDecoration(labelText: '本次收款金额（元）'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: '微信',
            items: const ['微信', '支付宝', '现金', '银行转账', '其他']
              .map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (v) { if (v != null) method = v; },
            decoration: const InputDecoration(labelText: '收款方式'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认收款')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await database.addPayment(_sale, Fixed.parse(amount, decimals: 2), method: method);
      final updated = await database.saleById(_sale.id);
      if (updated == null) throw StateError('收款已入账，但刷新单据失败，请检查历史记录');
      if (mounted) {
        setState(() => _sale = updated);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('收款已保存')));
      }
    } catch (e) {
      if (mounted) await _error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print(bool share) async {
    setState(() => _busy = true);
    try {
      if (share) { await InvoicePdf.shareInvoice(_sale); }
      else { await InvoicePdf.printInvoice(_sale); }
    } catch (e) { if (mounted) await _error(context, e); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) {
    final sale = _sale;
    return Scaffold(
      appBar: AppBar(title: const Text('销售出货单详情')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(child: Text('$_brand销售出货单', style: Theme.of(context).textTheme.headlineSmall)),
        const SizedBox(height: 10),
        Text('NO.${sale.number}'),
        Text('客户：${sale.customerName}'),
        Text('销售日期：${sale.date}'),
        const SizedBox(height: 12),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
          columns: const [DataColumn(label: Text('型号')), DataColumn(label: Text('米数')),
            DataColumn(label: Text('门幅')), DataColumn(label: Text('总数量')),
            DataColumn(label: Text('单价')), DataColumn(label: Text('金额'))],
          rows: sale.lines.map((line) => DataRow(cells: [
            DataCell(Text(line.code)),
            DataCell(Text(Fixed.format(line.lengthMilli, decimals: 3, trim: true))),
            DataCell(Text(Fixed.format(line.widthMilli, decimals: 3, trim: true))),
            DataCell(Text(line.areaText)),
            DataCell(Text(Fixed.format(line.unitPriceCents, decimals: 2))),
            DataCell(Text(Fixed.format(line.totalCents, decimals: 2))),
          ])).toList(),
        )),
        const SizedBox(height: 10),
        _total('产品合计', sale.subtotalCents),
        _total('优惠金额', sale.discountCents),
        _total('合同金额', sale.payableCents, emphasize: true),
        const Divider(height: 30),
        _total('已收款', sale.receivedCents),
        _total('本单未收', sale.currentDueCents, emphasize: true),
        _total('上期欠款（开单时）', sale.priorDueCents),
        FutureBuilder<int>(
          future: DatabaseScope.of(context).customerOutstanding(sale.customerId),
          builder: (context, snapshot) => snapshot.hasData
            ? _total('客户当前总欠款', snapshot.data!, emphasize: true)
            : Text(snapshot.hasError ? '当前欠款查询失败' : '当前欠款查询中…'),
        ),
        const SizedBox(height: 10),
        if (sale.note.isNotEmpty) Text('备注：${sale.note}'),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: FilledButton.icon(
            onPressed: _busy ? null : () => _print(false),
            icon: const Icon(Icons.print), label: const Text('打印 PDF'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _print(true),
            icon: const Icon(Icons.share), label: const Text('分享 PDF'))),
        ]),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(onPressed: _busy || sale.currentDueCents == 0 ? null : _receive,
          icon: const Icon(Icons.payments), label: const Text('登记后续收款')),
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
