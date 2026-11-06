# 验收矩阵：截至 2026-11-06（整改分支）

所有状态必须引用实际测试输出：**已编写** / **CI 已通过** / **真机已通过** / **未实施**。CI 在分支不断更新，最新 commit 的最终结论以 [Actions](https://github.com/Jqsfree/-ERP/actions) 为准。

| 类别 | 场景 | 预期结果 | 自动化证据 | 现场验收 |
|---|---|---|---|---|
| 金额 | 37×2.8×13.99-0.36 | ¥1449.00 | `money_test.dart` | 待验 |
| 金额 | 多行逐行取整与输入限制 | 2192.40、1334.26；非法值拒绝 | `money_test.dart` | 待验 |
| 输入输出 | UI 客户→产品→开单→详情 | 数据库中单号、金额、客户/明细一致 | `sales_flow_widget_test.dart` | 待 CI 终态与设备验 |
| SQLite | 写入→关闭→重开 | 客户、产品、订单、收款不丢 | `database_integration_test.dart` | 待安卓真机 |
| SQLite | 事务失败 | 回滚所有写入，不出现孤儿明细 | `database_integration_test.dart` | 待验 |
| SQLite | 并发创建 6 张单 | 单号唯一，明细齐全 | `database_integration_test.dart` | 待验 |
| SQLite | 超额收款拒绝、分次收款 | 拒绝并维持余额；合法付款累计 | `database_integration_test.dart` | 待验 |
| SQLite | v1→v2 迁移 | 已有客户保留，草稿表可写 | `database_integration_test.dart` | 待升级真机 |
| 草稿 | 写入→重开→恢复；确认后清除 | 临时数据不进入销售流水 | `database_integration_test.dart` | 待真机强杀测试 |
| CSV | 订单与明细分表 | 不重复记整单金额，Excel 安全文本 | `sales_csv_test.dart` | 待 WPS/Excel |
| PDF | 1/9/10/20 行及跨页打印 | 无丢字、中文正常 | 未有设备测试 | 待验 |
| 备份 | 离机可恢复、可校验 | 重装/故障数据可找回 | **未实施** | 阻断发布 |
| 会计/库存 | 退货、作废、冲销、进销存 | 事件可回放、对账一致 | **未实施** | 阻断称作完整 ERP |

## 测试方式

```bash
flutter pub get
flutter test
flutter analyze --no-fatal-infos
flutter create --platforms=android --project-name kaibao_sales --org com.kaibao .
flutter build apk --debug
```

真实设备至少测试：

1. 首次安装/重启，客户与产品持久；输入订单，多行计算符合业务截图。
2. 开单前后台切换、应用被系统回收、手动保存/自动保存草稿；再进入恢复，确认订单后草稿清除。
3. 10、100、1000 单的查询、补收款、总欠款及导出精确核账。
4. 打印不同数量的明细，中文/横向/跨页；分享 PDF 与两份 CSV。
5. **离机备份及恢复未实现前，不得录入唯一一份真实营业账。**

完整设计和阻断条件见 [工程审计](engineering-audit-2026-11-06.md)。
