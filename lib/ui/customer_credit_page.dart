import 'package:flutter/material.dart';

import '../application/customer_credit_store.dart';
import '../domain/customer_credit.dart';
import '../domain/money.dart';

class CustomerCreditPage extends StatefulWidget {
  const CustomerCreditPage({super.key, required this.customerId, required this.store});
  final int customerId;
  final CustomerCreditStore store;

  @override
  State<CustomerCreditPage> createState() => _CustomerCreditPageState();
}

class _CustomerCreditPageState extends State<CustomerCreditPage> {
  late Future<CustomerCreditAccount> _account = widget.store.customerCreditAccount(widget.customerId);
  void _refresh() {
    final pending = widget.store.customerCreditAccount(widget.customerId);
    setState(() { _account = pending; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('客户余额与明细'), actions: [
      IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: '刷新余额'),
    ]),
    body: FutureBuilder<CustomerCreditAccount>(future: _account, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('余额暂时无法读取'), TextButton(onPressed: _refresh, child: const Text('重新加载'))]));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      final account = snapshot.data!;
      return ListView.builder(itemCount: account.entries.length + 1, itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(account.customer.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text('可用余额 ¥${Fixed.format(account.balanceCents, decimals: 2)}',
                style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text('余额与客户欠款分别核算。每笔变动均关联来源销售单；此页不能直接修改余额。'),
              const Divider(height: 32),
              if (account.entries.isEmpty) const Text('暂无余额流水'),
            ]));
        }
        final entry = account.entries[index - 1];
        final amount = '${entry.deltaCents > 0 ? '+' : ''}¥${Fixed.format(entry.deltaCents, decimals: 2)}';
        return Card(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: Padding(
          padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(amount, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(entry.reason), Text('来源单号 ${entry.saleNumber}'), Text(entry.createdAt),
            Text('变动后余额 ¥${Fixed.format(entry.balanceAfterCents, decimals: 2)}'),
          ])));

      });
    }),
  );
}
