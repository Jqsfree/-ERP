import 'package:flutter/material.dart';
import '../domain/money.dart';

/// Keeps the request and entered amount alive until the posting result is known.
class CreditTransferDialog extends StatefulWidget {
  const CreditTransferDialog({super.key, required this.customerName,
    required this.maximumCents, required this.post});
  final String customerName;
  final int maximumCents;
  final Future<void> Function(int amountCents, String requestKey) post;

  @override
  State<CreditTransferDialog> createState() => _CreditTransferDialogState();
}

class _CreditTransferDialogState extends State<CreditTransferDialog> {
  final _form = GlobalKey<FormState>();
  late final _amount = TextEditingController(
    text: Fixed.format(widget.maximumCents, decimals: 2));
  final _requestKey = 'credit-transfer-${DateTime.now().microsecondsSinceEpoch}';
  bool _busy = false;
  bool _attempted = false;
  String? _error;

  @override
  void dispose() { _amount.dispose(); super.dispose(); }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    final amount = Fixed.parse(_amount.text, decimals: 2);
    setState(() { _busy = true; _attempted = true; _error = null; });
    try {
      await widget.post(amount, _requestKey);
      if (mounted) { Navigator.pop(context, true); }
    } catch (e) {
      if (mounted) { setState(() {
        _error = e is StateError || e is ArgumentError || e is FormatException
          ? '$e' : '转入结果未能确认，请使用原请求重试，或关闭后刷新待退款与余额。';
      }); }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
      Text('待退款转余额', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 16),
      Form(key: _form, child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.customerName} · 可处理 ¥${Fixed.format(widget.maximumCents, decimals: 2)}'),
          const SizedBox(height: 16),
          TextFormField(controller: _amount, readOnly: _attempted,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            decoration: const InputDecoration(labelText: '转入金额（元，必填）'),
            validator: (value) {
              try {
                final cents = Fixed.parse(value ?? '', decimals: 2);
                if (cents <= 0 || cents > widget.maximumCents) return '金额须大于0且不超过可处理金额';
                return null;
              } catch (_) { return '请输入金额，最多两位小数'; }
            }),
          const SizedBox(height: 12),
          const Text('转入该客户可用余额，不发生现金退款。可分次转入，剩余金额继续待处理。'),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text('操作未完成：$_error'),
            const Text('重试沿用原金额与请求，避免重复入账；修改金额请关闭并刷新后重新操作。'),
          ],
        ])),
      const SizedBox(height: 16),
      Wrap(alignment: WrapAlignment.end, spacing: 12, runSpacing: 8, children: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('关闭')),
        FilledButton(onPressed: _busy ? null : _submit,
          child: Text(_busy ? '正在转入…' : _attempted ? '原请求重试' : '确认转入余额')),
      ]),
      ]))),
    ));
}
