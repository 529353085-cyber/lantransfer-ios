# 章鱼快传 iOS 版 — TestFlight 构建与分发操作指南

> 适用对象：在中国大陆、没有 Apple Developer 账号、没有 Mac 的开发者。
> 目标：通过 Codemagic 云构建，把「章鱼快传」打包成签名后的 .ipa，上架 TestFlight 供测试员安装。
> 全程不需要 Mac；只有「注册账号、填表、上传文件、点按钮」在本地电脑或手机上完成即可。

---

## 第 0 部分：现状说明

### 0.1 为什么现在装不上

「章鱼快传」是原生 iOS 应用，使用 SwiftUI 与 Network.framework 开发。苹果对 iOS 应用的分发有严格管控：

- 直接把源码或 .ipa 发给别人，iPhone 是无法安装的。iOS 只接受两类安装来源：App Store，以及 TestFlight。
- 安装到真机的每一个 App 都必须用苹果签发的「证书」和「描述文件（provisioning profile）」签名。没有签名或签名无效，安装会被拒绝。
- 生成签名产物、执行打包（archive）这一步需要 macOS + Xcode。你没有 Mac，所以这一步要借助 Codemagic 的云端 macOS 构建机器完成。
- 分发到 TestFlight 需要一个付费的 Apple Developer Program 账号（免费 Apple ID 不行）。

因此，要让别人装上这个 App，必须先补齐三样东西：**付费开发者账号**、**签名材料**、**云构建＋TestFlight 发布**。

### 0.2 前置条件清单

| 前置条件 | 说明 |
| --- | --- |
| Apple Developer Program 账号 | 个人 $99/年（人民币约 688 元/年，以苹果实际定价为准）。免费 Apple ID 不能上架 TestFlight。 |
| 可国际支付的信用卡 | 用于支付年费；Apple ID 需绑定该支付方式。 |
| 一个专用邮箱 | 建议用与 Apple ID 绑定的邮箱，用于接收苹果的验证与通知。 |
| GitHub 账号 | 用于托管源码并登录 Codemagic。国内访问 GitHub 可能较慢，请提前准备好网络环境。 |
| Codemagic 账号 | 用 GitHub 登录，免费额度对本项目足够。 |
| 一部 iPhone | 作为测试员安装 TestFlight 与被测 App。 |

### 0.3 App 本身的已知约束（发布前需知）

- 需要 iOS 16 及以上系统。
- 首次启动会弹出「本地网络」权限请求，用户必须点「允许」，否则发现不到局域网设备。
- 传输必须保持 App 在前台，切到后台传输不可靠。
- UDP 广播到 255.255.255.255 在 iOS 上不可用，发现主要依赖 Bonjour（mDNS）。

---

## 第 1 部分：申请 Apple Developer Program

1. 准备一个 Apple ID。若没有，到 Apple ID 管理页面注册；建议开启两步验证。
2. 在 Apple ID 账户的「付款与配送」中添加一张可用于国际支付的信用卡（Visa / MasterCard / 银联双币卡等）。
3. 打开 Apple Developer 官网，进入「注册 Apple Developer Program」，用上面的 Apple ID 登录。
4. 选择成员类型：
   - **个人（Individual）**：以个人名义注册，需提供姓名与身份证明信息，年费 $99。开发者名称显示为你的个人姓名。适合个人项目，流程最快。
   - **组织（Organization）**：以公司/机构名义注册，需提供营业执照、邓白氏编码（D-U-N-S Number）等材料，年费同样 $99。开发者名称显示为公司名称，适合公司产品，但审核更久、材料更多。
   - 本指南按**个人**类型说明。若你是公司主体，请选择组织并准备相应材料。
5. 按提示填写信息、同意协议、支付年费。付费后账号通常很快生效，个别情况需等待苹果审核邮件。
6. 生效后，在 Apple Developer 后台的 Membership 页面记下 **Team ID**（形如 `1A2BC3D4E5`），后面会用到。

---

## 第 2 部分：在 Apple Developer 后台创建 App ID 与签名材料

### 2.1 创建 App ID（Identifiers）

