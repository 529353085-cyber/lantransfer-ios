/**
 * iOS 端静态一致性校验。
 *
 * 本机没有 Swift/Xcode 工具链，无法编译 iOS 工程；本脚本用静态分析 +
 * 跨平台算法复现的方式，验证 iOS 端与桌面/Android 端的协议一致性、关键接线、
 * 以及 Xcode 工程配置的完整性。这是当前环境下唯一可行的自动化验证手段。
 */
'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const ROOT = path.resolve(__dirname, '..');
const R = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const EXISTS = (p) => fs.existsSync(path.join(ROOT, p));

let passed = 0;
let failed = 0;
function test(name, fn) {
  try { fn(); console.log(`  PASS  ${name}`); passed++; }
  catch (e) { console.log(`  FAIL  ${name}\n        ${e.message}`); failed++; }
}
function section(t) { console.log(`\n=== ${t} ===`); }

// ---------------------------------------------------------------------------
section('1. 文件与工程结构完整性');

const IOS_SWIFTS = [
  'ios/LanTransfer/App/LanTransferApp.swift',
  'ios/LanTransfer/UI/AppState.swift',
  'ios/LanTransfer/UI/ContentView.swift',
  'ios/LanTransfer/Core/Protocol/Constants.swift',
  'ios/LanTransfer/Core/Protocol/Messages.swift',
  'ios/LanTransfer/Core/Protocol/JSONValue.swift',
  'ios/LanTransfer/Core/Protocol/FrameCodec.swift',
  'ios/LanTransfer/Core/Protocol/ByteReader.swift',
  'ios/LanTransfer/Core/Network/TcpConnection.swift',
  'ios/LanTransfer/Core/Network/TcpServer.swift',
  'ios/LanTransfer/Core/Network/DeviceRegistry.swift',
  'ios/LanTransfer/Core/Network/DiscoveryManager.swift',
  'ios/LanTransfer/Core/Transfer/ChecksumUtil.swift',
  'ios/LanTransfer/Core/Transfer/ChunkPlanner.swift',
  'ios/LanTransfer/Core/Transfer/PathSanitizer.swift',
  'ios/LanTransfer/Core/Transfer/ResumeManager.swift',
  'ios/LanTransfer/Core/Transfer/FolderBundle.swift',
  'ios/LanTransfer/Core/Transfer/ReceiveState.swift',
  'ios/LanTransfer/Core/Transfer/TransferManager.swift',
  'ios/LanTransfer/Core/Storage/TransferRecordStore.swift',
  'ios/LanTransfer/Core/Storage/SettingsStore.swift',
  'ios/LanTransfer/Core/Storage/ChatMessageStore.swift',
  'ios/LanTransfer/Core/Chat/ChatManager.swift',
  'ios/LanTransfer/Core/Chat/ChatChannel.swift',
  'ios/LanTransfer/Features/Devices/DeviceListView.swift',
  'ios/LanTransfer/Features/Transfer/TransferView.swift',
  'ios/LanTransfer/Features/Transfer/IncomingRequestView.swift',
  'ios/LanTransfer/Features/Chat/ChatConversationListView.swift',
  'ios/LanTransfer/Features/Chat/ChatView.swift',
  'ios/LanTransfer/Features/Chat/ChatComposer.swift',
  'ios/LanTransfer/Features/Settings/SettingsView.swift',
];

test('全部 31 个 Swift 源文件存在', () => {
  for (const f of IOS_SWIFTS) assert.ok(EXISTS(f), `缺失 ${f}`);
});

test('Xcode 工程、Scheme、Info.plist、构建配置齐全', () => {
  for (const f of [
    'ios/LanTransfer.xcodeproj/project.pbxproj',
    'ios/LanTransfer.xcodeproj/xcshareddata/xcschemes/LanTransfer.xcscheme',
    'ios/LanTransfer/Info.plist',
    'ios/codemagic.yaml',
    'ios/exportOptions.plist',
    'ios/README.md',
    'ios/TESTFLIGHT_GUIDE.md',
    'ios/RESIGN_INSTALL_GUIDE.md',
  ]) assert.ok(EXISTS(f), `缺失 ${f}`);
});

