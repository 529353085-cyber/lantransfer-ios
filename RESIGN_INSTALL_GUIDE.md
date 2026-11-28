# 章鱼快传 iOS 版 — 未签名 IPA 云构建与全能签重签安装指南

一句话原理：用 Codemagic 在云端免费把本工程编译成一个未签名的 IPA，再用 iPhone 上的「全能签」导入你自己的证书和描述文件重新签名并安装到手机；全程不需要 Mac，也不需要苹果付费开发者账号。

本指南面向完全没有 iOS 发布经验的用户，按第 1 步到第 6 步顺序操作即可。所有命令行操作在 Windows 上完成，不需要苹果电脑。

---

## 第 1 步：准备 GitHub 账号并推送 ios 工程

Codemagic 需要从代码仓库读取工程，所以先把 `ios` 目录上传到 GitHub。

1. 注册并登录 GitHub（https://github.com）。
2. 创建一个新仓库（New repository），仓库名随意，例如 `lantransfer-ios`。可见性选 Private（私有）或 Public（公开）均可，Codemagic 两种都能读取；建议选 Private。
3. 在本机打开「命令提示符」或 PowerShell，进入 `ios` 目录后依次执行下面的命令。把其中的 `你的用户名` 和 `你的仓库名` 换成你自己的实际值：

   ```bash
   cd /d E:\WorkBuddy\2026-11-19-19-23-51\ios
   git init
   git add .
   git commit -m "init lantransfer ios project"
   git branch -M main
   git remote add origin https://github.com/你的用户名/你的仓库名.git
   git push -u origin main
   ```

4. 推送时 GitHub 会要求登录，按提示在浏览器里完成授权即可。

关于仓库根的重要说明：

- 上面示例是「只把 `ios` 目录的内容作为仓库根」推送，此时 `codemagic.yaml` 就在仓库根，第 2 步的配置路径填 `codemagic.yaml`，最简单。
- 如果你想把整个项目（含 `android/`、`desktop/`、`ios/` 等）都放进同一个仓库，那么 `codemagic.yaml` 位于 `ios/` 子目录，第 2 步的配置路径必须填 `ios/codemagic.yaml`，并且 `codemagic.yaml` 里的 `XCODE_PROJECT` 要改成 `ios/LanTransfer.xcodeproj`。
- 两种方式都能构建成功，推荐第一种（只推 `ios` 目录），配置更少、更不易出错。

---

## 第 2 步：注册 Codemagic 并启动构建

1. 打开 Codemagic 官网（https://codemagic.io），点「Sign up」，选择用 GitHub 账号登录并授权。
2. 进入控制台后点「Add application」，在列表中选择第 1 步创建的仓库。
3. 选择构建配置来源时，选「Use a codemagic.yaml file from the repository」，并把 Configuration file 路径填成：
   - 只推 `ios` 目录：`codemagic.yaml`
   - 推整个项目：`ios/codemagic.yaml`
4. Codemagic 会读取仓库里的 `codemagic.yaml`，里面定义了名为 `lantransfer-ipa` 的工作流。选择该工作流。
5. 点「Start new build」，选择分支 `main`，启动构建。
6. 构建过程通常几分钟。免费账号每月有一定时长的免费云构建额度，个人小工程构建一次只消耗几分钟，一般够用；具体额度以 Codemagic 官网和后台显示为准，用完需等下个计费周期或升级套餐。
7. 本方案不需要配置任何证书、描述文件、Team ID 或 API Key，如果 Codemagic 界面要求填写这些，说明选错了工作流或配置路径，请回到第 3、4 点检查。

---

## 第 3 步：下载构建好的 IPA

1. 构建状态变为成功（Successful）后，进入该次构建的详情页。
2. 切换到「Artifacts」（产物）标签页。
3. 找到 `LanTransfer.ipa`，点击下载到本机。
4. 这个文件就是未签名的 IPA，接下来交给全能签重签。

如果构建失败，请点击构建日志逐条查看报错，常见原因见文末「常见问题排查」表。

---

## 第 4 步：把 IPA 传到 iPhone

IPA 文件在电脑上，需要先传到手机。任选一种你方便的方式：

- 隔空投送（AirDrop）：从 Mac 投送；Windows 上可用支持 AirDrop 的工具或先把 IPA 存到手机网盘。
- 网盘：把 IPA 上传到百度网盘、阿里云盘等，在 iPhone 上用对应 App 下载。
- 微信文件传输助手：在电脑微信里把 IPA 发给「文件传输助手」，在 iPhone 微信里点开并用「用其他应用打开」保存到「文件」App。
- 数据线：用iTunes/Finder 文件共享或第三方助手把 IPA 放进手机。

只要能让全能签在 iPhone 上读取到这个 IPA 文件即可。

---

## 第 5 步：用全能签签名并安装

前提：iPhone 上已安装「全能签」，并且已备好 p12 证书与 mobileprovision 描述文件。

证书从哪来：

- 全能签 App 内通常提供证书购买或兑换码兑换入口，按 App 内说明获取。
- p12 证书一般会带一个密码，密码以你购买/兑换时商家给出的说明为准，不要自己猜。
- mobileprovision 描述文件与证书配套使用，按全能签内说明导入。
- 证书有有效期（常见为一年或更短，以商家说明为准），到期需要更换新证书重新签名。