1. 登录 Apple Developer 后台，进入「Certificates, Identifiers & Profiles」（证书、标识符与描述文件）。
2. 左侧选择「Identifiers」，点右上角的「+」。
3. 选择「App IDs」，点「Continue」。
4. 类型选「App」，点「Continue」。
5. 填写：
   - Description（描述）：`章鱼快传`，便于自己识别即可。
   - Bundle ID：选择「Explicit」，填入 **`com.lantransfer.ios`**。此值必须与工程中的 Bundle Identifier 完全一致，不能多一个字符。
6. 在 Capabilities（能力）列表中，**不需要为本 App 勾选任何特殊 entitlement**。
   - 说明：本地网络访问不是靠勾选 Capability 实现的，而是靠在工程的 `Info.plist` 中添加 `NSLocalNetworkUsageDescription` 字段（本工程已包含）。用户首次使用时系统会据此弹出授权弹窗。
   - 不要勾选 Associated Domains、Push Notifications 等无关能力，否则描述文件需要同步包含，容易出错。
7. 点「Continue」→「Register」，完成 App ID 创建。

### 2.2 创建 Distribution Certificate（分发证书）

1. 在「Certificates, Identifiers & Profiles」左侧选择「Certificates」，点「+」。
2. 类型选择「Apple Distribution」（用于上架 App Store / TestFlight），点「Continue」。
3. 系统要求上传一个 CSR（证书签名请求）文件。CSR 可以用 Mac 的「钥匙串访问」生成；没有 Mac 时，可以让 Codemagic 自动管理签名（推荐，见第 3 部分），这样就不需要自己创建证书和上传 CSR。
   - **推荐路线**：跳过手动创建证书，使用 Codemagic 的 Automatic Code Signing（自动签名），由 Codemagic 通过 App Store Connect API Key 自动创建并管理分发证书与描述文件。第 3 部分会说明。
   - **手动路线**：若坚持手动签名，需要在 Mac 上生成 CSR，创建证书后下载 `.cer` 文件，再导出 `.p12` 上传 Codemagic；没有 Mac 时不建议走这条路。
4. 本指南后续默认采用**自动签名**路线，因此这里不在 Apple Developer 后台手动创建证书。

### 2.3 创建 App Store provisioning profile（描述文件）

同样，自动签名路线下，描述文件由 Codemagic 自动生成与更新，无需手动创建。

若你需要手动创建（例如本地打包，见第 7 部分），步骤如下：

1. 左侧选择「Profiles」，点「+」。
2. 类型选择「App Store」，点「Continue」。
3. App ID 选择 `com.lantransfer.ios`，点「Continue」。
4. 选择上面创建的分发证书（Distribution Certificate），点「Continue」。
5. 填写 Profile Name，例如 `LanTransfer App Store`，点「Generate」。
6. 下载生成的 `.mobileprovision` 文件备用。**请记住这个 Profile Name，它必须与 `exportOptions.plist` 中的值一致。**

---

## 第 3 部分：注册 Codemagic 并配置集成

### 3.1 注册与连接仓库

1. 打开 Codemagic 官网，选择「Sign up」，用 **GitHub 账号登录**（推荐，省去单独注册）。
2. 首次进入时选择免费方案（Free plan）。免费方案对本项目足够。
3. 进入 Applications 页面，点「Add application」。
4. Git provider 选择「GitHub」。若提示授权，按提示安装 Codemagic 的 GitHub App，并只授权你准备存放本工程的仓库。
5. 选择仓库，点「Next」→ 项目类型选「iOS App」→「Finish」。

### 3.2 创建 App Store Connect API Key（关键步骤）

Codemagic 需要一个 API Key 来与苹果通信（自动签名、上传 TestFlight）。

1. 登录 App Store Connect。
2. 进入「用户和访问（Users and Access）」→「集成（Integrations）」→「App Store Connect API」。
3. 点「+」生成新密钥：
   - 名称：例如 `Codemagic LanTransfer`。
   - 访问权限（Access Level）：选 **Admin**（或 App Manager）。文档要求至少 App Manager；选 Admin 最稳妥，能覆盖自动签名与上传所需权限。
