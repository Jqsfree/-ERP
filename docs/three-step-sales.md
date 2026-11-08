# 三步开单第一阶段

新开单分为选客户、填商品、核对金额；仅最后一步可生成销售单并自动保存图片。已确认单编辑保持原操作布局，本阶段不扩展其他操作页。

- 客户可按名称、电话搜索，也可新增后自动选中。
- 下一步校验当前字段，失败滚动定位首个错误；米数、门幅大于0且最多3位小数，单价非负最多2位，优惠及首收不得超额。
- 上一步保留输入；新草稿保存步骤，兼容旧schema1草稿（从第一步开始）。未新增数据库迁移。
- 删除有内容的商品行需确认，至少保留一行。
- 最后一步核对客户、商品、金额和预计余额抵扣，余额读取失败阻止提交，可重试。数据库继续最终核算和事务保护。
- 保存成功但图片失败仍属于已开单，应补存图片，不重新开单。

验证日志：release-evidence/three-step-regression-20261108.log、three-step-analyze-20261108.log。新增专项测试覆盖未选客户、搜索选客、零米数阻止继续、往返保留、草稿恢复步骤；原真实SQLite余额开单测试已切换三步操作，金额断言保持。

## 真机更新（2026-11-08）

0.1.5+6已通过adb install -r覆盖RMX3093 Android12，包名与签名证书保持一致，未清空数据。构建、安装、签名及哈希见release-evidence/three-step-{build,install,signature,sha256}-20261108.log。

- PASS：安装后版本6；旧草稿从第一步恢复；未选客户点击下一步显示请选择客户并阻止继续；强关重启后仍可恢复草稿。
- 用户已授权新增并保留验收客户/单据。真机新增ACCEPTANCE-ONLY-20261108，单号XS202611080001，商品ACCEPTANCE-FABRIC，2米×2.8米×10元=56元，优惠0、现金首收20、余额抵扣0、未收36。
- PASS：商品必填与零米数拦截、步骤返回保留输入、100元超额优惠拦截、改正后提交、自动保存图片、系统相册打开、强关重启后核对、修复包同版本覆盖后仍仅1张单据。
- 发现并修复：提交校验失败后旧错误未随输入修正刷新；现为尝试继续/提交后实时重新校验。修复后131项全量测试、静态检查、Release构建通过；真机验证修正商品型号立即清除其错误，其他未填字段仍提示。
- PASS：客户搜索弹层可选择验收客户。关键词输入过滤由自动化验证，未单列真机通过。
- NOT RUN：本轮实体打印、新版200%系统字体及完整键盘专项、真实SQLite私有库直接读取。真机核账证据为重启后应用读取结果，不冒充SQL证据。
- 输出限制：长商品型号在图片产品列会省略，当前验收图为ACCEPTANCE-F...；此为现有打印版式限制，未在本轮扩展图片版式。
- 验收记录保留，另留有一份未提交的ACCEPTANCE-DRAFT草稿，无第二张正式单。未清空数据。
- 日志：release-evidence/three-step-device-{zero,back,discount,saved,gallery,ledger-restart,detail-restart,error-refresh,final-ledger}-20261108.log；图片为build/three-step-device-evidence/invoice.png。

APK：build/release-candidates/three-step-0.1.5+6.apk，SHA256 17c83d5dee8f4353de6faa32b62b6f9457c94b36f8aed349ced4e5bb2b033cc6。截图在build/three-step-device-evidence/。完整ERP发布结论保持NO-GO。
