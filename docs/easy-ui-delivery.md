# 简化界面交付记录（2026-11-08）

版本0.1.4+5，应用标识com.kaibao.kaibao_sales，SQLite v9。本轮仅优化导航和销售操作，不改变金额、余额、收款或库存规则。

## 已实现

- 底部固定“开单／业务／设置”，首页仅快速开单、找单／保存图片与日期。
- 业务按客户与商品、采购与库存、收款与对账分组，设置集中备份及版本说明。
- 主要正文18、大金额22、主要按钮最小高度56；商品明细改纵向卡片。
- 开单分区，选填规格和备注折叠；底部固定合同金额与确认按钮，随键盘避让。
- 返回时保存最新草稿，恢复时明确提示未正式开单，重新填写需确认；改单退出保护及防重复保存。
- 详情优先展示图片状态、保存、分享、再开一单；改单、收款、打印等放在更多操作；待退款和待退货不折叠。
- 销售列表支持客户名、电话、单号本地搜索。

实现文件：lib/ui/pages.dart、lib/main.dart、pubspec.yaml。无数据库迁移。

## 验证矩阵

| 场景 | 实际结果 | 证据 | 状态 |
|---|---|---|---|
| 全量自动化，含真实SQLite开单/改单/余额/迁移/备份、图片生成 | 130项通过 | release-evidence/easy-ui-regression-20261108.log | PASS |
| 360dp、字体100%和200%的首页/编辑/返回/分页 | 无布局异常，退出保存草稿 | test/easy_ui_test.dart | PASS |
| 静态检查 | No issues found | release-evidence/easy-ui-analyze-20261108.log | PASS |
| Release APK构建 | 构建成功 | release-evidence/easy-ui-build-20261108.log | PASS |
| RMX3093 Android12 同标识同签名覆盖0.1.3+4 | adb install -r成功，版本5 | release-evidence/easy-ui-device-install-20261108.log | PASS |
| 真机首页、业务、设置、开单与键盘避让 | 已实际操作及截图检查 | release-evidence/easy-ui-device-*.log；build/easy-ui-device-evidence/ | PASS |
| 真机退出并重新进入草稿 | 显示“已恢复上次未完成内容”，未正式开单 | easy-ui-device-draft-20261108.log | PASS |
| 真机找单与强关重启 | 当前0单，重启可正常打开 | easy-ui-device-search-20261108.log | PASS |
| 新版真机确认新单、相册保存、带数据升级核账 | 本轮未新增正式交易，历史图片版证据独立保留 | invoice-images-delivery.md | NOT RUN |
| 新版真实打印、备份恢复、全ERP退款闭环 | 本轮未执行，部分功能仍缺失 | RELEASE_ACCEPTANCE_REPORT.md | NOT RUN |

为保护设备数据，本轮未清空应用、未创建验收客户或正式销售单。进入和退出开单会保留空白草稿。手机当前日期为2026-11-08。截图是本地构建证据，不加入Git。

## 安装包

- build/release-candidates/easy-ui-0.1.4+5.apk
- SHA256：1fef7386da2e6346ba7c8b6c6e70a9484a6b81b489b524587b00d0212e788338
- 签名证书SHA256：d5e48b89c69c2a9f10ad3944eaf8d87dce3dac40ee7c82e4528af9c42e7599ae

界面更新已安装交付；完整ERP发布决策仍为NO-GO，不能以界面回归通过替代尚缺的退款及完整设备验收。
