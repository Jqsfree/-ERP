# MVP v0.1 收口契约：停止扩建，交付 Android 离线开单

制定：2026-11-07。当前基线：`main@078a44bae83a21cb2387588a406a91bf3bd25528`，合并后 GitHub Actions #42342791225 已通过。
本契约优先于此前“两模块一批”的**扩建排期**，不更改已合并历史，不声明目前已完成 MVP。

## 唯一目标

**让一个软装商户用一台安卓手机，在离线状态下稳定地完成一次“客户/产品 → 销售开单 → 收款/欠款 → 中文单据分享或打印 → 退出重开仍可查询”的真实业务闭环，并可以把所有营业数据安全带到新设备或新安装中。**

目标是可安装、可演示、可恢复、可升级的 **MVP v0.1 受控试用版**，不是完成 ERPNext 式财务总账，也不以 GitHub CI 全绿替代真机验收。

## 冻结范围（P0，不新增业务模块）

1. 客户/产品基本建档、查找/选择；有效的 Android 软键盘输入。
2. 多产品销售单：米数、门幅、元/平方米单价、逐行到分四舍五入、整单优惠、独立单号、客户资料及金额快照。
3. 首收款、后续部分收款、超额拒绝、客户欠款与历史列表准确且可重开。
4. 本地 SQLite 持久化与草稿恢复；进程结束、前后台恢复、覆盖升级后数据正确。
5. 离线中文 PDF（含多行和分页）打印/分享、订单和明细两份 CSV 导出。
6. AES-GCM 加密离机备份、文件真实保存到设备外、全新空库恢复与备份核对。
7. **可复制交付**：固定 Android applicationId/原生 runner 构建配置，稳定签名材料、递增 versionCode；安装、覆盖升级、数据保留在真实安卓上可验证。签名私钥不得进入 Git；不要求上架应用商店。
8. 清晰的操作反馈：提交成功/失败、离线、支付、分享与备份失败时有可判断的错误提示；不增加视觉改版或业务报表。

已写入的供应商、采购订单、库存流水、销售出库/退货、其他资金及日结模块**不删除，不做新功能开发**。它们不是 MVP 交付阻断项，但不能在试用版中被描述为“全功能已验”；如果发现这些模块影响 P0（崩溃、改写销售账、丢数据），应修复回归或对试用入口降级。不要为这些模块再创建第五、六批。

## 闸门与验收信号（按顺序，优先解决阻断项）

| 门禁 | 要执行的动作 | 可核查交付证据 |
|---|---|---|
| G0 基线 | 固定当前 main SHA 和 Flutter 3.47.9；确认真实需求中的 P0 金额公式与测试截图 | Git 状态/测试与原始 PRD 一致 |
| G1 真机基本操作 | Android 手机上的中文输入、客户/产品建档、37 × 2.8 × 13.99 − 0.36 = **1449.00**，另建至少一张多行销售单，补收、显示欠款，前后台及强杀后恢复 | 人工步骤、屏幕录制/截图、对应数据库结果；不得以 Widget 模拟代替 |
| G2 单据交付 | 离线模式下，生成 1、9、10、20 行 PDF，测试中文排版、分页、打印/分享目标；两份 CSV 在表格软件读取金额不重复 | 实际手机文件/打印预览，内容与数据库核对 |
| G3 数据安全 | 真实安卓上导出 `.kberp` 到设备外，再在**空数据库的隔离安装/另一台设备**恢复，核对客户、产品、销售、付款、草稿；非法口令/非空库恢复拒绝 | 外部备份文件存在、恢复前后记录计数与金额一致；不能在唯一原始账本上实验 |
| G4 可升级安装 | 固定应用 ID、签名、版本号与 Android runner；签名材料不入库。以同一签名安装 v0.1.0→v0.1.1，验证覆盖更新不卸载、不丢数据及此前备份可用 | 两个 APK 的签名指纹、applicationId/versionCode、adb 安装结果、数据库对比 |
| G5 最终回归和交付 | Flutter tests、严格 analyze、Debug+受控签名 APK 构建，按真实手机走至少 10 单的业务回归；记录剩余已知问题 | GitHub Actions 最终 SHA 全绿、受控签名 APK + SHA256、设备验收表、变更说明和回滚/恢复指引 |

注意：`integration_test/storage_device_test.dart` 测试的是隔离 SQLite 文件，不能单独证明真实应用界面的输入、打印/系统分享以及离机备份可用。真机验证参考 Flutter 官方集成测试与 Android 官方升级/签名规则。

## 需要优先修复的已知风险

- 原人工记录曾出现**客户新增表单在 Android 上无法输入**；没有最新设备复现和通过证据。优先重测及修复，不能把 CI Widget 输入等价为实体软键盘。
- Git 忽略整个 `android/`，CI 每次 `flutter create` 临时生成 runner。当前 Debug APK 不能证明稳定应用 ID / 签名可供真实经营数据无损更新。MVP 需固定这一交付链路。
- 当前只有 Debug APK 自动构建，缺少独立受控签名和版本升级测试。签名证书更换可能导致 Android 拒绝覆盖安装；**不得先卸载唯一一份有营业数据的 App**。
- 加密备份代码虽已有 SQLite 单测，但未在真实 Android 分享、外部保存并恢复演练；恢复逻辑仅支持**空数据库**，不是对现有账本的“合并导入”。
- 中文 PDF 的多行分页、打印机/系统分享和真实表格软件兼容性仍未得到实体手机验收。

## 本轮显式不做

不新增采购发票、供应商应付/付款、贷项通知单、退款、总账、税务、资产负债、仓库调拨、成本估值、多门店、多设备同步、账号/权限、可配置报表、扫码、蓝牙打印机适配、架构大重构和 UI 装饰性改版。

不要因为某个已有 P1 模块存在就要求把其整个领域逻辑补齐到“完整 ERP”。只修复影响 P0 主路径、数据安全或导致整体崩溃的明确问题。

## 退出标准：什么时候可以宣布 MVP 完成

`G1 + G2 + G3 + G4 + G5` 全部有可核查证据；P0 没有已知会导致金额错误、数据丢失、无法开单/收款/分享的阻断缺陷；安装包、版本和恢复指引可以交给试用者按步骤运行。

**完成后停止新功能开发，交付 MVP v0.1 受控试用；收集一次真实使用反馈再决定后续路线。** 不把“待做列表全部清零”当验收条件。

### Ubuntu + Android 本地验证指令

```bash
git fetch origin --prune
git switch main
git pull --ff-only origin main
git rev-parse --short HEAD
fvm flutter pub get --enforce-lockfile
fvm flutter test
fvm flutter analyze
fvm flutter build apk --debug
adb devices -l
fvm flutter test integration_test/storage_device_test.dart -d <Android设备ID>
fvm flutter run -d <Android设备ID>
```

**以上自动化命令只覆盖部分验收；G1–G4 的人工设备测试仍必须单独记录。**

## 参考

- 原始产品 P0：[PRD](prd.md)
- 真实设备和加密备份：[Ubuntu/Android 指引](ubuntu-device-and-backup-2026-11-07.md)
- 质量矩阵：[acceptance.md](acceptance.md)
- [Flutter Android release / signing](https://docs.flutter.dev/deployment/android)
- [Android 应用更新条件](https://developer.android.com/google/play/app-updates)
- [Flutter integration_test](https://docs.flutter.dev/testing/integration-tests)
