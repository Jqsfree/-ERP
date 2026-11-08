import 'dart:math';
import 'package:flutter/material.dart';
import '../application/refund_store.dart';
import '../application/sales_store.dart';
import '../domain/finance.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../domain/sale_refund.dart';
import '../domain/sale_revision.dart';

class RefundPage extends StatefulWidget {
  const RefundPage({
    super.key,
    required this.saleId,
    required this.store,
    required this.sales,
  });
  final int saleId;
  final RefundStore store;
  final SalesStore sales;
  @override
  State<RefundPage> createState() => _RefundPageState();
}

class _RefundPageState extends State<RefundPage> {
  Sale? _sale;
  List<PendingSaleRefund> _pending = [];
  List<SaleRefundEvent> _events = [];
  RefundRequest? _request;
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool posted = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sale = await widget.sales.saleById(widget.saleId);
      if (sale == null) throw StateError('找不到销售单');
      final pending = await widget.store.pendingSaleRefunds(widget.saleId);
      final events = await widget.store.saleRefundEvents(widget.saleId);
      final request = await widget.store.latestRefundRequest(widget.saleId);
      if (mounted) {
        setState(() {
          _sale = sale;
          _pending = pending;
          _events = events;
          _request = request;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error =
                  posted
                      ? '已经入账，但刷新失败。请重试查询，避免重复登记。'
                      : '退款结果查询失败，请重试查询，暂不新增登记。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry() async {
    if (_busy || _request == null) return;
    setState(() => _busy = true);
    var posted = false;
    try {
      await widget.store.postRefundRequest(_request!.key);
      posted = true;
    } catch (e) {
      if (mounted) setState(() => _error = '原请求尚未确认入账：$e。请查询原请求，勿重新登记。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (posted && mounted) await _load(posted: true);
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('取消未入账请求？'),
            content: const SingleChildScrollView(
              child: Text(
                '只取消本软件尚未入账的请求，不撤回实际转账。已退款的钱仍须登记。若原请求已入账，系统会拒绝取消，请重新查询。',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('保留请求'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('取消未入账请求'),
              ),
            ],
          ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.store.cancelRefundRequest(_request!.key);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  Future<void> _edit({
    PendingSaleRefund? source,
    SaleRefundEvent? original,
  }) async {
    if (_busy || _error != null || _sale == null) return;
    final posted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (_) => _RefundDialog(
            sale: _sale!,
            store: widget.store,
            source: source,
            original: original,
          ),
    );
    if (!mounted) return;
    await _load(posted: posted == true);
  }

  @override
  Widget build(BuildContext context) {
    final canPost = !_busy && _error == null && _request?.status != 'pending';
    final reversed =
        _events.where((e) => e.isReversal).map((e) => e.originalId).toSet();
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('实际退款与冲销')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('此处只登记已经实际退回客户的钱，不执行转账。实物退货须另行登记。'),
            if (_sale != null) ...[
              Text('单号：${_sale!.number} · 版本${_sale!.revision}'),
              Text('当前客户：${_sale!.customerName}'),
              Text(
                '当前客户归属段净退款 ¥${Fixed.format(_sale!.refundedCents, decimals: 2)}',
                style: const TextStyle(fontSize: 22),
              ),
            ],
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text(_error!),
            OutlinedButton(
              onPressed: _busy ? null : () => _load(),
              child: const Text('重新查询退款结果'),
            ),
            if (_request != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '最近请求：${_request!.kind == 'refund' ? '退款' : '冲销'} · ${_request!.status == 'posted'
                            ? '已入账'
                            : _request!.status == 'pending'
                            ? '未确认入账'
                            : '已取消'}',
                      ),
                      SelectableText(_request!.key),
                      if (_request!.status == 'pending') ...[
                        Text(
                          _request!.kind == 'refund'
                              ? '原请求金额 ¥${Fixed.format(_request!.payload['amountCents'] as int, decimals: 2)} · ${_request!.payload['method']}'
                              : '原退款记录 #${_request!.payload['originalEventId']} · ${_request!.payload['reason']}',
                        ),
                        FilledButton(
                          onPressed: _busy ? null : _retry,
                          child: const Text('重试原请求'),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : _cancel,
                          child: const Text('取消未入账请求'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            const Text('待退款来源', style: TextStyle(fontSize: 22)),
            if (_pending.isEmpty && !_busy && _error == null)
              const Text('暂无待处理退款'),
            for (final p in _pending)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${p.customerName} · 归属段${p.epoch}'),
                      Text(
                        '剩余可处理 ¥${Fixed.format(p.amountCents, decimals: 2)}',
                        style: const TextStyle(fontSize: 22),
                      ),
                      FilledButton(
                        onPressed: canPost ? () => _edit(source: p) : null,
                        child: const Text('登记已实际退款'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            const Text('退款与冲销记录（保留原记录）', style: TextStyle(fontSize: 22)),
            if (_events.isEmpty && !_busy) const Text('暂无实际退款记录'),
            for (final e in _events)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '#${e.id} ${e.isReversal
                            ? '退款冲销 · 原记录 #${e.originalId}'
                            : reversed.contains(e.id)
                            ? '实际退款（已冲销）'
                            : '实际退款'}',
                      ),
                      Text(
                        '¥${Fixed.format(e.amountCents, decimals: 2)} · ${e.method}',
                        style: const TextStyle(fontSize: 22),
                      ),
                      Text(
                        '${e.customerName} · 归属段${e.epoch} · 操作版本${e.version}',
                      ),
                      Text(e.createdAt),
                      if (e.reason.isNotEmpty) Text('说明：${e.reason}'),
                      if (e.closed && !e.isReversal)
                        const Text('退款日期已日结，禁止直接冲销'),
                      if (!e.closed &&
                          !e.isReversal &&
                          !reversed.contains(e.id))
                        OutlinedButton(
                          onPressed: canPost ? () => _edit(original: e) : null,
                          child: const Text('冲销误登记退款'),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RefundDialog extends StatefulWidget {
  const _RefundDialog({
    required this.sale,
    required this.store,
    this.source,
    this.original,
  });
  final Sale sale;
  final RefundStore store;
  final PendingSaleRefund? source;
  final SaleRefundEvent? original;
  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  final _key =
      'refund-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  String _method = '微信';
  bool _confirmed = false, _busy = false, _attempted = false;
  String? _error;
  bool get reversal => widget.original != null;
  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (!_confirmed) {
      setState(() => _error = reversal ? '请确认误登记或退款资金已经收回' : '请确认资金已经实际退给客户');
      return;
    }
    setState(() {
      _busy = true;
      _attempted = true;
      _error = null;
    });
    try {
      if (reversal) {
        await widget.store.prepareRefundReversal(
          originalEventId: widget.original!.id,
          reason: _reason.text,
          fundsRecoveredOrMistake: true,
          requestKey: _key,
        );
      } else {
        await widget.store.prepareSaleRefund(
          saleId: widget.sale.id,
          expectedRevision: widget.sale.revision,
          customerId: widget.source!.customerId,
          epoch: widget.source!.epoch,
          amountCents: Fixed.parse(_amount.text, decimals: 2),
          method: _method,
          requestKey: _key,
          note: _reason.text,
        );
      }
      await widget.store.postRefundRequest(_key);
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '结果尚未确认：$e。可原请求重试，关闭后也可查询原请求，勿重复登记。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reversal ? '冲销退款（保留原记录）' : '登记已经实际退款',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Text(
                  reversal
                      ? '${widget.original!.customerName} · 原退款 #${widget.original!.id} · ¥${Fixed.format(widget.original!.amountCents, decimals: 2)} · ${widget.original!.method}'
                      : '${widget.source!.customerName} · 归属段${widget.source!.epoch}\n最多 ¥${Fixed.format(widget.source!.amountCents, decimals: 2)}',
                ),
                if (!reversal) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _amount,
                    readOnly: _attempted,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '已实际退款金额（元，必填）',
                    ),
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    validator: (v) {
                      try {
                        final n = Fixed.parse(v ?? '', decimals: 2);
                        return n <= 0 || n > widget.source!.amountCents
                            ? '金额须大于0且不超过可处理金额'
                            : null;
                      } catch (_) {
                        return '请输入金额，最多两位小数';
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _method,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '实际退款渠道'),
                    items:
                        FinanceMath.methods
                            .map(
                              (m) => DropdownMenuItem(value: m, child: Text(m)),
                            )
                            .toList(),
                    onChanged:
                        _attempted ? null : (v) => setState(() => _method = v!),
                  ),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  controller: _reason,
                  readOnly: _attempted,
                  maxLines: 3,
                  maxLength: 500,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  decoration: InputDecoration(
                    labelText: reversal ? '冲销原因（必填）' : '退款备注（可选）',
                  ),
                  validator:
                      (v) =>
                          reversal && (v ?? '').trim().isEmpty
                              ? '请填写冲销原因'
                              : null,
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _confirmed,
                  onChanged:
                      _attempted
                          ? null
                          : (v) => setState(() => _confirmed = v!),
                  title: Text(
                    reversal ? '确认原记录为误登记，或退款资金已经收回' : '确认这笔钱已经实际退给该客户；此操作不会转账',
                  ),
                ),
                if (_error != null) Text(_error!),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed:
                          _busy ? null : () => Navigator.pop(context, false),
                      child: const Text('关闭'),
                    ),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(
                        _busy
                            ? '正在登记…'
                            : _attempted
                            ? '原请求重试'
                            : reversal
                            ? '确认冲销退款'
                            : '确认登记实际退款',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
