# 验收矩阵：2026-11-07（持续迭代，CI 结果以当前提交为准）

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
5. **加密备份虽已实现自动化测试，但未经过真实设备离机恢复演练前，不得录入唯一一份真实营业账。**

完整设计和阻断条件见 [工程审计](engineering-audit-2026-11-06.md)。

## 兼容原 main 分支的设备记录（2026-11-06）

以下保留自 main@5c58989 的人工测试记录，**不是当前整改分支的真机验收**：

- Android 15 模拟器曾成功构建、安装、启动 Debug APK；最初一次 VM service/DevFS 连接失败，之后启动成功。
- 用户反馈客户新增表单无法输入；原 Widget 测试可模拟输入，但未验证实体设备的输入法事件。**真实软键盘问题仍未复现或证实修复**。
- 曾出现 `share_plus` Kotlin Gradle Plugin 的兼容提示，需要在真实构建与插件升级后复查。
- 原 main 保存的 7 项单测及本地运行记录属于历史版本，不能代替当前分支的 CI。


## v4 采购收货 + 库存流水（本批新增门禁）

| 场景 | 预期信号 | 自动化测试 | Android 现场 |
|---|---|---|---|
| 仓库新增与库存读取 | 仓库可重新读取，余额初始为 0 | `inventory_widget_test.dart` | 待验 |
| 采购下单无库存 | 下单后无库存流水 | `inventory_integration_test.dart` | 待验 |
| 分次收货与分仓/批次 | 30m + 70m = 100m，面积精确累加 | `inventory_integration_test.dart` | 待验 |
| 并发超收与幂等重试 | 相同键不重复、不同键超量失败 | `inventory_integration_test.dart` | 待验 |
| 采购取消与收货关联 | 已收货的订单拒绝直接取消 | `inventory_integration_test.dart` | 待验 |
| v3→v4 | 旧客户/采购订单不丢失，库存为空 | `inventory_integration_test.dart` | 待升级演练 |
| 加密备份与旧档 | v2/v3兼容、v4流水无孤儿/篡改 | `inventory_integration_test.dart` | 待验 |
| 安卓物理 SQLite | 测试库收货→关闭→重开保持一致 | `storage_device_test.dart`（需指定设备） | **未执行** |

> 自动化代码编写完成不代表 CI 或真机验证通过。只用测试数据进行设备测试；没有用户的安卓手机不能声称设备验收。