4. 点「Generate」，生成后立即**下载 .p8 私钥文件**并妥善保存——**这个私钥只能下载一次，丢失后无法重新获取，只能重新生成密钥**。
5. 在密钥列表中记下：
   - **Issuer ID**（页面上方显示，形如 `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`）。
   - **Key ID**（生成后列表中的一串字符）。

### 3.3 在 Codemagic 中添加 Apple Developer 集成

1. 在 Codemagic 进入团队设置（Team settings）→「Integrations」。
2. 找到「Developer Portal」（或 Apple Developer Program）集成，点「Connect」。
3. 填写：
   - App Store Connect API key name：给这个集成起个名字，例如 `lantransfer-appstore-key`。
   - Issuer ID：填第 3.2 步记下的 Issuer ID。
   - Key ID：填第 3.2 步记下的 Key ID。
   - API key：上传第 3.2 步下载的 `.p8` 私钥文件。
4. 点「Save」保存。

> 对应到 `codemagic.yaml`：
> - `integrations.app_store_connect` 引用此集成（留空则用默认集成；若你起了名字，填入该名字）。
> - `environment.ios_signing.distribution_type: app_store` 与 `bundle_identifier: com.lantransfer.ios` 让 Codemagic 自动准备分发证书与描述文件。

### 3.4 配置 Team ID 与 Profile Name

在 Codemagic 项目设置 →「Environment variables」中添加两个变量（推荐，避免把值写进仓库）：

| 变量名 | 值 | 说明 |
| --- | --- | --- |
| `TEAM_ID` | 你的 Team ID | 第 1 部分末尾记下 |
| `PROFILE_NAME` | `LanTransfer App Store` | 自动签名时 Codemagic 生成的描述文件名，或你手动创建的名字 |

若不用环境变量，也可以直接编辑 `codemagic.yaml` 中 `vars` 下的同名占位符。

**重要**：`exportOptions.plist` 中 `provisioningProfiles` 的键必须是 `com.lantransfer.ios`，值必须与真实的描述文件名称完全一致（大小写、空格都要一致），否则导出会报签名错误。

---

## 第 4 部分：推送工程到 GitHub 并触发构建

1. 把本 `ios/` 目录的内容初始化为 Git 仓库并推送到你第 3.1 步授权的 GitHub 仓库。至少要包含：
   - `LanTransfer.xcodeproj`（Xcode 工程）
   - `LanTransfer/`（源码目录）
   - `codemagic.yaml`
   - `exportOptions.plist`
   - `TESTFLIGHT_GUIDE.md`、`README.md`
2. 确认 `codemagic.yaml` 的路径设置正确：
   - 若仓库根目录就是 `ios/` 的内容，无需改动 `XCODE_PROJECT`，保持 `LanTransfer.xcodeproj`。
   - 若推送的是整个项目（含 `android/`、`desktop/`、`ios/`），把 `XCODE_PROJECT` 改为 `ios/LanTransfer.xcodeproj`，并在 Codemagic 项目设置中把配置文件路径指向 `ios/codemagic.yaml`（或把该文件复制到仓库根目录）。
3. 提交并推送：
   ```bash
   git add .
   git commit -m "Add iOS project and Codemagic config"
   git push
   ```
4. 在 Codemagic 的 Applications 页面打开对应应用，点「Start new build」。
5. 选择 workflow `lantransfer-testflight`，点「Start new build」。
6. 等待构建完成（最多 120 分钟，通常十几分钟）。可以在线查看实时日志。
   - 国内访问 Codemagic 控制台可能较慢，请耐心等待；构建是在云端进行，与你本地网络无关。

---

## 第 5 部分：在 TestFlight 中查看构建并添加测试员

### 5.1 在 App Store Connect 查看构建

1. 构建并发布成功后，登录 App Store Connect，进入你的 App（若还没有 App 记录，需先创建一个，Bundle ID 填 `com.lantransfer.ios`）。
2. 进入「TestFlight」标签页。
3. 在左侧选择对应的构建版本，可看到：
   - 版本号（Version）与构建号（Build）。
   - 构建处理状态：刚上传时会显示「正在处理」，通常几分钟到几十分钟后变为可测试。
   - 若配置了 `submit_to_testflight: true`，构建会自动提交给 **Beta App Review（Beta 应用审核）**。

