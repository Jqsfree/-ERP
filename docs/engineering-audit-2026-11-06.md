# 2026-11-06 工程审计：销售输入、输出、持久化与架构

> **历史审计记录（2026-11-06）**：以下“未实现”结论仅代表初始 v0.1/SQLite v2 阶段。当前功能、迁移版本和验收门禁以 [最新架构](architecture.md)、[模块路线图](erp-module-roadmap-2026-11-07.md) 和 GitHub Actions 最终提交为准；新批次已增加库存、出库、实物退货、其他资金收支及日结代码，但 Android 真机商用验收仍未完成。

> 基线：main@1025861，整改分支 `feat/storage-io-audit-20261106`。
> 状态定义：**已编写**不等于**CI 已验证**，CI 通过也不等于**安卓真机验收**。
> 当前修改是原型架构改进，不代表 ERP 账务、库存和正式商用已完成。

## 1. 审计范围与发现

审查 `lib/main.dart`、`lib/domain`、`lib/data`、`lib/ui`、`lib/services`、`test`、CI 与安装路径。

| ID | 级别 | 基线缺陷 | 整改与验证信号 |
|---|---|---|---|
| IO-01 | P0 | 金额只有孤立单测，没有真实 SQL 读写 | FFI 使用**真实 SQLite 文件**测试建档、开单、查询、关闭重开、后续收款 |
| IO-02 | P0 | 无持久化草稿，应用退出会丢失未提交输入 | DB v2 引入 `sale_drafts`；编辑器停顿后写入、再次进入恢复；保存销售时同一事务删除草稿 |
| IO-03 | P0 | v1 无版本迁移机制 | 明确 schemaVersion=2，v1->v2 onUpgrade；旧记录保留单测 |
| IO-04 | P0 | 无事务回滚测试；并发单号未验证 | 外键异常整单回滚、并发编号唯一、超额收款拒绝测试 |
| IO-05 | P1 | `sales()` 逐单查询明细 N+1 | 改为订单查询 + 分块明细查询；单独 `saleById` 避免保存后全表重查 |
| IO-06 | P1 | CSV 每行重复整单合同金额、收款额；文本公式注入 | 输出销售单、销售明细两个 CSV；统一转义与 Excel 展示保护；纯 Dart 测试 |
| IO-07 | P1 | 历史欠款快照与当前回款混用 | 详情单独实时查询当前客户欠款，原单仍保留开单快照 |
| ARCH-01 | P1 | UI 强依赖不可注入全局 SQLite | `DatabaseScope` 将数据存储注入 UI，真实文件数据库用于 Widget 测试 |
| ARCH-02 | P1 | 无明确缓存责任 | SQLite 是权威写入源；**不另加业务金额/库存缓存**；草稿持久化不是查询缓存 |
| OPS-01 | P0 | 无可恢复的离机备份，卸载会丢数据 | **未解决**，阻止商用 |
| OPS-02 | P0 | 没有审核、冲销、退货、库存事件 | **未解决**，阻止称作完整 ERP |

## 2. 架构边界

```text
Presentation  UI / forms / user feedback
    |
    v
Application  use-case orchestration (next)
    |
    v
Domain       money, units, invariants, immutable snapshots
    |
    v
Data         AppDatabase (injected factory, migrations, transactions)
    |
    +--> SQLite: customers / products / sales / sale_lines / payments
    +--> SQLite: sale_drafts (ephemeral business input, NOT the ledger)
    |
    v
Output       SalesCsvExporter (pure) / InvoicePdf (device-specific)
```

现阶段 Application service 仍混合在 UI 和 AppDatabase 中；新增复杂库存流程前需要提取 `CreateSale`、`ReceivePayment`、`ConfirmDispatch` 用例，以事务和幂等请求 ID 保证业务事件边界。不建议一次性引入大量没有业务实现的接口与空架构。

### 写入与查询原则

1. SQLite 是**本地唯一权威账本**；收款和销售保存为追加写入事件，历史价格与客户信息快照不可因商品改价而被重算。
2. 应收款通过确认销售单与收款记录推导，不能把页面缓存的余额回写数据库。
3. `sale_drafts` 为单机单草稿暂存区，JSON 有版本号，只恢复可解析的字段；格式错误应保留原内容并提示，不能静默删库。
4. 草稿约 650ms 防抖写入，点击“立即保存草稿”可等待写入完成。**这并不能承诺在突发断电/650ms 内强杀时保存最后一个字符**；需补 Android 生命周期与设备场景测试。
5. 确认销售前等待已排队草稿写入，销售+删除草稿在同一 SQLite 事务中完成；异常时事务回滚。
6. 目前页面每次进入重新读取数据库，不持有跨页面业务缓存。以后若引入读缓存，必须明确版本/失效事件、上限和一致性测试。

