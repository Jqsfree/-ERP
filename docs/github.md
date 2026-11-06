# GitHub 发布方案

当前 GitHub 连接只开放已有仓库文件/分支/PR 操作，**不提供创建新仓库功能**。因此项目交付时未声称已远端推送。

维护者在本机已登录 GitHub CLI 时，在项目根目录执行：

```bash
bash scripts/publish_github.sh Jqsfree/kaibao-sales-app
```

安全规则：默认创建 **private** 仓库；如果仓库已经存在，脚本主动终止，不对既有项目覆盖推送。新仓库生成后，CI `Android debug build` 自动跑测试、分析并上传调试 APK。安装真机前务必检查 Actions 成功日志。

如改为公开仓库，先核查代码、样例、日志、CI 工件和提交历史中没有真实客户、电话、付款等业务隐私。正式 APK 必须另配签名凭据和交付渠道，不能把 debug APK 当生产发布包。
