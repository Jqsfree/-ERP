# 凯堡软装销售开单（Kaibao Sales）

面向软装/布料商户的 Android 离线开单应用。**当前版本：v0.1.0（审查整改分支；仍是原型，尚未通过真实设备完整验收）**。

> 本仓库是独立实现，不是 ERPNext / Invoice Ninja 的二次分发。

## 当前已编写的功能（不等于已在安卓验证）

- 离线客户建档：名称、电话、地址、初始欠款。
- 供应商主数据：新增、修改、停用，历史采购单保留供应商资料快照。
- 采购订单：选择供应商、已登记产品、多行米数/门幅、独立采购单价；记录采购承诺、可查看历史并取消。**创建采购订单不增加库存，也不形成应付账款。**
- **采购收货 + 库存流水（已合并）**：先建仓库，从采购订单逐明细登记部分收货，支持仓库及可选批次，事务同步写入不可直接修改的库存流水；查询库存按面积汇总。已通过合并前 CI，Android 真机仍待验收。
- 产品建档：产品型号、规格、元/平方米单价。
- 销售单：客户选择、多产品行、米数、门幅、折算面积、优惠、首笔收款、备注。
- 保存时在 SQLite 事务内生成 `XSYYYYMMDD0001` 风格编号，并将价格和客户资料快照保存，历史单不会随产品改价发生变化。
- 每行 `数量(米) × 门幅(米) × 单价(元/㎡)`；每行金额按四舍五入到分，然后相加；优惠是**单据级优惠**。
- 销售历史、按单补录收款、查看应收余额、显示开单时的上期欠款。
- 安卓设备系统字体离线绘制中文，生成 A4 横版 PDF，可打印、分享。
- 销售记录导出两份 UTF-8 BOM CSV（销售单、销售明细）供 Excel/WPS 查阅（不是 XLSX）；整单金额不在每条明细上重复。
- 草稿保存在 SQLite `sale_drafts` 中；停顿约 650ms 自动写入、支持手动保存和重新进入恢复。
- **本批次开发中**：销售出库按原销售行进行分次扣减实际仓库批次库存；销售实物退货必须引用真实原出库，退回原仓库与批次。两者均不修改销售账、应收或收款。
- 数据库 schema v5，保留 v1→v2→v3→v4→v5 非破坏性迁移路径；SQLite 文件测试覆盖销售、采购、收货、出库、退货、库存流水、事务及重开。
- **本轮验证中的功能**：用户主动导出 AES-256-GCM 加密 `.kberp` 数据备份；恢复前校验账务一致性，只允许在全空 SQLite 数据库恢复。尚未完成真机验证。
- UI 通过 DatabaseScope 注入存储依赖，输出 CSV 与设备分享 IO 分离。

## 尚未实现

采购发票/应付款、采购退货、**销售退款/贷项通知单**、质量不合格退货、费用收支、销售订单作废/修订、自动备份与全量恢复演练、多设备同步、多角色权限、发票税务处理、商业打印版式与设备验收。**加密备份导出/空库导入已有代码和自动化测试，但真实 Android 文件分享/选取仍待设备验证。**

**重要**：保存销售单仍不会自动扣库存；必须单独提交实际销售出库，且只有真实入库后才能出库。实物退货不自动退款/冲销财务。不要把此应用当成已验收的正式 ERP。安装卸载或清除应用数据可能丢失本地数据；测试时勿录入唯一一份真实商业数据。

## 运行

要求 Android SDK 和 Flutter stable，最低 Dart 3.7。仓库不提交自动生成的 Android 工程目录；为了减少模板/Gradle 版本漂移，请在首次运行时生成：

```bash
flutter create --platforms=android --project-name kaibao_sales --org com.kaibao .
flutter pub get
flutter test
flutter analyze
flutter run
```

生成测试 APK：

```bash
flutter build apk --debug
# build/app/outputs/flutter-apk/app-debug.apk
```

Github Actions 工作流 `.github/workflows/android.yml` 会在每次 push / PR 时重新生成 Android 工程、测试并上传可安装测试包。**Debug APK 只用于内部验证，正式投产需要独立签名、备份与发布策略。**

## Ubuntu 主开发机（FVM + 安卓真机）

本轮 `.fvmrc` 固定 Flutter 3.47.9。项目依赖独立于 SDK 安装位置，在 Ubuntu 运行：

