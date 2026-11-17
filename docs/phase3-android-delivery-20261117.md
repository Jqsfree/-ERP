# 第三阶段：Android 交付验收（2026-11-17）

## 范围与门禁

本阶段冻结业务功能。前序 [PR #11](https://github.com/Jqsfree/-ERP/pull/11) 的独立预期值和真实 SQLite 场景通过自动化 CI；合并提交为 1712d657d13b9c60befdba4660e55afc0a609ab3。第三阶段候选版本拟为 **0.1.10+11**，仅用于验收，不代表正式发布。

证据按三个独立层级记录：桌面 CI、Android 原生 SQLite（隔离工作库）、同签名候选 APK 的实际设备 UI/升级/外部文件恢复。禁止互相替代。旧 v0.1.9 Release 和既有用户数据保持不变。

## A. 原生设备运行（仅空白测试手机）

Ubuntu 本地确认工具链及 USB 调试已授权：

```bash
git switch main
git pull --ff-only
bash scripts/doctor.sh
adb devices -l
bash scripts/accept-android-device.sh --device YOUR_SERIAL \
  --expected-sha "$(git rev-parse HEAD)" --confirm-test-device
```

仅在已确认用于测试且未安装 ERP 的实体 Android 设备上运行。脚本拒绝已安装同包名应用、模拟器、错误 SHA 和不洁工作树；不会执行卸载、清除数据或删除原业务库。Flutter 测试可能安装 Debug 应用，因此此手机不能用于后续同签名覆盖升级，需另外的隔离环境执行 B。输出目录中包含源码 SHA、设备型号、系统版本、原生存储/业务测试日志及独立结果。不要提交真实设备序列号、个人信息或业务数据。

共享测试与桌面 CI 使用同一个场景：
- 采购承诺 150 元；收货 30㎡、出库 15㎡、实物退货 7㎡，最终库存 22㎡。
- A 首收 200 元（微信）；累计退款 170 元、冲销 30 元、转余额 60 元；更换为客户 B 后各归属独立；B 现金收款 80 元。
- A 新单 90 元，支付宝首收 10 元、余额抵扣 60 元、次日银行补收 20 元。
- 首日微信 60、现金 80、支付宝 10 元；次日银行 20 元；两客户应收为零；幂等重试不重复入账。
- 真实文件备份、解密、还原到另一隔离库，关闭重开后逐表核对；检查外键及完整性。

A 通过只代表原生数据库和文件 API 通过，不代表 APK UI 或系统分享面板通过。

## B. 签名候选包及覆盖升级（隔离测试手机）

只使用 [受控签名工作流](verified-release-gate.md) 生成的候选 Artifact；四项原有签名 Secrets 必须就绪。确认最新 main CI 成功后，从 main 运行：
```bash
gh workflow run release-candidate.yml --ref main \
  -f expected_sha="$(git rev-parse HEAD)"
```

下载同一次成功执行的 Artifact，进入其目录核对：
```bash
sha256sum -c SHA256SUMS.txt
cat SOURCE.txt
apksigner verify --verbose --print-certs kaibao-sales-release.apk
aapt dump badging kaibao-sales-release.apk | head -n 1
```

要求 applicationId 为 com.kaibao.kaibao_sales，versionName=0.1.10，versionCode=11；
证书 SHA-256 必须与原 v0.1.9 一致（见签名门禁）。SOURCE.txt 的 commit 必须与批准的 main SHA 一致。公示正式 Release 之前不得更换签名、重新构建或修改这份 APK。

在隔离手机安装原签名 v0.1.9，使用**虚构数据**完成开单、收款、余额/退款、库存及日结，保存外部加密备份，记录订单号和各合计。确认备份已实际保存并可读取。仅验证证书、版本和备份后执行：

```bash
adb -s YOUR_SERIAL install -r kaibao-sales-release.apk
```

确认 Success，启动检查版本和全部前置账目；强制停止应用后再次启动核对。禁止因安装失败执行卸载、pm clear、降级或替换签名。若使用在役设备而非隔离测试设备，必须另行授权，不能套用上述命令。

## C. 正式候选 APK 人工验收矩阵（本次均 NOT RUN）

| ID | 前置与操作 | 可核验预期 | 初始状态 |
|---|---|---|---|
| D01 | 原签名旧版覆盖升级、重启 | 版本正确、订单、金额、库存、余额、待办不变 | NOT RUN |
| D02 | 首收渠道、草稿恢复、关闭重开、重复点击 | 正确首收、仅一个销售单、渠道正确 | NOT RUN |
| D03 | 出库→降量→实际退款/冲销→转余额→换客→实物退货→新单抵扣 | 符合 A 的核账数，历史和归属不变 | NOT RUN |
| D04 | 日结差异、当日冻结、次日补收 | 渠道合计正确，闭账后拒绝当日收款 | NOT RUN |
| D05 | 当前和历史单据存图、PDF、CSV、系统文件打开与分享取消 | 内容对应版本和净退款/余额；取消不误报保存 | NOT RUN |
| D06 | 外部分享实际保存加密文件；独立干净设备导入 | 文件非空可读；库恢复及重启后逐项核账 | NOT RUN |
| D07 | 错密码、损坏文件、非空库恢复、空间不足与启动异常 | 原数据库和已有交易保留；明确失败和重试反馈 | NOT RUN |
| D08 | 320/360/411dp、横屏、100/150/200%字体、键盘及返回 | UI01–UI22 无溢出和关键不可达；依现有范围记录缺口 | NOT RUN |
| D09 | 签名候选全新安装（另一干净设备） | 可正常开单、保存并重开 | NOT RUN |

D07 中模拟故障只能在隔离测试数据环境进行，不制造生产库损坏。
D08 必须核对 [完整 UI 标准](../UI_ACCEPTANCE_STANDARD.md)；B01 客户/产品资料编辑、启停等尚未宣称实现，旧版范围冻结不等于完整正式版验收。B06 输出需实看文件，不能仅检查导出调用成功。物理打印按现有范围不验收。

## D. 证据模板与结论

每轮复制本表到独立本地验收记录，实际填写；不得以预期当实测。记录候选 Source SHA、CI URL、候选工作流 URL、APK SHA-256、签名指纹、版本、设备型号、Android 版本。

| ID | 前置数据 | 实际操作 | 实际金额/数量/状态 | 日志/截图/输出文件证据 | PASS/FAIL/BLOCKED/NOT RUN |
|---|---|---|---|---|---|
| Dxx |  |  |  |  | NOT RUN |

自动化诊断、同签名候选、真机矩阵、完整验收范围分别签署。只有所有承诺门禁 PASS 且发布保护规则实际启用才允许正式 GO；本文件不是 GO 证明。保留经核对的同一份 APK，不在验收后重新打包。
