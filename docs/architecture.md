# 凯堡软装 ERP：技术架构与数据契约（2026-11-06）

状态：**离线采购/销售开发中的 ERP 原型，尚未达到完整 ERP 的数据安全与业务验收。**

## 1. 当前已经落地的代码层次

```text
main.dart
  └─ DatabaseScope（UI 可注入测试用 AppDatabase）
       └─ UI/pages.dart（输入、草稿和视图交互）
            ├─ Domain: models.dart / money.dart
            ├─ Data: AppDatabase（SQLite schema v5, transaction, migration）
            ├─ Output: SalesCsvExporter（纯数据转换，订单与明细分表）
            └─ Output: InvoicePdf（Flutter canvas / Android printing）
```

严格区分：
- **Domain**：业务单位与金额规则，整数分/毫米，单行四舍五入，不依赖 IO。
- **Data**：SQLite 是唯一的订单、收款、客户、产品真值。历史快照只代表开单时状态。
- **Output**：标准数据导出与设备分享分离；CSV 测试不需要操作手机。
- **UI**：输入校验/反馈、草稿恢复和页面导航；当前仍存在部分应用用例编排，属于下一阶段需抽离的技术债。
- **Application（未独立完成）**：销售、收款、出库等业务用例将以端口和事务边界实现，不靠堆空接口假装架构完善。

## 2. SQLite 数据结构

| 表 | 用途 | 写入特点 |
|---|---|---|
| `customers` | 客户、联络信息、期初欠款 | 当前仅新增 |
| `products` | 产品型号、规格、默认价格 | 当前仅新增 |
| `sales` | 已确认销售单、编号、客户快照、金额快照 | 事务内写入 |
| `sale_lines` | 产品快照、米数、门幅、单价、行金额 | 销售事务内写入 |
| `payments` | 分次收款流水 | 超额拒绝，事务内写入 |
| `sale_drafts` | 单机 1 份编辑草稿、带 JSON schema 版本 | 可覆盖，不能作为财务账 |

生产路径：Android `getDatabasesPath()/kaibao_sales.db`；测试路径：通过 AppDatabase.forTesting 注入数据库工厂及独立文件路径。

Schema 版本：
- v1：客户、产品、销售、销售明细、收款。
- v2：增加 `sale_drafts`；保留 v1 业务数据。
- v3：供应商、采购订单和采购明细，订单不直接影响库存及应付。
- v4：仓库、采购收货、收货明细与库存流水；按采购行部分收货，事务/请求标识防重复。
- v5：新增销售出库及销售实物退货四表；不更改原有入库事件，统一视图按正负库存运动推导余额。
- 迁移通过 `onUpgrade`，不允许破坏性删除旧表。每次升级需新增从真实前版数据库迁移的自动化测试。

## 3. 金额不变量

- `length_milli`、`width_milli`：毫米，整数。
- `area_micro = length_milli × width_milli`：百万分之一平方米。
- `unit_price_cents`：每平方米价格（分）。
- `line_cents = round_half_up(area_micro × unit_price_cents / 1_000_000)`。
- `subtotal = Σ line_cents`，`payable = subtotal - discount`。
- `current_due = payable - Σ payments`；`customer_outstanding = opening_balance + Σ confirmed_sales.current_due`。
- 货款和收款不能由缓存写回；任何超额收款必须在数据库事务内再次判定。
- `prior_due_snapshot` 是**开单时历史快照**，当前客户欠款应重新查询权威数据库。

## 4. 缓存、草稿、持久化

**目前不引入跨页面业务读缓存。** 每次列表读取数据库，避免引入失效协议之前缓存造成欠款不一致。未来性能瓶颈需要先采集 1k/10k 单测量，再决定分页、索引与可失效只读缓存。

草稿与缓存不是同一件事：
- `sale_drafts` 是业务操作进行中的**持久化工作副本**，不进入销售账。
- 文本输入停顿约 650ms 自动保存、可手工保存；再次进入编辑器恢复。
- 正式销售提交等待排队中的草稿写入，再通过单笔事务生成销售及首付款、清除草稿。
- 恢复失败时不默删草稿，需保留原文供诊断。
- 极短间隔强杀/断电仍可能丢最后一次尚未写入的输入；此项必须设备测试。