```bash
git fetch origin --prune
git switch main\ngit pull --ff-only origin main
bash scripts/doctor.sh
bash scripts/bootstrap-ubuntu.sh
fvm flutter test
fvm flutter analyze
fvm flutter build apk --debug
fvm flutter devices
fvm flutter run -d <设备ID>
fvm flutter test integration_test/storage_device_test.dart -d <设备ID>
```

当前从 `main` 获取已经合并的开发基线。若需提前测试未合并的第三批代码，改为 `git switch --track origin/feat/sales-dispatch-return-20261107`。切换分支前检查未提交文件。本仓库目前仍动态生成 `android/`，Gradle Wrapper 尚待纳入版本控制，不能称为完整的可复现原生构建。

**数据备份**：首页右上角“数据备份与恢复”允许导出带密码的 `.kberp` 文件、从系统文件选择器选择后恢复到**完全空**的数据库。密码至少 12 字符且无法找回；用户必须确认文件实际保存到了手机外部。没有任何现有数据会被覆盖。真机数据完整性及分享流程尚待验收。

完整执行与验证见 [Ubuntu/设备及备份手册](docs/ubuntu-device-and-backup-2026-11-07.md)。

## 业务数据与计算

示例图：`37 × 2.8 × 13.99 = 1449.364`，逐行四舍五入后 `¥1449.36`，优惠 `¥0.36`，合同金额 `¥1449.00`。内部不使用 double 处理账款；人民币使用整型分，长度/门幅用千分之一米，面积以百万分之一平方米计。

- 明细：长度（米）× 门幅（米）＝计价面积（㎡），以每条原始行计算金额。
- 产品金额：每条金额四舍五入到分后求和。
- 合同金额＝产品金额－优惠。
- 本单未收＝合同金额－本单全部收款。
- 客户当前欠款＝初始欠款＋全部已确认销售单剩余未收。
- 出货单显示的“上期欠款”是在该单创建时计算的**快照**，历史单不会随着未来收款而重写。

## 项目结构

```text
lib/
  main.dart                 应用入口
  domain/                  定点数计算、销售及采购领域模型
  data/app_database.dart   SQLite v5、销售/采购/库存事务
  services/invoice_pdf.dart 离线中文 PDF 渲染
  ui/pages.dart             销售、产品、客户、收款交互
  ui/procurement_pages.dart  供应商与采购订单页面\n  ui/inventory_pages.dart    仓库、收货及库存流水\n  ui/fulfillment_pages.dart  销售出库及关联实物退货
test/                      金额、SQLite 真实文件 IO、Widget 业务路径、CSV 安全输出测试
docs/                      需求、设计和路线图
.github/workflows/          安卓 CI / Debug APK
```

## 2026-11-06 软件工程审计

详见 [数据存储、输入输出与完整架构审计](docs/engineering-audit-2026-11-06.md)。当前整改放在独立分支，不以主页可以打开代替业务验收。读缓存尚未加入，SQLite 为权威数据源；草稿持久化不是余额缓存。

## 模块分批推进

阶段计划见 [ERP 两模块一批的实施与测试门禁](docs/erp-module-roadmap-2026-11-07.md)。

首批新模块**供应商 + 采购订单**已经合并；第二批**采购收货 + 库存流水**已经合并；第三批**销售出库 + 实物退货**正在独立分支验证。迁移路径包括 v2→v3→v4→v5，备份必须兼容 v2/v3/v4。CI 通过只代表自动测试和构建通过，真机输入、持久化和备份流程需要设备验收。用户未确认的进销存单据规则不得按假设擅自录入财务或库存流水。

## 发布准则

在正式启用前至少完成：安卓真机安装；前后台重进不丢单；10/100/1000 条订单稳定性；中文 PDF 多页打印；退款/作废的反向流水；可恢复的数据备份；签名密钥管理；销售总账与收款核对。见 `docs/acceptance.md`。

## 研究参考

- [Ledger for Android](https://github.com/robifr/ledger) — 离线销售订单与欠款。
- [Invoice Ninja](https://github.com/invoiceninja) — 发票与收款、打印工作流。
- [Flutter POS](https://github.com/Shan0h/Pos) — 离线库存、收银流程。
- [ERPNext Selling](https://docs.frappe.io/erpnext/selling) — 订单、出货、发票、付款的职责边界。

上述项目仅作为工作流参考，不引入其源码；改造和商业复用时仍需单独审核许可。
