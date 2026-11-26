# 局域网快传 — iOS 端

基于 SwiftUI 与 Network.framework 的原生 iOS 局域网文件快传应用。与桌面端（Electron/Node）、Android 端（Kotlin）遵循同一套通信协议，可在同一局域网内互相发现、传输文件/图片/文件夹并聊天。

- 最低系统版本：**iOS 16+**
- Bundle ID：`com.lantransfer.ios`
- Xcode 工程：`LanTransfer.xcodeproj`
- Scheme / Target 名称：`LanTransfer`
- 分发方式：Codemagic 云构建 → 签名 .ipa → TestFlight（见 `TESTFLIGHT_GUIDE.md`）；另提供「云构建未签名 IPA + 全能签重签」路径，无需 Mac 与苹果付费开发者账号（见 `RESIGN_INSTALL_GUIDE.md`）

---

## 1. 功能列表

| 功能 | 说明 |
| --- | --- |
| 局域网设备发现 | 通过 Bonjour（mDNS）发现同一局域网内的桌面/Android/iOS 设备，服务类型 `_lantransfer._tcp`，并维护在线/离线状态。 |
| 文件传输 | 通过 TCP 45211 发送任意文件，支持断点续传、分块并发、CRC32 校验与 SHA-256 完整性校验。 |
| 图片传输 | 图片作为文件走同一套数据通道，支持在聊天会话中发送与接收。 |
| 文件夹传输 | 使用 `LFTB1` 整包格式，把整个文件夹作为一个传输任务发送，接收端一次性解包还原目录树。 |
| 局域网聊天 | 基于协议 v1 的聊天扩展（`CHAT_MESSAGE` / `CHAT_IMAGE` / `CHAT_ACK`），支持文本消息与图片消息。 |
| 传输记录 | 记录每次传输的文件名、对端、方向、结果与本地保存路径，便于回溯。 |
| 本地网络权限引导 | 首次启动请求 `NSLocalNetworkUsageDescription` 对应的本地网络权限，并在设置中提供跳转引导。 |
| 文件访问 | 接收的文件保存在 App 沙盒的 `Documents` 目录，可通过 iOS「文件」App 访问。 |

---

## 2. 工程结构

```
ios/
├── LanTransfer.xcodeproj/          # Xcode 工程文件（Target / Scheme: LanTransfer）
├── LanTransfer/                    # 主 Target 源码
│   ├── App/                        # 应用入口、@main、AppDelegate/Scene 生命周期、全局状态装配
│   ├── Core/                       # 与界面无关的核心层
│   │   ├── Network/                # Network.framework 封装：TCP 连接、Bonjour 浏览/发布、UDP 发现
│   │   ├── Protocol/               # 协议常量、控制帧/数据帧编解码、消息模型与信封
│   │   ├── Transfer/               # 传输状态机、分块调度、断点续传位图、校验与重传
│   │   ├── Chat/                   # 聊天消息编解码、会话管理、ACK 处理
│   │   └── Storage/                # Documents 目录文件管理、传输记录持久化、.part 临时文件
│   ├── Features/                   # SwiftUI 功能模块（View + ViewModel）
│   │   ├── Devices/                # 设备发现与设备列表界面
│   │   ├── Transfer/               # 发送/接收、进度与传输记录界面
│   │   ├── Chat/                   # 会话列表与聊天界面
│   │   └── Settings/               # 设置与权限引导界面
│   └── Resources/                  # Info.plist、资源文件、本地化文案等
├── LanTransferTests/               # 单元测试与协议一致性测试
├── Scripts/                        # 构建/校验辅助脚本
├── codemagic.yaml                  # Codemagic 云构建工作流（lantransfer-testflight）
├── exportOptions.plist             # xcodebuild -exportArchive 导出配置
├── TESTFLIGHT_GUIDE.md             # Apple Developer 账号 → Codemagic → TestFlight 全流程指南
├── RESIGN_INSTALL_GUIDE.md         # 云构建未签名 IPA → 全能签重签安装指南（无需开发者账号）
└── README.md                       # 本文件
```

> 说明：各目录下 Swift 源文件的具体命名由 iOS 工程实现维护；分层职责如上表所述。

典型的请求链路：

