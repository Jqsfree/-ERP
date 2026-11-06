# 凯堡软装销售开单（Kaibao Sales）

面向软装/布料商户的 Android 离线开单应用。**当前版本：v0.1.0（审查整改分支；仍是原型，尚未通过真实设备完整验收）**。

> 本仓库是独立实现，不是 ERPNext / Invoice Ninja 的二次分发。

## 当前已编写的功能（不等于已在安卓验证）

- 离线客户建档：名称、电话、地址、初始欠款。
- 产品建档：产品型号、规格、元/平方米单价。
- 销售出货单：客户选择、多产品行、米数、门幅、折算面积、优惠、首笔收款、备注。
- 保存时在 SQLite 事务内生成 `XSYYYYMMDD0001` 风格编号，并将价格和客户资料快照保存，历史单不会随产品改价发生变化。
- 每行 `数量(米) × 门幅(米) × 单价(元/㎡)`；每行金额按四舍五入到分，然后相加；优惠是**单据级优惠**。
- 销售历史、按单补录收款、查看应收余额、显示开单时的上期欠款。
- 安卓设备系统字体离线绘制中文，生成 A4 横版 PDF，可打印、分享。
- 销售记录导出两份 UTF-8 BOM CSV（销售单、销售明细）供 Excel/WPS 查阅（不是 XLSX）；整单金额不在每条明细上重复。
- 草稿保存在 SQLite `sale_drafts` 中；停顿约 650ms 自动写入、支持手动保存和重新进入恢复。
- 数据库 schema v2，支持 v1->v2 的非破坏性迁移，测试中使用独立 SQLite 文件验证 IO、事务、重开与收款。
- UI 通过 DatabaseScope 注入存储依赖，输出 CSV 与设备分享 IO 分离。

## 尚未实现

采购、供应商、实际库存流水与扣减、退货、费用收支、订单作废/修订、**离机备份与恢复**、多设备同步、多角色权限、发票税务处理、商业打印版式与设备验收。仅有 v1->v2 数据库迁移，不代表已有独立备份。

**重要**：当前只写销售流水，**不会自动扣减库存**。不要把此应用当成已验收的正式 ERP。安装卸载或清除应用数据可能丢失本地数据；测试时勿录入唯一一份真实商业数据。

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
  domain/                  定点数计算、业务模型
  data/app_database.dart   SQLite 模型和事务
  services/invoice_pdf.dart 离线中文 PDF 渲染
  ui/pages.dart             销售、产品、客户、收款交互
test/                      金额、SQLite 真实文件 IO、Widget 业务路径、CSV 安全输出测试
docs/                      需求、设计和路线图
.github/workflows/          安卓 CI / Debug APK
```

## 2026-11-06 软件工程审计

详见 [数据存储、输入输出与完整架构审计](docs/engineering-audit-2026-11-06.md)。当前整改放在独立分支，不以主页可以打开代替业务验收。读缓存尚未加入，SQLite 为权威数据源；草稿持久化不是余额缓存。

## 发布准则

在正式启用前至少完成：安卓真机安装；前后台重进不丢单；10/100/1000 条订单稳定性；中文 PDF 多页打印；退款/作废的反向流水；可恢复的数据备份；签名密钥管理；销售总账与收款核对。见 `docs/acceptance.md`。

## 研究参考

- [Ledger for Android](https://github.com/robifr/ledger) — 离线销售订单与欠款。
- [Invoice Ninja](https://github.com/invoiceninja) — 发票与收款、打印工作流。
- [Flutter POS](https://github.com/Shan0h/Pos) — 离线库存、收银流程。
- [ERPNext Selling](https://docs.frappe.io/erpnext/selling) — 订单、出货、发票、付款的职责边界。

上述项目仅作为工作流参考，不引入其源码；改造和商业复用时仍需单独审核许可。
