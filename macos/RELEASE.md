# LCT macOS 签名与发布指南

本文说明两件事：

1. **本地开发**怎么签名，让屏幕录制、麦克风、语音识别的授权在重新构建后保持有效。
2. **对外发布**怎么做：用 Developer ID 签名、公证、打成 DMG，让别人下载后能直接打开。

## 两种证书

| 用途 | 证书 | 门槛 | 别人能直接打开吗 |
|------|------|------|------------------|
| 本地开发 | Apple Development | 任何 Apple ID 都能在 Xcode 里生成 | 不能 |
| 对外发布 | Developer ID Application + 公证 | 需要付费的 Apple Developer Program 会员 | 能 |

`package-app.sh` 不会回退到 ad-hoc 签名：没有设置 `LCT_SIGN_IDENTITY` 就直接报错。这是故意的，避免把未正式签名的包当成发布包。

## 一、本地开发签名

macOS 按应用的签名身份记录隐私授权。ad-hoc 签名每次构建都会变，所以每次重新构建后都要重新授权。用 Apple Development 证书签名后，签名身份在多次构建之间保持不变，授权一次就够了。

1. 列出钥匙串里可用的签名身份：

   ```bash
   security find-identity -v -p codesigning
   ```

   每行开头的 40 位十六进制字符串是证书的 SHA-1 哈希。

2. 把身份写进 `~/.zshrc`。如果有**多张同名**的证书，`codesign` 会报 "ambiguous"，这时必须用 SHA-1 哈希：

   ```bash
   export LCT_SIGN_IDENTITY=<40 位 SHA-1 哈希>
   ```

   重新打开终端，或执行 `source ~/.zshrc`。

3. 打包：

   ```bash
   cd macos && ./package-app.sh && open LCTMac.app
   ```

   - 第一次签名时，钥匙串可能弹出 "codesign wants to sign using key…"，点 **始终允许**。之后不会再弹。
   - 签名带 `--timestamp`，需要能连上 Apple 的时间戳服务器。
   - 换成新的签名身份后，需要重新授权一次。之后用同一身份重新构建，授权会一直保持。

`Scripts/dev-cert.sh` 生成的自签名 "LCT Dev" 身份仍可使用，但 Apple Development 证书更可靠，推荐优先使用。

## 二、对外发布：一次性配置

前提：Apple Developer Program 会员申请已通过。下面的步骤只需要做一次。

### 1. 生成 Developer ID Application 证书

只有团队的 Account Holder 能生成这种证书。个人会员就是 Account Holder。

- **用 Xcode（推荐）**：Xcode → Settings → Accounts → 选中你的团队 → Manage Certificates… → 左下角 `+` → **Developer ID Application**。证书和私钥会直接进入登录钥匙串。
- **用网页**：在 developer.apple.com → Certificates 里新建 Developer ID Application，并上传 CSR。CSR 在「钥匙串访问 → 证书助理 → 从证书颁发机构请求证书」里生成。

确认生成成功：

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

记下完整的身份名，例如 `Developer ID Application: Peng Cheng (ABCDE12345)`。括号里的 10 位字符就是 Team ID。

### 2. 导出 .p12

打开「钥匙串访问」→ 登录 → 我的证书，找到 `Developer ID Application: …`。展开它，确认下面挂着私钥。右键 → 导出 → 文件格式选 `.p12` → 设置一个导出密码。

### 3. 生成 App 专用密码

在 account.apple.com → 登录与安全 → App 专用密码里新建一个，名字可以叫 `LCT notarization`。公证用的是这个密码，不是 Apple ID 的登录密码。

### 4. 在 GitHub 上配置 7 个 secrets

| Secret | 值 |
|--------|----|
| `LCT_DEVELOPER_ID_CERTIFICATE` | 第 2 步导出的 .p12，base64 编码 |
| `LCT_DEVELOPER_ID_CERTIFICATE_PASSWORD` | 第 2 步设置的导出密码 |
| `LCT_SIGN_IDENTITY` | 第 1 步记下的完整身份名 |
| `LCT_NOTARY_PROFILE` | 任意名字，例如 `lct-notary`（CI 里保存 notarytool 凭据用的标签） |
| `LCT_APPLE_ID` | 你的 Apple ID 邮箱 |
| `LCT_APPLE_ID_PASSWORD` | 第 3 步生成的 App 专用密码 |
| `LCT_TEAM_ID` | 10 位 Team ID |