1. `Features/Devices` 通过 `Core/Network` 的 Bonjour 浏览发现对端并展示。
2. 用户在 `Features/Transfer` 选择文件，交给 `Core/Transfer` 的状态机。
3. `Core/Protocol` 把控制消息编码成 4 字节长度前缀的 JSON 帧，把文件数据编码成 20 字节头的数据帧。
4. `Core/Network` 通过 TCP 45211 收发，发送方主动连接接收方。
5. `Core/Storage` 把接收数据先写为 `.part` 临时文件与位图，校验通过后原子重命名为正式文件，存入 `Documents`。

---

## 3. 与桌面端 / Android 端的协议兼容性

本协议以 `shared/protocol/lan-transfer-protocol.md` 为唯一事实来源，配套 `constants.yaml` 与 `message-types.json`。iOS 端实现必须与桌面端（Node）、Android 端（Kotlin）逐字一致。

### 3.1 网络层

| 项 | 值 | 用途 |
| --- | --- | --- |
| 服务类型 | `_lantransfer._tcp` | Bonjour / mDNS 服务发现（端口 45211） |
| UDP 发现端口 | 45210 | 上线宣告、离线通知、设备查询（iOS 仅作兼容，发现以 Bonjour 为主） |
| TCP 端口 | 45211 | 控制连接与数据连接共用，靠首帧 HELLO 的 `channel` 字段区分 |
| 字节序 | big-endian（网络字节序） | 所有多字节整数统一 |
| 连接方向 | 发送方主动连接接收方 | 避免双端同时监听带来的 NAT/防火墙复杂度 |

### 3.2 帧格式

**控制帧**：4 字节长度前缀（uint32 BE，仅计 JSON 长度）+ UTF-8 JSON payload，单帧上限 1 MB。

```
┌────────────┬──────────────────────────┐
│ 4B length  │ N B UTF-8 JSON payload   │
│ (uint32 BE)│                          │
└────────────┴──────────────────────────┘
```

**数据帧**：20 字节定长头 + 裸数据，每块独占一条 TCP 数据连接。

```
┌────────┬─────────────┬──────────────┬─────────────┬──────────┬──────────┐
│ 4B cmd │ 4B transKey │ 4B chunkIdx  │ 4B chunkLen │ 4B crc32 │ N B 数据 │
│ 0x44415431 ("DAT1")  │             │             │          │          │
└────────┴─────────────┴──────────────┴─────────────┴──────────┴──────────┘
```

- `chunkLen` 后严格读取 `chunkLen` 字节（readFully），天然处理粘包/半包。
- `crc32` 为该块裸数据的 IEEE CRC32，可为 0 表示不校验（本实现默认计算）。
- `transferKey` 派生规则：`transferId`（UUID v4）去掉连字符后取前 8 个十六进制字符，按 big-endian 解析为 uint32。跨端必须一致。

**消息信封**：

```json
{ "v": 1, "type": "TRANSFER_REQUEST", "msgId": "uuid-v4", "ts": 1770000000000, "payload": {} }
```

控制消息类型摘要：HELLO、HELLO_ACK、TRANSFER_REQUEST、TRANSFER_ACCEPT、TRANSFER_REJECT、RESUME_QUERY、RESUME_RESPONSE、CHUNK_PLAN、PROGRESS、VERIFY_REQUEST、VERIFY_RESULT、RESEND_CHUNK、TRANSFER_COMPLETE、TRANSFER_FAILED、TRANSFER_CANCEL、PING、PONG。

### 3.3 文件夹传输（LFTB1 整包）

- 协议 v1 纯追加，文件夹作为**一个整体**传输，不是拆成多个独立任务。
- 发送端把文件夹打包成一个临时容器作为一个 `FileMeta` 走既有分块/校验状态机；接收端整包 SHA-256 通过后一次性解包为原目录树。
- 追加字段示例：

```json
{
  "name": "项目A.lftb",
  "mime": "application/x-lantransfer-folder",
  "bundle": { "format": "LFTB1", "rootName": "项目A", "fileCount": 12 }
}
```

- 容器布局（整数 big-endian，不压缩，支持流式 ≥2GB）：

```
[8B MAGIC="LFTB1\r\n\u0000"][文件裸字节按 manifest 顺序拼接]
[manifest JSON][4B manifestLength uint32][8B FOOTER="LFTBEND1"]
```

- `manifest` 含 `version`、`rootName`、`totalSize`、`files[{path,size,sha256}]`、`dirs`；路径统一 `/` 分隔并逐段清洗，拒绝 `..`、绝对路径与非法字符。
- 传输记录只写一条，`fileName` 为 `文件夹「rootName」`，`localPath` 指向解包后的目录。
- 兼容字段 `FileMeta.relativePath` 保留给不识别 `bundle` 的旧端，旧端会把整包当作普通 `.lftb` 文件保存。

