import 'package:flutter/material.dart';
import '../application/data_integrity_store.dart';

class DataIntegrityPage extends StatefulWidget {
  const DataIntegrityPage({super.key, required this.store});
  final DataIntegrityStore store;
  @override State<DataIntegrityPage> createState() => _DataIntegrityPageState();
}
class _DataIntegrityPageState extends State<DataIntegrityPage> {
  late Future<List<String>> _result = widget.store.checkDataIntegrity();
  void _retry() => setState(() => _result = widget.store.checkDataIntegrity());
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('数据检查')),
    body: FutureBuilder<List<String>>(future: _result, builder: (context, s) {
      if (s.hasError) return Center(child: TextButton(onPressed: _retry, child: const Text('检查未完成，点击重试')));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Text('只检查金额、关联、余额和当前库存商品标识，不修改原单据。'),
        const SizedBox(height: 16),
        if (s.data!.isEmpty) const Text('本次检查未发现异常。仍需定期备份并核对实际收付款。'),
        for (final issue in s.data!) Card(child: Padding(padding: const EdgeInsets.all(16), child: SelectableText(issue))),
        if (s.data!.isNotEmpty) const Text('请保留原始数据与备份，按原单及实际业务核对；软件不会自动改写历史金额。'),
        OutlinedButton(onPressed: _retry, child: const Text('重新检查')),
      ]);
    }),
  );
}