### 对未来进销存的建模约束

- **订单**：承诺卖什么、价格多少，不等于已经发货。
- **出库单**：实际发货，一次出库事件唯一且库存流水幂等。
- **收款单**：资金事件，可以早于、晚于或分次于发货，不应随修改订单静默变更。
- **退货/退款**：关联原销售、出库和收款，通过反向流水与更正凭证记录。
- **库存**：确定米、平方米、卷、套的单位与换算精度前不得自动扣库。
- 这些模块不应因为首页有入口就被视为完成。

## 3. 测试矩阵 / 独立验收

| 类型 | 测试 | 断言 |
|---|---|---|
| Domain | 定点数、逐行四舍五入 | 示例合同 1449.00 元 |
| Database (FFI) | 客户、产品、销售、付款，close/reopen | 实际文件中数据保留、金额不漂移 |
| Database (FFI) | 外键异常、收款超额、并发开单 | 全部回滚/拒绝；单号不重复 |
| Database (FFI) | schema v1->v2；draft reopen/commit | 旧数据存在；草稿可恢复；确认后清除 |
| Output | CSV 订单/明细行数及列契约 | 不重复计算整单金额，Excel BOM 与安全文本 |
| UI (Widget) | 客户/产品输入->销售->详情/数据库 | 真实 UI 路径可完成，输出与数据库一致 |
| Device | Android 冷启动、进后台、强杀、重新开单 | **待真机验证** |
| Device | PDF/分享/中文打印/存储清理 | **待真机验证** |
| Recovery | 离机备份+恢复+校验 hash | **未实现，阻止生产** |
| Business | 退货、冲销、库存、日结对账 | **未实现，阻止生产** |

提交前/CI 执行：
```bash
flutter pub get
flutter test
flutter analyze --no-fatal-infos
flutter create --platforms=android --project-name kaibao_sales --org com.kaibao .
flutter build apk --debug
```

## 4. 后续工程阶段与发布门禁

### P0 数据安全

- 建立数据库结构和迁移兼容性测试（至少 v1、v2，未来每版向前迁移）。
- **实现离机加密备份/恢复**：数据清单、schemaVersion、文件摘要、原子导出、恢复预演，不允许导入失败覆盖现有数据库。
- 恢复后运行 `PRAGMA integrity_check` 和 `foreign_key_check`，对销售额/收款额做业务核对。
- 业务命令引入幂等请求键；所有金额/数量边界验证发生在事务内，覆盖并发与重复点击。
- 在真实 Android 设备上验证 SQLite 的存储路径、冷启动、异常退出、系统回收与升级。

### P1 架构收敛与进销存领域建模

- 按 Use Case -> Repository ports -> SQLite adapters 解耦，UI 不承担账务事务。
- 统一 Application Result（成功/校验失败/设备 IO 失败/冲突），确保保存成功而详情读取失败不呈现“保存失败”。
- 定义销售单/出库单/收款/退货状态机，追加事件、冲销与审计日志。
- 对订单历史做分页、索引和量测（1k/10k/100k 单），不要通过全表查询充当搜索服务。
- 一次真实出库只扣一次库存，计量换算通过用例和单测覆盖。
- 实现正式单据模板的文本可选择 PDF、设备打印、多页对账。

### P2 运营与交付

- 多角色、访问权限、本地安全策略；业务报表与日结。
- 正式 Android `android/` 工程版本化、packageId、签名、安全更新、密钥保管；不应长期依赖每次 CI 动态生成原生模板。
- 签名 APK/AAB、Release 版本、可重放验收记录、操作手册和数据迁移说明。

## 5. 结论边界

CI 测试通过只证明当前自动化用例通过；**不代表**真实安卓系统文件 IO、设备打印、备份恢复、库存准确性、外部 Excel 等价或完整 ERP 商用验收。未通过所有 P0 阻断门槛前，不得部署为正式经营唯一记账系统。