用 `gh` 设置。每条命令都会提示你粘贴值，输入不会显示在屏幕上：

```bash
REPO=PCcoding666/LCT
base64 -i ~/Downloads/DeveloperID.p12 | gh secret set LCT_DEVELOPER_ID_CERTIFICATE --repo $REPO
gh secret set LCT_DEVELOPER_ID_CERTIFICATE_PASSWORD --repo $REPO
gh secret set LCT_SIGN_IDENTITY --repo $REPO
gh secret set LCT_NOTARY_PROFILE --repo $REPO
gh secret set LCT_APPLE_ID --repo $REPO
gh secret set LCT_APPLE_ID_PASSWORD --repo $REPO
gh secret set LCT_TEAM_ID --repo $REPO
gh secret list --repo $REPO          # 应该列出这 7 个名字
```

设置完后删掉本地的 .p12 文件。

## 三、发布一个版本

1. **改版本号**：编辑 `macos/VERSION`（格式必须是 `x.y.z`），合入 master。

2. **触发交付**：在 GitHub → Actions → "macOS Build and Release" → Run workflow，或者用命令：

   ```bash
   gh workflow run macos-build.yml --repo PCcoding666/LCT -f release-version=1.1.0 -f build-number=1
   gh run watch --repo PCcoding666/LCT
   ```

   这个 workflow 会依次：检查 7 个 secrets 是否都已配置 → 构建并测试 → Developer ID 签名 → 打成 DMG → 提交公证并 staple → Gatekeeper 验证。缺少任何 secret 时，它会在第一步失败并列出缺了哪些。

3. **下载 DMG**：

   ```bash
   gh run download <run-id> --repo PCcoding666/LCT -n LCT-macOS-dmg -D dist
   ```

   产物在 Actions 上保留 30 天。

4. **发布到 Releases**：

   ```bash
   gh release create v1.1.0 dist/LCT-1.1.0.dmg --repo PCcoding666/LCT --title "LCT 1.1.0" --notes "更新说明"
   ```

## 四、在另一台 Mac 上验收

一定要在**另一台** Mac 上，通过浏览器下载 DMG 来测。自己机器上构建出来的文件没有 quarantine 标记，测不出 Gatekeeper 的真实行为。

```bash
xcrun stapler validate LCT-1.1.0.dmg
spctl -a -vvv -t open --context context:primary-signature LCT-1.1.0.dmg
```

然后打开 DMG，把 LCT 拖到「应用程序」，双击启动。不应出现「无法验证开发者」或「已损坏」的提示，接着会进入权限引导。

**首次发布时的已知风险**：当前流程只给 DMG 里的 app 签名，DMG 本身不签名。Apple 支持对未签名的 DMG 做公证和 staple，但 CI 最后一步对 DMG 做 Gatekeeper 评估，未签名的 DMG 能否通过这一步，要等第一次真实发布才能确认。如果只有这一步失败，修复办法是在公证之前用 Developer ID 给 DMG 也签上名（`codesign --sign "$LCT_SIGN_IDENTITY" --timestamp LCT-x.y.z.dmg`）。

## 五、不走 CI，在本机手动发布（可选）

先把公证凭据保存进本机钥匙串，只需做一次：

```bash
xcrun notarytool store-credentials lct-notary --apple-id <Apple ID> --team-id <Team ID> --password <App 专用密码>
```

然后：

```bash
cd macos
export LCT_SIGN_IDENTITY="Developer ID Application: <姓名> (<Team ID>)"
RELEASE_VERSION=1.1.0 BUILD_NUMBER=1 ./package-app.sh
Scripts/create-dmg.sh LCTMac.app LCT-1.1.0.dmg
LCT_NOTARY_PROFILE=lct-notary Scripts/notarize-dmg.sh LCT-1.1.0.dmg
Scripts/verify-release-dmg.sh LCT-1.1.0.dmg
```