### 3.4 聊天扩展（协议 v1 纯追加）

- HELLO 的 `purpose` 字段（`transfer` | `chat`，缺省 `transfer`）用于单一分流聊天连接与传输连接；聊天连接仍声明 `channel='control'`。
- 新增消息：`CHAT_MESSAGE`（kind=`TEXT`）、`CHAT_IMAGE`（kind=`IMAGE`，仅带元数据，图片字节走数据通道）、`CHAT_ACK`（state=`DELIVERED`/`READ`）。
- `conversationId = sorted([from,to]).join('|')`；文本 ≤2000 字符；`msgId` 与信封 `msgId` 同值。
- `TRANSFER_REQUEST` 追加可选 `category='NORMAL'|'CHAT_IMAGE'` 与 `chatMsgId`，聊天图片据此静默保存到 `<saveDir>/chat-images/<peerAlias>/`。
- 协议版本保持 1；收到未知消息类型必须忽略而不崩溃；任何图片字节的内联 base64 都是协议违规。

### 3.5 其它约定

- 断点续传位图：`4B magic("BIT1") + 4B chunkSize + 4B totalChunks + totalChunks 字节 0/1`；`.part` 与位图文件名均纳入 `fileId`，避免同名文件串档。
- 校验算法：SHA-256 为主、MD5 兼容；坏块重传闭环最多 `MAX_VERIFY_ROUNDS` 轮，判定 pending 前做 800ms 有界宽限轮询。
- 错误码：`USER_REJECTED`、`USER_TIMEOUT`、`HASH_MISMATCH`、`CONN_LOST`、`DISK_FULL`、`CANCELLED`、`CRC_MISMATCH`、`INVALID_FRAME`、`PEER_OFFLINE`。

---

## 4. 如何在 Xcode 中打开

1. 在 Mac 上从 App Store 安装 Xcode（需 iOS 16+ SDK，建议最新版）。
2. 双击 `LanTransfer.xcodeproj` 打开工程。
3. 顶部 Scheme 选择 `LanTransfer`，目标设备选「Any iOS Device (arm64)」或你的 iPhone。
4. 在 Target `LanTransfer` →「Signing & Capabilities」中选择你的 Team，Xcode 会自动管理签名；Bundle Identifier 为 `com.lantransfer.ios`。
5. 按 `Cmd + R` 运行到模拟器或真机；真机运行需要在 iPhone 的「设置 → 隐私与安全性 → 本地网络」中允许本 App 访问本地网络。
6. 归档：Product → Scheme → Edit Scheme → Archive 设为 Release；然后 Product → Archive，在 Organizer 中分发到 TestFlight。

---

## 5. 已知限制

| 限制 | 说明 |
| --- | --- |
| 前台传输 | iOS 后台执行时间受限，切到后台或锁屏后传输不可靠。请在传输期间保持 App 在前台并避免锁屏。 |
| 沙盒 Documents | 接收文件保存在 App 沙盒的 `Documents` 目录，只能通过 iOS「文件」App 或本 App 访问，不能写入任意系统目录。 |
| UDP 广播不可用 | iOS 不支持向 `255.255.255.255` 广播；设备发现主要依赖 Bonjour（mDNS）。请确保两端在同一局域网且路由器未开启 AP 隔离。 |
| 本地网络权限 | 首次启动必须允许「本地网络」权限；拒绝后需在系统设置中手动开启并重启 App。 |
| 安装来源限制 | iOS 应用只能通过 App Store 或 TestFlight 安装，不能直接分发 .ipa；TestFlight 需要付费 Apple Developer 账号。 |
| TestFlight 有效期 | 每个 TestFlight 构建版本自审核通过起 90 天有效，到期需发布新版本。 |

---

## 6. 相关文档

- `TESTFLIGHT_GUIDE.md`：从零申请开发者账号到上架 TestFlight 的完整步骤与排错。
- `RESIGN_INSTALL_GUIDE.md`：云构建未签名 IPA → 全能签重签安装的完整步骤与排错（无需 Mac 与苹果付费开发者账号）。
- `codemagic.yaml` / `exportOptions.plist`：云构建与导出配置（当前 `lantransfer-ipa` 工作流产出未签名 IPA）。
- 协议权威规范：`../shared/protocol/lan-transfer-protocol.md`（仓库根目录下的 `shared/protocol/`）。