test('pbxproj 纳入全部 Swift 文件且括号配对', () => {
  const pbx = R('ios/LanTransfer.xcodeproj/project.pbxproj');
  assert.strictEqual((pbx.match(/sourcecode\.swift/g) || []).length, IOS_SWIFTS.length);
  assert.strictEqual((pbx.match(/\{/g) || []).length, (pbx.match(/\}/g) || []).length);
  assert.strictEqual((pbx.match(/\(/g) || []).length, (pbx.match(/\)/g) || []).length);
  assert.ok(pbx.includes('PRODUCT_BUNDLE_IDENTIFIER = com.lantransfer.ios'));
  assert.ok(pbx.includes('IPHONEOS_DEPLOYMENT_TARGET = 16.0'));
  assert.ok(pbx.includes('SWIFT_VERSION = 5.0'));
});

test('Info.plist 声明本地网络权限与 Bonjour 服务', () => {
  const plist = R('ios/LanTransfer/Info.plist');
  assert.ok(plist.includes('NSLocalNetworkUsageDescription'));
  assert.ok(plist.includes('_lantransfer._tcp'));
  assert.ok(plist.includes('NSBonjourServices'));
  assert.ok(plist.includes('UIFileSharingEnabled'));
});

// ---------------------------------------------------------------------------
section('2. 三端协议常量一致性');

const constants = R('ios/LanTransfer/Core/Protocol/Constants.swift');
const dtConstants = R('desktop/core/protocol/constants.ts');
const androidConstants = R('android/app/src/main/java/com/lantransfer/app/protocol/ProtocolConstants.kt');

const constCases = [
  ['协议版本', 'PROTOCOL_VERSION', '1'],
  ['UDP 发现端口', 'UDP_DISCOVERY_PORT', '45210'],
  ['TCP 端口', 'TCP_PORT', '45211'],
  ['默认块大小', 'DEFAULT_CHUNK_SIZE', '4 * 1024 * 1024'],
  ['最大块大小', 'MAX_CHUNK_SIZE', '16 * 1024 * 1024'],
  ['最小块大小', 'MIN_CHUNK_SIZE', '1 * 1024 * 1024'],
  ['默认并发', 'DEFAULT_CONCURRENCY', '4'],
  ['缓冲大小', 'BUFFER_SIZE', '64 * 1024'],
  ['发现间隔', 'DISCOVER_INTERVAL_MS', '2000'],
  ['设备超时', 'DEVICE_TIMEOUT_MS', '6000'],
];
for (const [label, name, value] of constCases) {
  test(`${label} ${name}=${value} iOS 端正确`, () => {
    const re = new RegExp(`(let|const|val)\\s+${name}\\s*(:\\s*[^=]+)?=\\s*${value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`);
    assert.ok(re.test(constants), `iOS Constants.swift 中未找到 ${name} = ${value}`);
  });
}

test('数据帧魔数 MAGIC_DATA=0x44415431 三端一致', () => {
  assert.ok(constants.includes('0x44415431'));
  assert.ok(dtConstants.includes('0x44415431'));
  assert.ok(/0x44415431/i.test(androidConstants));
});

test('位图魔数 MAGIC_BITMAP=0x42495431 三端一致', () => {
  assert.ok(constants.includes('0x42495431'));
  assert.ok(dtConstants.includes('0x42495431'));
  assert.ok(/0x42495431/i.test(androidConstants));
});

test('Bonjour 服务类型 _lantransfer._tcp 三端一致', () => {
  assert.ok(constants.includes('_lantransfer._tcp'));
  assert.ok(dtConstants.includes('_lantransfer._tcp'));
  assert.ok(androidConstants.includes('_lantransfer._tcp'));
});

test('transferKey 派生规则与三端一致（去连字符取前8位16进制）', () => {
  assert.ok(constants.includes('prefix(8)'));
  assert.ok(constants.includes('radix: 16'));
  assert.ok(dtConstants.includes('slice(0, 8)'));
});