### 5.2 Beta App Review（必读）

- TestFlight 分「内部测试」和「外部测试」：
  - **内部测试员**：你在 App Store Connect 中添加的内部用户（通常是团队成员），**不需要**经过 Beta App Review，构建处理完即可安装。上限 100 人。
  - **外部测试员**：通过公开链接或邮件邀请的外部人员，**必须**先通过 Beta App Review 才能收到邀请。首次提交需要填写审核信息（测试说明、联系人等），苹果通常在一个工作日内审核，偶尔更久。
- 本项目的 `submit_to_testflight: true` 会自动提交 Beta 审核。若你只想先给内部人员测试，可以把它改为 `false`，并把发布范围限制为内部测试。
- 每个新版本首次给外部测试员时都需要重新审核；同一版本内追加构建通常不需要重复审核。

### 5.3 添加测试员

1. 在 TestFlight 页面选择「 testers（测试员）」或「Groups（群组）」。
2. 创建外部测试群组（例如 `LanTransfer-外部测试`），添加测试员邮箱。
3. 选择刚上传的构建，点「Add Build」把构建分配给该群组。
4. 苹果审核通过后，测试员会收到邀请邮件。

### 5.4 测试员如何安装

1. 测试员在 iPhone 的 App Store 搜索并下载 **TestFlight** App（免费，需非中国大陆区 Apple ID；若 Apple ID 是中国大陆区，可能需要切换到美区或其他区来下载 TestFlight 和获取邀请，这是 TestFlight 的客观限制）。
2. 打开邀请邮件，点击「View in TestFlight」或按邮件中的兑换码提示操作。
3. 在 TestFlight 中接受邀请，即可看到「章鱼快传」，点「安装」。
4. 安装后首次启动，系统会弹出「本地网络」权限请求，请点**允许**。
5. 确保手机与桌面/Android 设备处于**同一 Wi-Fi 局域网**，即可开始互传。

---

## 第 6 部分：常见错误排查

| 现象 | 可能原因 | 处理办法 |
| --- | --- | --- |
| 构建日志报 `No matching provisioning profiles found` / 签名失败 | 描述文件未上传到 Codemagic，或 Bundle ID/Team ID 不匹配 | 检查 `ios_signing` 的 bundle_identifier 是否为 `com.lantransfer.ios`；在 Codemagic Code signing identities 中确认有 app_store 类型的描述文件；确认 TEAM_ID 正确。 |
| 导出时报 `provisioningProfiles` 相关错误 | `exportOptions.plist` 中描述文件名与真实名称不一致 | 核对 `PROFILE_NAME` 与 Apple Developer 后台描述文件名称完全一致（含空格、大小写）。 |
| `Bundle ID does not match` / 上传被拒 | App ID 的 Bundle ID 与工程不一致 | 确认 Apple Developer 后台创建的 App ID 为 `com.lantransfer.ios`，且与工程 `PRODUCT_BUNDLE_IDENTIFIER` 完全一致。 |
| 提示描述文件不含设备 / device not registered | 误用了 development/ad_hoc 描述文件 | 上传到 TestFlight 必须用 `app_store` 分发类型；不要在 `ios_signing` 中写 `development`。 |
| App 装不上或安装后立刻退出 | 签名无效或实体未通过审核 | 在 App Store Connect 查看构建处理状态与审核结果；查阅 Codemagic 构建日志中的签名步骤。 |
| 首次启动发现不到设备 | 「本地网络」权限被拒绝 | 到 iOS 设置 > 隐私与安全性 > 本地网络，打开「章鱼快传」的开关；重启 App。 |
| 传输中途中断 | App 被切到后台或锁屏 | 保持 App 在前台并保持屏幕常亮；iOS 后台传输不可靠。 |
| 搜不到 UDP 广播设备 | iOS 不支持向 255.255.255.255 广播 | 这是平台限制，请使用 Bonjour（mDNS）发现；确保两端在同一局域网且未开启 AP 隔离。 |
| 外部测试员收不到邀请 | Beta App Review 未通过，或测试员 Apple ID 区域问题 | 在 App Store Connect 查看审核状态；确认测试员邮箱正确；必要时改用内部测试员。 |
| TestFlight 构建到期无法打开 | TestFlight 版本 90 天有效期 | 发布新版本构建以重置 90 天周期（见下）。 |

