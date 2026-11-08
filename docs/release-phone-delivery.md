# 手机升级与交付包验收（2026-11-08）

## 最新手机更新：0.1.9+10 / SQLite v11

按用户要求，已核对签名并覆盖更新RMX3093，原验收数据保留。
修正设置页旧版本文字后重新构建安装；最终APK SHA-256：
`99fdf53dabb16d20bf3158128ceede035ef555e50882f1ed6cfb5786529bc79e`。
重启后原两单金额不变，数据检查未发现异常，退款页面可正常打开。
未通过新增交易模拟退款；完整退款真机业务链待执行。
详见[退款更新记录](refunds-and-reversals.md)和release-evidence/refund-device-*。

以下为0.1.8历史记录。

## 发布决定：NO-GO（完整ERP范围）

0.1.8+9为已签名的Release交付候选包，不标记完整ERP正式版GO。原需求中的实际现金退款/退款日结、客户商品编辑停用等仍有缺口，真实打印及完整设备备份恢复也未补齐。本轮没有发布到外部商店、推送Git或创建公开Release。

## 已执行

- 用户明确确认手机两张单据均为验收数据，允许不备份直接覆盖升级并保留记录。
- RMX3093 Android12以adb install -r从0.1.7+8升级至0.1.8+9，应用标识及签名相同，启动完成v9→v10迁移，数据检查返回未发现异常。未读取Android私有SQLite文件，不冒充直接SQL证据。
- 原XS202611080001合同56元、原已收20元、未收36元；新增1元验收收款（仅软件登记，无实际支付转账）。强关重启后显示已收21元、未收35元；重新进入收款页显示上次已入账，需要明确登记另一笔才能发起新意图。没有再次确认新收款。
- 原XS202611080002仍合同1176元、未收1176元。两单及验收客户保留，没有清空应用或删除历史。
- 保存原单最新图片至凯堡软装相册，拉取手机实际PNG人工检查：ACCEPTANCE-FABRIC完整，已收21/未收35正确。
- 收款后再次数据检查未发现当前覆盖范围内异常，手机返回正常开单首页。

## UI与溢出检查

新增release_layout_test覆盖360dp/200%字体、长客户/商品名称、商品步骤到核对页、280dp键盘遮挡、收款已入账恢复、历史详情展开更多操作和余额流水。结合既有查单/首页等测试，本轮已测路径未发现RenderFlex溢出。

不能据此宣称所有页面都完善或任意设备均无溢出：采购、日结等外围页面没有参加本轮全面布局验收。真机字体原值0.9，尝试切换200%被Android WRITE_SETTINGS权限拒绝，读回仍0.9；未提高系统权限，真机200%项目BLOCKED，不计PASS。数值溢出由独立金额、面积及恢复恶意快照回归覆盖，区别于UI溢出。

## 测试与证据

全量148项通过，静态检查No issues found。Release APK复用已构建并签名验证的0.1.8+9：本轮仅新增布局测试并完善测试异步等待，没有改动生产代码，包哈希与此前修复包一致。

首次全量运行出现改单UI测试等待未完成的SQLite读取，保留release-first-run-lock-20261108.log；修正为等待欠款/余额/待办加载结束后才发起测试读取，原金额、版本、库存和回滚断言不变。专项通过，随后完整148项通过。不是通过跳过用例或修改业务预期取得通过。

日志位于release-evidence/release-{device-install,device-version,device-integrity,device-integrity-after,device-payment-review,device-payment-posted,device-payment-recovered,device-orders-restart,device-image,device-font200,final-regression,final-analyze}-20261108.log。实际PNG和截图位于build/release-device-evidence/。

NOT RUN：真机实际退款（未实现）、物理打印、加密备份导出后设备恢复全链路、所有外围页面和跨设备兼容矩阵。自动化、已有历史测试及模拟收款不能代替这些项目。

## 交付文件

- build/deliveries/kaibao-0.1.8/凯堡软装-0.1.8.apk
- build/deliveries/凯堡软装-0.1.8-交付包.zip（APK、使用说明、当前发布验收说明、校验值）
- APK SHA256：5f74f696afea1cfd3a7db9de4f86a6a7faf8aa18e58ad5ea6b5a17e39c473f08

软件数据只在手机本地，交付APK不包含验收客户和单据。其他手机全新安装为空数据；当前RMX3093按用户要求保留验收记录。开始真实经营前应做好数据用途区分和备份，不在本轮擅自清除验收账。