## 5. 业务命令与状态边界（待实现的正确方向）

```text
CreateSale / UpdateSaleDraft
            |
            v
      Sales + SaleLines  ----> Receivables
            |
            +----> Dispatch (单独业务事件；不等于销售已确认)
                         |
                         v
                   Stock movements
Payment (独立事件) ----> Receivables
PhysicalReturn (引用原出库) --> 正向入库流水\nCreditNote / Refund (待实现) --> 独立财务凭证
```

**阻断项**：当前只支持米数×门幅折合面积计价/入库，没有卷/匹/套换算、独立退款/贷项/冲销、完整会计/审计日志；只有手动加密备份，未通过真机恢复演练。不能称作已完成 ERP。

## 6. 质量门禁

- Domain 金额与边界单测。
- 真实文件 SQLite FFI：创建、关闭、重开、交易回滚、迁移、并发、收款。
- Widget 层：输入客户、产品、开单，核对订单详情与数据库结果。
- Output 层：CSV 两表行数、金额唯一性、特殊字符与公式型文本处理。
- CI：`flutter test`、`flutter analyze`、`flutter build apk --debug`。
- Android 真机：冷启动、异常退出、重入、安装升级、打印与文件系统权限。
- 正式部署门禁：**可校验、可恢复的离机数据备份**、签名发布、迁移演练。

详见 [工程审计报告](engineering-audit-2026-11-06.md) 和 [验收矩阵](acceptance.md)。

## 7. 收货及库存流水（schema v4）

`PurchaseOrders` 属商业承诺；`PurchaseReceipts` 记录实物到货；`StockMovements` 只写由收货事件生成的正向库存流水，供应商应付等待独立发票流程。

- 收货对齐 **purchase_lines.id** 而非 product_id：同一产品多个采购行可以有不同门幅/单价。
- 原始单位米数/门幅为整数千分之一米；库存单位 `area_micro = length_milli × width_milli`，避免浮点误差。
- 不缓存库存权威余额；查询时按 `product_id + warehouse_id + batch_code` 汇总流水。
- 数据库事务内校验采购单状态、仓库状态、采购行所属与已收数量；`request_key` 加规范化 payload 做幂等；一条收货行严格一条库存流水。
- 已有收货的采购单不能直接取消；没有退货业务前，不提供可任意删除流水的 UI。
- v4 备份包含新增四表和一致性校验，支持旧 v2/v3 备份恢复到新空库。

详见 [两模块实施计划](erp-module-roadmap-2026-11-07.md)。

## 8. 销售出库与实物退货（schema v5）

- `FulfillmentStore` 是应用接口；`FulfillmentRepository` 独立承载 SQLite 锁定事务和幂等，`AppDatabase` 仅做应用组合与端口注入。UI 不构造原始 SQL。
- 新增 `sale_dispatches` / `sale_dispatch_lines` 和 `sale_returns` / `sale_return_lines` 四张事件凭证表，不修改 v4 `stock_movements` 记录。
- `stock_ledger_entries` 是 SQLite 只读视图：采购收货（正）、销售出库（负）、原出库关联退货（正）；`stockBalances()` 统一求和，没有双写缓存。
- 真实出库在同一 SQLite 事务重核销售行、仓库/批次、累计已出米数与库存余额。缺少销售产品 ID 的历史手工明细不允许猜测并扣库存。
- 原出库行和实物退货一一可追溯；累计实物退回不大于出库米数，且只能回原仓和批次。资金冲销独立于实物退货，**绝不自动重写销售应收或已收款**。
- 快照 v5 引入四表并校验原销售/原出库关系、面积、数量上限、库存非负、请求键和内容一致性；原 v2/v3/v4 快照恢复时，v5 表按空表创建。
- Android 软键盘、脱机中断、真实分享、打印仍待用户设备验收；源码可编译或 GitHub CI 成功不等于发布就绪。
