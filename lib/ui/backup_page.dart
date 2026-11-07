import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../application/backup_store.dart';
import '../data/backup_snapshot.dart';
import '../services/backup_codec.dart';

/// User-controlled, password-encrypted off-device backup and empty-db restore.
/// The UI never writes the plaintext snapshot to a file.
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.store});
  final BackupStore store;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;

  Future<String?> _askPassword({required bool forExport}) {
    var password = '';
    final key = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(forExport ? '设置备份密码' : '输入备份密码'),
        content: Form(key: key, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(forExport
              ? '备份包含客户、销售和收款信息。必须保存到手机外；忘记密码无法恢复。'
              : '密码仅在本次解密时使用，不会发送或保存。'),
            const SizedBox(height: 16),
            TextFormField(
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '备份密码'),
              onChanged: (v) => password = v,
              validator: (v) => v == null || v.runes.length < 12
                ? '密码至少需要 12 个字符' : null),
            if (forExport) ...[
              const SizedBox(height: 12),
              TextFormField(
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '再次输入密码'),
                validator: (v) => v != password ? '两次密码不一致' : null),
            ],
          ],
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (key.currentState!.validate()) {
                Navigator.pop(ctx, password);
              }
            }, child: Text(forExport ? '生成加密备份' : '解密并检查')),
        ],
      ),
    );
  }

  Future<void> _notify(String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('数据管理'),
        content: SelectableText(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<void> _export() async {
    final password = await _askPassword(forExport: true);
    if (password == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final plain = await widget.store.exportSnapshotJson();
      final encrypted = await BackupCodec.encrypt(plain, password);
      final temp = await getTemporaryDirectory();
      final now = DateTime.now();
      final filename = 'kaibao-${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}-${now.millisecondsSinceEpoch}.kberp';
      final output = File('${temp.path}/$filename');
      await output.writeAsBytes(encrypted, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(output.path, mimeType: 'application/octet-stream')],
        subject: '凯堡软装加密备份',
      ));
      await _notify('已打开系统分享。请检查 .kberp 文件是否确实保存到手机以外的位置，并妥善保管密码。'
          '仅生成临时文件或打开分享面板不等于备份已完成。');
    } catch (e) {
      await _notify('备份未完成：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom, allowedExtensions: ['kberp']);
      if (file == null || !mounted) return;
      final password = await _askPassword(forExport: false);
      if (password == null || !mounted) return;
      setState(() => _busy = true);
      final encrypted = await file.readAsBytes();
      final clear = await BackupCodec.decrypt(encrypted, password);
      final snapshot = BackupSnapshot.parse(clear);
      if (!mounted) return;
      final summary = snapshot.counts;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('恢复前最后确认'),
          content: Text('备份日期：${snapshot.createdAt}\n'
              '客户：${summary['customers']}，产品：${summary['products']}，'
              '供应商：${summary['suppliers']}，采购单：${summary['purchase_orders']}，'
              '仓库：${summary['warehouses']}，收货单：${summary['purchase_receipts']}，'
              '库存流水：${summary['stock_movements']}，'
              '销售：${summary['sales']}，收款：${summary['payments']}。\n\n'
              '只允许恢复到没有任何业务数据的全新数据库。'
              '如果本机已有客户、订单或草稿，将拒绝恢复，不会合并或覆盖。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认恢复')),
          ],
        ),
      );
      if (confirmed != true) return;
      await widget.store.restoreSnapshotJson(clear);
      await _notify('数据库恢复成功，完整性和关联检查已通过。请返回首页核对客户、销售、收款等数据。');
    } catch (e) {
      await _notify('恢复没有完成：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('数据备份与恢复')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      const Card(child: Padding(
        padding: EdgeInsets.all(16),
        child: Text('所有经营数据默认保存在本机 SQLite。卸载应用、清除数据或设备损坏可能导致数据丢失。'
            '备份文件采用密码派生密钥和 AES-256-GCM 认证加密；软件不会替你保存密码。'),
      )),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _busy ? null : _export,
        icon: const Icon(Icons.ios_share),
        label: const Padding(padding: EdgeInsets.all(12),
          child: Text('创建加密备份并分享')),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy ? null : _restore,
        icon: const Icon(Icons.settings_backup_restore),
        label: const Padding(padding: EdgeInsets.all(12),
          child: Text('从加密备份恢复（仅空数据库）')),
      ),
      const SizedBox(height: 18),
      const Text('正式使用前，请先用测试数据演练：导出 → 保存到电脑 → '
          '在全新安装或独立测试设备恢复 → 核对金额。'
          '目前不提供对现有数据的覆盖恢复，也不提供多设备合并。',
          style: TextStyle(color: Colors.grey)),
      if (_busy) ...[
        const SizedBox(height: 20),
        const Center(child: CircularProgressIndicator()),
      ],
    ]),
  );
}