签名安装步骤：

1. 打开全能签，进入证书管理，导入 p12 证书，按提示输入证书密码。
2. 导入配套的 mobileprovision 描述文件。
3. 回到全能签主界面，导入第 4 步传到手机的 `LanTransfer.ipa`。
4. 选中刚导入的 IPA，选择刚才的证书和描述文件，点击「签名」或「重签」。
5. 签名完成后，按全能签提示点击「安装」，把 App 装到 iPhone。
6. 如果系统弹出信任企业/开发者证书提示，进入「设置 → 通用 → VPN与设备管理」（部分系统叫「描述文件与设备管理」），点开对应证书并选择信任。
7. 首次打开 App 前，iOS 16 及以上还需开启开发者模式：「设置 → 隐私与安全性 → 开发者模式」，打开后按提示重启手机。重启后再打开 App。

---

## 第 6 步：首次使用设置与传输注意事项

1. 首次打开 App 时，系统会弹出「本地网络」权限请求，务必点「允许」。否则 App 发现不了同一局域网内的电脑和其他设备。
2. 如果不小心点了「拒绝」，到「设置 → 隐私与安全性 → 本地网络」里打开本 App 的开关，然后重新打开 App。
3. 接收的文件保存在 App 沙盒的 `Documents` 目录，可通过 iOS 自带的「文件」App 找到；本 App 内也能查看传输记录。
4. iOS 对后台执行时间有限制，传输期间请保持 App 在前台并避免锁屏，否则传输可能中断。
5. 确保手机和电脑在同一局域网，路由器不要开启 AP 隔离，否则互相发现不了。

---

## 常见问题排查

| 现象 | 可能原因 | 处理办法 |
| --- | --- | --- |
| Codemagic 构建失败 | 配置路径填错，或工作流选错 | 确认 Configuration file 路径为 `codemagic.yaml` 或 `ios/codemagic.yaml`，工作流选 `lantransfer-ipa`；逐条看构建日志的第一个报错 |
| Codemagic 提示找不到工程 | `XCODE_PROJECT` 路径不对 | 仓库根是 ios 时保持 `LanTransfer.xcodeproj`；仓库根是项目根时改为 `ios/LanTransfer.xcodeproj` |
| 下载不到 IPA | 构建未成功，或产物路径变化 | 确认构建状态为 Successful；到 Artifacts 页刷新；检查日志末尾是否打印了 IPA 校验通过 |
| 未签名 IPA 全能签不认 | IPA 结构不对或文件损坏 | 确认包内是 `Payload/LanTransfer.app` 结构；重新下载或重新构建；不要用已经签名过的 IPA 再喂给全能签 |
| 全能签签名时提示证书无效 | 证书过期、密码错误、描述文件不匹配 | 核对证书密码；确认证书在有效期内；重新导入配套的描述文件 |
| 证书掉签 / 打开几天后闪退 | 证书到期，或苹果吊销了证书 | 更换新证书重新签名安装；第三方签名受证书有效期和苹果策略影响，属于正常现象 |
| 安装后打不开 App | 未信任证书，或未开开发者模式 | 到「设置 → 通用 → VPN与设备管理」信任证书；到「设置 → 隐私与安全性 → 开发者模式」开启并重启 |
| 发现不了电脑 | 本地网络权限被拒，或不在同一局域网 | 在「设置 → 隐私与安全性 → 本地网络」允许本 App；确认两端同网段且路由器未开 AP 隔离 |
| 传输中途断开 | App 切到后台或锁屏 | 传输期间保持 App 在前台、不要锁屏 |
| 担心 TestFlight 90 天过期 | 误以为本方案走 TestFlight | 本方案不涉及 TestFlight，没有 90 天构建过期问题；但证书本身有有效期，到期需换证书重签 |

---

## 你需要做的事（清单）

| 序号 | 事项 | 完成标志 |
| --- | --- | --- |
| 1 | 注册 GitHub 并把 ios 目录推送到仓库 | 仓库里能看到 `codemagic.yaml` 和 `LanTransfer.xcodeproj` |
| 2 | 注册 Codemagic 并用 GitHub 登录，连接仓库 | 控制台能看到该仓库的 App |
| 3 | 配置 Configuration file 路径，选择 `lantransfer-ipa` 工作流 | Codemagic 能读取到工作流 |
| 4 | 启动构建并等待成功 | 构建状态为 Successful |
| 5 | 在 Artifacts 页下载 `LanTransfer.ipa` | 本机有 IPA 文件 |
| 6 | 把 IPA 传到 iPhone | 全能签里能导入该 IPA |
| 7 | 在全能签导入证书和描述文件并对 IPA 重签安装 | iPhone 上出现「章鱼快传」图标 |
| 8 | 信任证书、开启开发者模式、允许本地网络权限 | App 能正常打开并发现设备 |

---

## 重要声明

全能签等第三方签名属于非 App Store 分发，稳定性受证书有效期和苹果策略影响，可能出现掉签、证书失效等情况，需要自行重新签名安装。这是个人自用的可行方案，不是官方上架，也不依赖苹果付费开发者账号或 TestFlight。请仅用于个人合法自用的场景，并遵守相关软件许可与当地法律法规。