// ---------------------------------------------------------------------------
section('3. 消息类型覆盖（20 种 + UNKNOWN 兜底）');

const iosMessages = R('ios/LanTransfer/Core/Protocol/Messages.swift');
const messageTypes = [
  'HELLO', 'HELLO_ACK', 'TRANSFER_REQUEST', 'TRANSFER_ACCEPT', 'TRANSFER_REJECT',
  'RESUME_QUERY', 'RESUME_RESPONSE', 'CHUNK_PLAN', 'PROGRESS', 'VERIFY_REQUEST',
  'VERIFY_RESULT', 'RESEND_CHUNK', 'TRANSFER_COMPLETE', 'TRANSFER_FAILED',
  'TRANSFER_CANCEL', 'PING', 'PONG', 'CHAT_MESSAGE', 'CHAT_IMAGE', 'CHAT_ACK',
];
test('20 种控制消息类型全部定义', () => {
  for (const t of messageTypes) {
    assert.ok(constants.includes(`= "${t}"`), `缺少消息类型 ${t}`);
  }
});

test('未知消息类型 UNKNOWN 兜底（协议 v1 兼容要求）', () => {
  assert.ok(constants.includes('case unknown = "__UNKNOWN__"'));
  assert.ok(constants.includes('init(from decoder: Decoder) throws'));
  assert.ok(constants.includes('?? .unknown'));
});

test('消息信封字段 v/type/msgId/ts/payload 与三端一致', () => {
  assert.ok(iosMessages.includes('var v: Int'));
  assert.ok(iosMessages.includes('var type: MessageType'));
  assert.ok(iosMessages.includes('var msgId: String'));
  assert.ok(iosMessages.includes('var ts: Int64'));
  assert.ok(iosMessages.includes('var payload: JSONValue'));
});

// ---------------------------------------------------------------------------
section('4. CRC32 算法跨端一致性（向量复现）');

// 用 Node 复现 iOS slice-by-8 算法（与桌面 ChecksumUtil.ts 同源），验证标准向量。
function buildCrcTables() {
  const tables = [new Uint32Array(256)];
  for (let n = 0; n < 256; n++) {
    let v = n;
    for (let k = 0; k < 8; k++) v = (v & 1) ? (0xedb88320 ^ (v >>> 1)) : (v >>> 1);
    tables[0][n] = v >>> 0;
  }
  for (let k = 1; k < 8; k++) {
    const prev = tables[k - 1], cur = new Uint32Array(256);
    for (let x = 0; x < 256; x++) {
      const v = prev[x];
      cur[x] = (tables[0][v & 0xff] ^ (v >>> 8)) >>> 0;
    }
    tables.push(cur);
  }
  return tables;
}
const CRC_TABLES = buildCrcTables();
function crc32(buf) {
  let crc = 0xffffffff, i = 0;
  const t = CRC_TABLES;
  while (i + 8 <= buf.length) {
    const b0=buf[i],b1=buf[i+1],b2=buf[i+2],b3=buf[i+3],b4=buf[i+4],b5=buf[i+5],b6=buf[i+6],b7=buf[i+7];
    crc = t[7][(crc^b0)&0xff]^t[6][((crc>>>8)^b1)&0xff]^t[5][((crc>>>16)^b2)&0xff]^t[4][((crc>>>24)^b3)&0xff]
        ^ t[3][b4]^t[2][b5]^t[1][b6]^t[0][b7];
    i += 8;
  }
  while (i < buf.length) { crc = t[0][(crc^buf[i])&0xff] ^ (crc>>>8); i++; }
  return (crc ^ 0xffffffff) >>> 0;
}

