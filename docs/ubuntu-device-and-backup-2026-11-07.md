# Ubuntu + Android 真机开发及加密数据备份（2026-11-07）

> 本文最初创建于历史 Ubuntu 开发分支；既有 PR #1–#6 已合并 `main`。下一阶段以 [销售开单 MVP 验收契约](mvp-release-gate-2026-11-07.md) 为唯一发布门禁。
> 代码提交、GitHub Actions 构建、真机验收是不同状态。
> **不允许在设备验收之前用作正式经营唯一账本。**

## 1. 分支依赖

```text
main（已合并 PR #1–#6、SQLite v6；MVP 验证基线）
```

在 Ubuntu 的克隆仓库中：

```bash
git fetch origin --prune
git switch main
git pull --ff-only origin main
git rev-parse --short HEAD
git status --short

bash scripts/doctor.sh
bash scripts/bootstrap-ubuntu.sh

fvm flutter analyze
fvm flutter test
fvm flutter build apk --debug
```

- 工程版本由 `.fvmrc` 约束 Flutter **3.47.9**，与 CI 一致。
- 需要 Java **17**、Android API **36**、Build Tools **36.0.0**、ADB。
- `bootstrap-ubuntu.sh` 不执行 `apt`、不重置 Git、不改变其他工程 SDK。
- `android/` 仍是临时生成的 Flutter runner。**它尚未纳入 Git**，因此 Gradle 配置的完整版本化是尚未解决的后续工作。不要误称 Android 原生工程已锁定。
- `pubspec.lock` 已由 GitHub CI 解析生成并提交；CI 使用 `flutter pub get --enforce-lockfile` 验证依赖版本，不允许静默升级。

## 2. 真机数据库测试（不会改动正式 kaibao_sales.db）

安卓手机打开 USB 调试、授权数据线，Ubuntu 执行：

```bash
adb devices -l
fvm flutter devices
fvm flutter test integration_test/storage_device_test.dart -d <设备ID>
```

此用例在安卓数据库目录创建一个带随机名称的临时库，写入测试客户、产品、销售、收款，关闭再打开核对数据，结束时删除临时库。**不触及现有正式数据库**。

手动测试：在首页新建测试客户→产品→销售→退出→重进→历史与欠款核对；在草稿界面输入→手动保存→重进恢复；打印与分享仍需设备审查。

## 3. 加密备份：用户动作与保护边界

首页右上角的“数据备份与恢复”：
1. 点击**创建加密备份并分享**；输入并重复至少 12 字符的口令。
2. 应用在同一 SQLite 事务读取当前 `BackupSnapshot.columns` 明确列出的全部业务表（v6 共 19 张，包含草稿、采购、收货、出库、退货、资金及日结），生成严格校验的逻辑快照。
3. 在内存中使用 PBKDF2-HMAC-SHA256 210000 次导出 256 位密钥，每次随机 16B 盐；使用 AES-256-GCM 的随机 nonce 加密。
4. **只有密文**会写到临时 `.kberp` 文件；选择系统分享目标将文件保存到电脑、外接存储或其他设备。打开分享面板不代表离机备份已经成功。
5. 密码不会储存在软件中；遗失后无法解密。

恢复操作：
1. 使用 Android 文件选择器打开 `.kberp`。
2. 解密、验证 GCM 完整性标签、快照版本、字段、资金计算与引用关系。
3. 展示记录数量及时间，明确确认后在 SQLite 事务中恢复。
4. **只有全空数据库允许恢复**，只要有一个客户、商品、单据、收款或草稿就禁止导入；不会合并、删除或覆盖现有数据。
5. 导入事务任意一步失败则整体回滚；额外检查外键与完整性。

注意：备份文件数据是**敏感经营信息**；口令应与文件分别保存。所有备份共享与文件选择器表现，仍必须在真实设备验证。大库情况下，本版为内存型 JSON 快照，32 MiB 内容上限；未来需流式导出/恢复与加密文件归档。

## 4. 验收矩阵

| 项 | 自动化检查 | 人工/设备仍需核查 |
|---|---|---|
| 工程版本 | FVM .fvmrc、CI Flutter 3.47.9，doctor | Ubuntu 实际 JDK/SDK |
| SQLite 基础 IO | FFI 读写、迁移、事务与重启 | Android 真实系统保存路径 |
| Android SQLite | `integration_test/storage_device_test.dart` | 在用户设备执行 |
| 加密备份 | roundtrip、随机盐、错误密码、篡改检查 | 文件在机外可找到 |
| 账务恢复 | 完整金额/外键校验、原子提交 | 全新设备还原比对 |
| 非空数据库保护 | 测试导入拒绝且原数据存在 | 在人工测试环境验证 |
| 可用 ERP | 出库、实物退货、库存及其他资金冲销已有代码和测试 | 真机、财务总账、供应商应付、客户贷项仍待验与实现 |

## 5. 不做的事

- 不在 Flutter/Ubuntu 安装目录内保存业务数据；不把 SDK、IDE 缓存提交 Git。
- 不覆盖已有数据库，不自动上传客户资料、不引入云端同步。
- 不宣称实现完整 ERP 财务总账、所有库存估值规则、税务发票或生产发布。
- 不把“可以运行”、“CI 全绿”、“真机经过测试”混为一谈。

官方参考：Flutter [Android 集成测试](https://docs.flutter.dev/testing/integration-tests)、[Android Gradle 构建](https://developer.android.com/build)、[SQLite 持久化](https://docs.flutter.dev/cookbook/persistence/sqlite)；加密库 [cryptography](https://pub.dev/packages/cryptography)、原生文件选择器 [file_picker](https://pub.dev/packages/file_picker)。

## SQLite v4–v6：增量业务模块及真机测试

本文件最初描述 v3 基线，后续已经合并 v4 仓库与收货、v5 销售出库与实物退货；v6 新增其他资金收支、反向冲销及日结对账。所有版本向前迁移；逻辑加密备份兼容历史 v2–v5。

真机用例 `integration_test/storage_device_test.dart` 增加真实 Android SQLite 的收货→关闭→重开→面积与批次校验。该测试代码必须由用户在安卓手机上运行才算设备通过。

真机用例在独立测试数据库中进一步验证其他资金收支→日结→关闭→重开；不触及正式 `kaibao_sales.db`。涉及真实银行流水核对及 CSV 分享时仍需人工提供设备证据。详见 [业务两模块计划](erp-module-roadmap-2026-11-07.md)。
