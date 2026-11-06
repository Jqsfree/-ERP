# GitHub 仓库与发布状态

本项目已关联 GitHub 仓库 [`Jqsfree/-ERP`](https://github.com/Jqsfree/-ERP)，默认分支为 `main`，仓库当前为公开。`scripts/publish_github.sh` 仅用于创建一个**新仓库**，并会在目标仓库已存在时终止；不要对本项目运行该脚本。

推送现有仓库的提交：

```bash
git push origin main
```

`.github/workflows/android.yml` 会在 push 和 Pull Request 时生成 Android runner、获取依赖、运行测试与静态分析，并构建 Debug APK。Debug APK 仅用于内部验证，不可作为正式发布包。

已知的本地验证结果和未解决问题见 [`acceptance.md`](./acceptance.md)。特别是，新增客户表单的 Widget 单测通过，但 Android 模拟器的真实键盘输入链路尚未确认；不得将其描述为已修复或已完成设备验收。

公开仓库不得包含真实客户、电话、付款等业务隐私。正式 APK 需要独立签名凭据和发布策略。