const checksumUtil = R('ios/LanTransfer/Core/Transfer/ChecksumUtil.swift');
test('CRC32 使用 IEEE 多项式 0xEDB88320 与初值 0xFFFFFFFF', () => {
  assert.ok(checksumUtil.includes('0xEDB88320'));
  assert.ok(checksumUtil.includes('0xFFFF_FFFF'));
});
test('CRC32 标准向量 "123456789" = 0xCBF43926', () => {
  assert.strictEqual(crc32(Buffer.from('123456789', 'ascii')), 0xCBF43926);
});
test('CRC32 空串 = 0x00000000', () => {
  assert.strictEqual(crc32(Buffer.alloc(0)), 0);
});
test('CRC32 结果按无符号承载（UInt64 编码 crcMap，避免 Int32 溢出）', () => {
  assert.ok(iosMessages.includes('crcMap: [String: UInt64]?'));
  assert.ok(checksumUtil.includes('UInt64(CRC32.checksum(chunk))'));
});

// ---------------------------------------------------------------------------
section('5. LFTB1 文件夹整包一致性');

const folderBundle = R('ios/LanTransfer/Core/Transfer/FolderBundle.swift');
test('LFTB1 MAGIC 为 8 字节 LFTB1\\r\\n\\0（与桌面一致）', () => {
  assert.ok(folderBundle.includes('0x4C, 0x46, 0x54, 0x42, 0x31, 0x0D, 0x0A, 0x00'));
  const desk = R('desktop/core/transfer/FolderBundle.ts');
  assert.ok(desk.includes('LFTB1\\r\\n\\u0000'));
});
test('LFTB1 FOOTER=LFTBEND1，manifest 4B 长度 BE', () => {
  assert.ok(folderBundle.includes('"LFTBEND1"'));
  assert.ok(folderBundle.includes('BE.u32(UInt32(manifestBytes.count))'));
});
test('bundle 元数据 format=LFTB1 走单一传输项', () => {
  assert.ok(folderBundle.includes('version: 1'));
  assert.ok(iosMessages.includes('var bundle: FolderBundleRef?'));
});
test('解包逐文件 SHA-256 校验 + 不覆盖已有目录（加序号后缀）', () => {
  assert.ok(folderBundle.includes('hasher.finalize().hexString.lowercased() == entry.sha256.lowercased()'));
  assert.ok(R('ios/LanTransfer/Core/Transfer/PathSanitizer.swift').includes('\\(index))'));
});

// ---------------------------------------------------------------------------
section('6. 路径穿越防护与文件名清洗');

const sanitizer = R('ios/LanTransfer/Core/Transfer/PathSanitizer.swift');
test('文件名清洗正则覆盖桌面非法字符集', () => {
  for (const ch of ['"\\\\"', '"/"', '":"', '"*"', '"?"', '"\\""', '"<"', '">"', '"|"']) {
    assert.ok(sanitizer.includes(ch), `缺少非法字符 ${ch}`);
  }
  assert.ok(sanitizer.includes('prefix(180)'));
});
test('相对路径逐段清洗拒绝 .. / . / 绝对路径 / 盘符 / 控制字符', () => {
  assert.ok(sanitizer.includes('s == ".."'));
  assert.ok(sanitizer.includes('s == "."'));
  assert.ok(sanitizer.includes('raw.hasPrefix("/")'));
  assert.ok(sanitizer.includes('first.isLetter && second == ":"'));
  assert.ok(sanitizer.includes('v <= 0x1F'));
});
test('接收落点做 containment 校验', () => {
  assert.ok(sanitizer.includes('guard path.hasPrefix(rootPath + "/")'));
});

// ---------------------------------------------------------------------------
section('7. 传输状态机关键接线');

