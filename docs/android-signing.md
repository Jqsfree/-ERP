# Android 签名与交付

应用 ID 为 `com.kaibao.kaibao_sales`，版本由 `pubspec.yaml` 管理。本机签名材料由用户保管，位于仓库外 `/home/jqs/Documents/kaibao-signing/`：`kaibao-release.jks` 是私钥库，`password.txt` 是其密码。证书 SHA-256：`D5:E4:8B:89:C6:9C:2A:9F:10:AD:39:44:EA:F8:D8:7D:CE:3D:AC:40:EE:7C:82:E4:52:8A:F9:C4:2E:75:99:AE`。切勿提交、公开或通过不安全渠道发送这些文件。

**备份尚未完成。** 请将密钥库复制到用户控制的加密离线介质，并单独安全保存密码；验证备份可读取后，将介质与本机分开保管。丢失密钥可能导致无法为现有安装提供同签名升级。此过程需用户提供和管理备份介质。

本机 `android/key.properties` 是被 Git 忽略的本地配置，包含密钥路径、别名和密码；迁移构建机时由保管人安全配置，不应提交。配置后执行：

```sh
fvm flutter pub get --enforce-lockfile
fvm flutter test
fvm flutter analyze
fvm flutter build apk --release
sha256sum build/app/outputs/flutter-apk/app-release.apk
apksigner verify --verbose --print-certs build/app/outputs/flutter-apk/app-release.apk
```

发布前核对包名、版本、证书指纹与产物哈希，并保存构建所用提交和工作树状态。相同 application ID 的原地升级要求签名兼容、版本号不降低；先核对现有安装的证书，并在独立测试环境验证备份和升级。**不要卸载或清除含业务数据的现有应用来绕过签名冲突。** 新密钥不自动兼容旧版安装。

实际分享、离机保存、空库恢复及同签名升级尚未完成真机验收；签名包不代表适合正式经营。初次正式安装及未来升级前应先验证独立可恢复的业务备份。

## 2026-11-07 本机构建记录

- 工作树基于 `2cd879a`，包含未提交改动，不能将产物视为该提交的可复现构建。
- `0.1.0+1` release APK 构建成功；SHA-256 为 `8436629c3a8f1206121d31d30885388352d0c6c1ead44362b1a65e22aa4bcf60`，`apksigner` 验证 v2 签名通过，证书指纹与上文一致。
- 已连接 RMX3093（Android 12）上现有同包名安装的证书为 Android Debug，SHA-256 为 `2162403df0a44722a462646e0afbe8864a5f05cd4bb629181c5158707bb048b4`，与新证书不同，不能以新签名直接原地升级。未安装、卸载或清除该应用。

## 更名与安装

经用户明确要求，已将桌面名称改为“凯堡软装”，卸载 RMX3093 上的旧 debug 签名版本并安装新签名版本，ADB 安装及启动命令成功。卸载删除了旧安装的本地数据；未验证数据恢复。新 APK SHA-256 为 `e471b0241e53f94647771c2ca61fd957dc2fa6e23314c545986b8199a8c49dbb`，替代上方更名前的构建哈希。设备完整业务、分享和备份恢复验收仍待完成。
