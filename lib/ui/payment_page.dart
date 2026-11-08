import 'dart:math';
import 'package:flutter/material.dart';
import '../application/sales_store.dart';
import '../application/payment_request_store.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/payment_request.dart';

class PaymentPage extends StatefulWidget {
  const PaymentPage({super.key, required this.sale, required this.store});
  final Sale sale;
  final SalesStore store;
  @override State<PaymentPage> createState() => _PaymentPageState();
}
class _PaymentPageState extends State<PaymentPage> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  late Sale _sale = widget.sale;
  String _method = '微信';
  static String _newKey() => 'payment-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  String _key = _newKey();
  PaymentRequest? _request;
  bool _busy = true;
  bool _posted = false;
  bool _exit = false;
  String? _error;
  PaymentRequestStore get _requests => widget.store as PaymentRequestStore;
  @override void initState() { super.initState(); _recover(); }
  @override void dispose() { _amount.dispose(); super.dispose(); }

  Future<void> _recover() async {
    setState(() { _busy = true; _error = null; });
    try {
      final request = await _requests.latestPaymentRequest(_sale.id);
      final current = await widget.store.saleById(_sale.id);
      if (current == null) throw StateError('找不到销售单');
      if (!mounted) return;
      setState(() {
        _sale = current;
        _request = request;
        _posted = request?.status == 'posted';
        if (request != null) {
          _key = request.key; _method = request.method;
          _amount.text = Fixed.format(request.amountCents, decimals: 2);
        }
      });
    } catch (_) { if (mounted) setState(() => _error = '无法确认上次收款结果，请重试查询，暂不登记新收款。'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _leave() async {
    if (_busy) return;
    if (!_posted && _amount.text.isNotEmpty) {
      final leave = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('离开收款页面？'),
        content: Text(_request == null ? '尚未登记，本次输入将放弃。原单据不会改变。' : '未完成收款请求已保留，下次进入会先查询结果，不会自动重复入账。'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('继续填写')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('返回单据'))]));
      if (leave != true) return;
    }
    if (!mounted) return;
    setState(() => _exit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) Navigator.pop(context, _posted ? _sale : null); });
  }

  Future<void> _newPayment() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_request?.status == 'pending') await _requests.cancelPaymentRequest(_key);
      final current = await widget.store.saleById(_sale.id);
      if (current == null) throw StateError('找不到销售单');
      if (!mounted) return;
      setState(() {
        _sale = current; _request = null; _posted = false;
        _key = _newKey(); _amount.clear(); _error = null;
      });
    } catch (_) { if (mounted) setState(() => _error = '无法确认原请求状态，请重新查询，勿重复登记。'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_posted && !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() { _busy = true; _error = null; });
    try {
      if (!_posted) {
        final current = await widget.store.saleById(_sale.id);
        if (current == null) throw StateError('找不到销售单，请返回重新查询。');
        if (_request != null && _request!.revision != current.revision) throw StateError('单据版本已变化，请取消未入账请求后重新填写。');
        final cents = Fixed.parse(_amount.text, decimals: 2);
        if (current.revision != _sale.revision || current.currentDueCents != _sale.currentDueCents) {
          setState(() => _sale = current);
          throw StateError('单据金额已变化，请核对最新未收后再次确认。');
        }
        if (!mounted) return;
        final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('核对本次收款'),
          content: SingleChildScrollView(child: Text('客户：${_sale.customerName}\n单号：${_sale.number}\n本次收到：¥${Fixed.format(cents, decimals: 2)}\n收款方式：$_method\n登记后未收：¥${Fixed.format(_sale.currentDueCents - cents, decimals: 2)}\n请确认款项已经实际收到。')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回修改')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认收款'))]));
        if (confirmed != true) return;
        _request = await _requests.preparePayment(current, cents, requestKey: _key, method: _method);
        if (_request!.status != 'posted') {
          await widget.store.addPayment(current, cents, requestKey: _key, method: _method);
        }
        _posted = true;
      }
      final updated = await widget.store.saleById(_sale.id);
      if (updated == null) throw StateError('暂时无法读取单据');
      if (!mounted) return;
      setState(() { _sale = updated; _exit = true; });
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) Navigator.pop(context, updated); });
    } catch (e) {
      // A plugin can lose its response after SQLite committed. Resolve the
      // durable key before enabling another attempt; keep its payload locked.
      try {
        final latest = await _requests.latestPaymentRequest(_sale.id);
        if (latest?.key == _key) { _request = latest; _posted = latest?.status == 'posted'; }
      } catch (_) { /* Existing key is retained even when the query fails. */ }
      if (mounted) { setState(() => _error = _posted
        ? '收款已入账，单据刷新失败。请重试刷新，不要重复收款。'
        : e is StateError ? e.message.toString() : '收款未完成，请核对单据和金额后重试。输入已保留。'); }
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override Widget build(BuildContext context) => PopScope(canPop: _exit,
    onPopInvokedWithResult: (didPop, result) { if (!didPop) _leave(); }, child: Scaffold(
      appBar: AppBar(leadingWidth: 92, leading: TextButton(onPressed: _busy ? null : _leave, child: const Text('返回')), title: const Text('登记收款')),
      body: AbsorbPointer(absorbing: _busy || _request != null || _posted, child: Form(key: _form, child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('客户：${_sale.customerName}'), Text('单号：${_sale.number}'),
        Text('本单剩余未收：¥${Fixed.format(_sale.currentDueCents, decimals: 2)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        if (_request != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(_posted ? '上次收款已入账，请勿重复登记。下面显示的是上次收款。' : '已恢复未完成收款，请先核对结果。金额与渠道已锁定，可重试或取消未入账请求。'))),
        const SizedBox(height: 20),
        TextFormField(controller: _amount, decoration: const InputDecoration(labelText: '本次收款金额（元）', helperText: '填写这一次实际收到的钱'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true), autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (v) { if (_posted) return null; try {
            final n = Fixed.parse(v ?? '', decimals: 2);
            if (n <= 0) return '收款金额必须大于0';
            if (n > _sale.currentDueCents) return '不能超过本单剩余未收';
            return null;
          } on FormatException catch (e) { return e.message; } }),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(key: ValueKey(_method), initialValue: _method, isExpanded: true,
          decoration: const InputDecoration(labelText: '收款方式'), items: ['微信','支付宝','现金','银行转账','其他'].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
          onChanged: (v) { if (v != null) _method = v; }),
        const SizedBox(height: 20), const Text('登记成功后不会自动另存图片，可返回单据详情保存最新图片。'),
      ]))),
      bottomNavigationBar: SafeArea(child: Padding(padding: EdgeInsets.fromLTRB(16,8,16,8 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (_request != null) OutlinedButton(onPressed: _busy ? null : _newPayment,
            child: Text(_posted ? '登记另一笔收款' : '取消未入账请求并重填')),
          FilledButton(onPressed: _busy ? null : (_error?.startsWith('无法确认') == true ? _recover : _submit),
            child: Text(_busy ? '处理中…' : _error?.startsWith('无法确认') == true ? '重新查询收款结果' : _posted ? '刷新并返回单据' : '核对收款')),
        ]))),
    ));
}