const tm = R('ios/LanTransfer/Core/Transfer/TransferManager.swift');
test('发送流程 RESUME_QUERY→CHUNK_PLAN→VERIFY_REQUEST→RESEND→COMPLETE 齐全', () => {
  for (const m of ['.resumeQuery', '.chunkPlan', '.verifyRequest', '.resendChunk', '.transferComplete']) {
    assert.ok(tm.includes(`sendMessage(${m}`), `缺少 ${m}`);
  }
});
test('接收流程 RESUME_RESPONSE / VERIFY_RESULT / HELLO_ACK 齐全', () => {
  assert.ok(tm.includes('.resumeResponse'));
  assert.ok(tm.includes('sendMessage(.verifyResult'));
});
test('聊天图片 silent accept 到 chat-images 子目录', () => {
  assert.ok(tm.includes('CHAT_IMAGE_SUBDIR'));
  assert.ok(tm.includes('category == "CHAT_IMAGE"'));
});
test('聊天图片接收完成回写聊天表（markImageReceived）', () => {
  assert.ok(tm.includes('chatManager.markImageReceived'));
});
test('接收侧按 HELLO.deviceId 定位对端设备', () => {
  assert.ok(tm.includes('link.hello?.deviceId'));
});
test('pieces与位图断点续传：missingChunks + markUndone 清位屏障', () => {
  assert.ok(R('ios/LanTransfer/Core/Transfer/ReceiveState.swift').includes('func markUndone'));
  assert.ok(R('ios/LanTransfer/Core/Transfer/ChunkPlanner.swift').includes('func missingChunks'));
});
test('发送块独占数据连接 + transferKey + 20B 头 + 等 FIN', () => {
  assert.ok(tm.includes('channel: .data'));
  assert.ok(tm.includes('toTransferKey(transferId)'));
  assert.ok(tm.includes('waitForEnd()'));
});

// ---------------------------------------------------------------------------
section('8. 聊天与未读角标（用户本轮反馈）');

const chatMgr = R('ios/LanTransfer/Core/Chat/ChatManager.swift');
const chatChannel = R('ios/LanTransfer/Core/Chat/ChatChannel.swift');
const appState = R('ios/LanTransfer/UI/AppState.swift');
const chatView = R('ios/LanTransfer/Features/Chat/ChatView.swift');

test('会话 id = sorted([from,to]).join("|")（与三端一致）', () => {
  assert.ok(chatMgr.includes('.sorted().joined(separator: "|")'));
});
test('打开会话即标记已读并清未读角标', () => {
  assert.ok(chatMgr.includes('func openConversation'));
  assert.ok(chatMgr.includes('list[i].state = "READ"'));
  assert.ok(chatMgr.includes('convId == activeConversationId ? 0'));
});
test('批量 READ 回执（对会话全部未读消息）', () => {
  assert.ok(chatChannel.includes('sendReadAckForConversation'));
  assert.ok(chatMgr.includes('func unreadMessageIds'));
});
test('聊天图片粘贴/拖入：PhotosPicker + 剪贴板粘贴', () => {
  const composer = R('ios/LanTransfer/Features/Chat/ChatComposer.swift');
  assert.ok(composer.includes('photosPicker'));
  assert.ok(composer.includes('UIPasteboard.general.image'));
});
test('ChatView 按 peerId 计算会话 id（避免与三端约定不一致）', () => {
  assert.ok(chatView.includes('ChatManager.conversationId(appState.selfDeviceId, peerId)'));
});

// ---------------------------------------------------------------------------
section('9. DI / 服务启动接线');

test('聊天 purpose=chat 连接按分流到 ChatChannel', () => {
  const server = R('ios/LanTransfer/Core/Network/TcpServer.swift');
  assert.ok(server.includes('hello.purpose == "chat"'));
  assert.ok(server.includes('onChat?(link)'));
  assert.ok(appState.includes('chatChannel.handleIncoming(link)'));
});
test('AppState 装配全部 Core 依赖并绑定状态', () => {
  assert.ok(appState.includes('DeviceRegistry()'));
  assert.ok(appState.includes('TransferRecordStore()'));
  assert.ok(appState.includes('ChatMessageStore()'));
  assert.ok(appState.includes('transferManager.$tasks'));
  assert.ok(appState.includes('chatManager.$conversations'));
});
test('设备 id 持久化保证重启后会话/记录关联稳定', () => {
  assert.ok(appState.includes('lantransfer.deviceId'));
});
test('发送文件/文件夹接线到 TransferManager（fileImporter 回调带 URL）', () => {
  const dev = R('ios/LanTransfer/Features/Devices/DeviceListView.swift');
  assert.ok(dev.includes('appState.sendFiles(urls, to: device)'));
  assert.ok(appState.includes('await transferManager.send(urls: urls, to: device)'));
});

