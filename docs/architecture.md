# 架构与数据契约

## 分层

```
Flutter Android UI
  -> Domain: Fixed/BillingMath/Sale/SaleLine
  -> Repository: AppDatabase (SQLite transaction)
  -> SQLite local-only
  -> Output adapters: Canvas PDF -> Android system print; CSV -> Share
```

- v0.1 设备完全本地，无后端，无第三方登录。
- 所有销售单创建包含客户快照、产品快照、金额、优惠、首次收款，在一个 SQLite 事务内完成。
- 对销售单新增收款在另一个 SQLite 事务内完成，并复核当前未收金额。不能覆盖原单行。
- 同一客户“当前总欠款”来自原始开账余额与所有已确认单未收金额，不直接累计一份可漂移的余额缓存。
- `sales.prior_due_snapshot` 是开单时快照，只用于历史单展示，不是当前客户应收的权威来源。

## 金额契约

- `length_milli`/`width_milli`：长度和门幅（千分之一米）。
- `area_micro = length_milli * width_milli`：百万分之一㎡。
- `unit_price_cents`：每平方米的价格分。
- `amount_cents = round_half_up(area_micro * unit_price_cents / 1000000)`。
- 先逐行计算分，再相加。不能先合计原始浮点再整体舍入。
- `contract = Σamount_cents - discount_cents`。
- `outstanding = contract - Σpayments.amount_cents`。

## 需要在 P1 解决的数据与不变量

- 库存数量的真实计量单位：布料可能按米长、平方米、卷或套销售；库存转换与进货单位不能以截图假设确定。
- 出货与销售是不同的业务事件；若支持部分出货，销售单与出库单须分别建模。
- 同一出库事件只扣一次库存；退货通过关联原出库的反向流水抵销。
- 售后、退款与欠款冲销必须关联原单并保持审计历史。
- `customers.name`/`products.code` 目前唯一；未来若有重名客户或不同批次同型号，须引入独立编码而非复用名称作身份。

## 发布/合规限制

应用生成“销售出货单/商业凭证”，**不是税务电子发票**。不应以它替代税控发票或会计软件。PDF 当前采取栅格化中文渲染确保离线打印，文本不可直接搜索/复制；后续可升级为嵌字矢量 PDF。
