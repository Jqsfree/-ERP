# Android 发布候选门禁（2026-11-16）

## 范围与状态

本门禁**不发布 Release、不修改手机、不删除现有 v0.1.9 包**。目前提供可核验的、仅从 `main` 精确提交构建的签名候选 APK，最终发放必须额外完成真机/升级验收和人工核对。

现存 `v0.1.9` 曾在对应提交 CI 完成前发布，且最终 CI 失败，因此不能将旧 Release 视为新的交付门禁通过证明。

## 受控流程

1. PR 的完整 Android `android` 检查（finance regression → full flutter test → flutter analyze → debug APK）全部通过；再按下述规则集要求合并到 `main`。
2. 在 `main` 更新 `pubspec.yaml` 的 **versionName 和 versionCode**，不得复用已存在的 `v0.1.9` 标签/包版本。保持对已安装版本的升级兼容。
3. 在仓库 Actions 运行 **Verified signed Android candidate**，分支选择 `main`，输入经过核对的完整 40 位 SHA。
4. 工作流先核对源码、版本、锁定依赖，再重新执行财务回归、全量测试、静态分析。**任一步失败都不会生成正式候选 APK**。
5. 签名材料必须来自 GitHub Secrets（与既有安装包使用相同的私钥/证书）。工作流通过 `apksigner` 检查 APK v2 签名，并与已有 v0.1.9 的证书指纹比对；通过 `aapt` 检查打包后的 applicationId、versionName、versionCode 与源码版本一致；任一不匹配即终止。
6. 仅上传私有工作流 Artifact：APK、SHA256SUMS.txt、SOURCE.txt、签名校验输出。候选通过不等于上线；Android 真实设备覆盖升级、重启、金额/余额/退款/库存核账、外部备份恢复和界面操作仍需要独立记录。
7. 最终人工核对候选 APK 与工作流 Artifact 的 SHA256 完全一致，验收 GO 后才能使用新版本号创建 GitHub Release。不得先创建 Release 再等待 CI。

## GitHub 仓库设置（需要有权限的维护者配置；仓库代码不能替代）

在 **Settings → Rules → Rulesets** 配置针对 `main` 的活跃规则，至少：
- Require a pull request before merging
- Require status checks to pass before merging：选择 **android** 检查，并启用 strict up-to-date（若可用）
- Block force pushes 和 restrict deletions

另为发布标签（`v*`）配置限制，禁止通过绕过 CI 的方式提前推送标签。人工通过 GitHub 网页直接创建 Release 同样不受本文工作流自动拦截，必须由仓库权限/规则约束。

## 签名 Secrets（绝不提交真实值）

需要在仓库 Secrets 配置以下四项：
- `ANDROID_RELEASE_KEYSTORE_B64`：**原有签名 keystore** 的 base64 文本
- `ANDROID_RELEASE_STORE_PASSWORD`
- `ANDROID_RELEASE_KEY_ALIAS`
- `ANDROID_RELEASE_KEY_PASSWORD`

预计证书 SHA-256：
`d5e48b89c69c2a9f10ad3944eaf8d87dce3dac40ee7c82e4528af9c42e7599ae`

若无法找到原有私钥，不能以新签名冒充可覆盖升级的发布版本；应停止发布候选构建，先设计合法升级/迁移方案。候选工作流会在缺少 Secrets 时失败，不会回退到 Debug 签名或无签名 APK。

## 交付证据

记录：完整 commit SHA、CI run URL、候选 run URL、`pubspec.yaml` 版本、APK SHA-256、证书 SHA-256、Android 真机验收记录（独立 PASS/FAIL/BLOCKED/NOT RUN），再做 GO/NO-GO 决策。

**现状不是已正式 GO**：在 CI、仓库规则、签名 Secrets 和真实设备验收都有通过证据之前，不得对外宣称正式版完成。