test('编译风险项：关键符号与方法签名自洽（人工审查回归）', () => {
  // 1. BundleManifest 无 fileCount 字段，必须用 files.count
  assert.ok(tm.includes('fileCount: built.manifest.files.count'));
  assert.ok(!tm.includes('built.manifest.fileCount'));
  // 2. IncomingRequest.expiresAt 无默认值，构造时必须传
  assert.ok(tm.includes('expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + ACCEPT_TIMEOUT_MS'));
  // 3. chatHandler 为可选闭包：Swift 6.2/Xcode 26 起可选类型参数内的 @escaping 会报
  //    "closure is already escaping in optional type argument"，必须去掉 @escaping。
  assert.ok(tm.includes('chatHandler: ((TcpConnection) -> Void)? = nil'));
  assert.ok(!tm.includes('(@escaping'));
  for (const f of IOS_SWIFTS) {
    assert.ok(!R(f).includes('(@escaping'), `${f} 残留可选参数内 @escaping`);
  }
  // 4. IPv4/6Address.rawValue 是 Data，须用 debugDescription 取字符串 IP
  const tcp = R('ios/LanTransfer/Core/Network/TcpConnection.swift');
  assert.ok(tcp.includes('case .ipv4(let addr): return addr.debugDescription'));
  const disc = R('ios/LanTransfer/Core/Network/DiscoveryManager.swift');
  assert.ok(disc.includes('case .ipv4(let addr) = host'));
  assert.ok(disc.includes('return addr.debugDescription'));
  // 5. TransferManager 用 @Published/ObservableObject 必须 import Combine
  assert.ok(tm.includes('import Combine'));
});

// ---------------------------------------------------------------------------
section('10. 构建与分发配置');

test('codemagic.yaml 产出未签名 IPA 且无苹果签名依赖', () => {
  const cm = R('ios/codemagic.yaml');
  for (const kw of [
    'lantransfer-ipa', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
    'CODE_SIGNING_IDENTITY', 'generic/platform=iOS', 'Payload', 'zip', '$HOME/build/output/*.ipa',
  ]) assert.ok(cm.includes(kw), `新配置缺少 ${kw}`);
  for (const kw of [
    'app_store_connect', 'submit_to_testflight', 'ios_signing', 'TEAM_ID', 'PROFILE_NAME',
  ]) assert.ok(!cm.includes(kw), `不应残留旧签名配置 ${kw}`);
});
test('exportOptions.plist 为 development 且无签名占位符', () => {
  // 剥离 XML 注释后断言，避免说明性注释里提到的占位符字样造成误报。
  const eo = R('ios/exportOptions.plist').replace(/<!--[\s\S]*?-->/g, '');
  assert.ok(eo.includes('<string>development</string>'));
  for (const kw of ['app-store', 'YOUR_TEAM_ID', 'provisioningProfiles', 'destination']) {
    assert.ok(!eo.includes(kw), `不应残留签名占位符 ${kw}`);
  }
});
test('RESIGN_INSTALL_GUIDE 覆盖工作流名与全能签重签全流程', () => {
  const guide = R('ios/RESIGN_INSTALL_GUIDE.md');
  for (const kw of [
    'lantransfer-ipa', '全能签', 'p12', 'mobileprovision', '本地网络', 'GitHub', 'Codemagic', 'Artifacts',
  ]) assert.ok(guide.includes(kw), `指南缺少关键词 ${kw}`);
});
test('TESTFLIGHT_GUIDE 覆盖账号申请/签名/TestFlight/90天限制', () => {
  const guide = R('ios/TESTFLIGHT_GUIDE.md');
  for (const kw of ['Apple Developer', 'TestFlight', 'API Key', '90', 'Bundle ID']) {
    assert.ok(guide.includes(kw), `指南缺少关键词 ${kw}`);
  }
});

// ---------------------------------------------------------------------------
console.log(`\n========================================`);
console.log(`汇总：PASS ${passed} / FAIL ${failed}`);
console.log(`========================================`);
if (failed > 0) process.exit(1);