### TestFlight 90 天有效期

- 每个 TestFlight 构建版本自苹果审核通过之日起 **90 天有效**，到期后测试员将无法继续安装/打开该版本。
- 解决方式：发布一个新的版本号（例如 1.0.1），构建并上传新版本，90 天周期重新开始。
- 建议维护一个版本节奏，避免临近到期造成测试中断。

### 外部测试员上限

- TestFlight 外部测试员上限为 **10000 人**（按 App 计）；内部测试员上限 **100 人**。
- 首次邀请外部测试员必须通过 Beta App Review。

---

## 第 7 部分：不用云构建时 — 在 Mac + Xcode 本地打包（简要）

如果你后续有了 Mac，可绕过 Codemagic 本地打包：

1. 在 Mac 上安装 Xcode（App Store），用 Apple ID 登录 Xcode → Preferences → Accounts，添加你的 Developer Team。
2. 打开 `LanTransfer.xcodeproj`，在 Target「LanTransfer」的 Signing & Capabilities 中：
   - Team 选择你的个人团队。
   - Bundle Identifier 填 `com.lantransfer.ios`。
   - 勾选「Automatically manage signing」。
3. 确认 `Info.plist` 含 `NSLocalNetworkUsageDescription`。
4. 顶部 Scheme 选 `LanTransfer`，设备选「Any iOS Device (arm64)」。
5. 菜单 Product → Archive，等待归档完成，在 Organizer 中点「Distribute App」→「App Store Connect」→「Upload」，按向导上传。
6. 上传后在 App Store Connect 的 TestFlight 中即可看到构建，后续步骤与第 5 部分相同。

本地导出 .ipa 时若用命令行 `xcodebuild -exportArchive`，同样使用本目录的 `exportOptions.plist`，并把两个占位符替换为真实值：

```bash
xcodebuild -exportArchive \
  -archivePath <你的.xcarchive路径> \
  -exportPath ./build/ipa \
  -exportOptionsPlist exportOptions.plist \
  -allowProvisioningUpdates
```

---

## 附录：接下来要做的事（Checklist）

| # | 事项 | 完成后标记 |
| --- | --- | --- |
| 1 | 注册/确认 Apple Developer Program（个人 $99/年），记下 Team ID | [ ] |
| 2 | 在 App Store Connect 创建 App 记录，Bundle ID `com.lantransfer.ios` | [ ] |
| 3 | 创建 App Store Connect API Key（Admin/App Manager），下载 .p8，记下 Issuer ID 与 Key ID | [ ] |
| 4 | 用 GitHub 注册/登录 Codemagic，连接存放本工程的仓库 | [ ] |
| 5 | 在 Codemagic 添加 Developer Portal 集成（填 Issuer ID / Key ID / .p8） | [ ] |
| 6 | 在 Codemagic 配置环境变量 `TEAM_ID`、`PROFILE_NAME` | [ ] |
| 7 | 确认 `codemagic.yaml` 中 XCODE_PROJECT 路径与仓库结构一致 | [ ] |
| 8 | 把 `ios/` 工程推送到 GitHub | [ ] |
| 9 | 在 Codemagic 启动 `lantransfer-testflight` 构建并确认成功 | [ ] |
| 10 | 在 App Store Connect > TestFlight 看到构建并处理 Beta App Review | [ ] |
| 11 | 添加测试员（先内部后外部），发送邀请 | [ ] |
| 12 | 测试员在 iPhone 安装 TestFlight 与 App，允许本地网络权限并验证互传 | [ ] |
| 13 | 记录构建版本号，留意 90 天有效期，规划下次发版 | [ ] |

---

## 相关文件

- `codemagic.yaml`：云构建工作流配置（workflow id `lantransfer-testflight`）。
- `exportOptions.plist`：`xcodebuild -exportArchive` 的导出配置。
- `README.md`：工程结构、功能与协议兼容性说明。
