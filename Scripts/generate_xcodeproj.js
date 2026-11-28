#!/usr/bin/env node
/**
 * 生成 LanTransfer.xcodeproj/project.pbxproj 与共享 Scheme。
 * 用脚本生成是为了保证 24 位对象 ID 唯一、文件列表与实际源码同步。
 * 用法：node ios/Scripts/generate_xcodeproj.js
 * 新增/删除 Swift 文件后重新运行本脚本即可。
 */
const fs = require('fs');
const path = require('path');

const IOS_DIR = path.resolve(__dirname, '..');
const SRC_DIR = path.join(IOS_DIR, 'LanTransfer');
const PROJ_DIR = path.join(IOS_DIR, 'LanTransfer.xcodeproj');
const SCHEME_DIR = path.join(PROJ_DIR, 'xcshareddata', 'xcschemes');

let counter = 0;
const id = () => 'A' + (++counter).toString(16).padStart(23, '0');

// 递归列出所有 .swift 文件（相对 SRC_DIR，用 '/' 分隔）。
function listSwift(dir, base) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    const rel = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...listSwift(full, rel));
    else if (entry.name.endsWith('.swift')) out.push(rel);
  }
  return out.sort();
}

const swiftFiles = listSwift(SRC_DIR, '');

// 对象 ID 分配
const IDs = {
  project: id(),
  mainGroup: id(),
  srcGroup: id(),
  productsGroup: id(),
  appProduct: id(),
  target: id(),
  sourcesPhase: id(),
  frameworksPhase: id(),
  resourcesPhase: id(),
  projectConfigList: id(),
  targetConfigList: id(),
  projectDebug: id(),
  projectRelease: id(),
  targetDebug: id(),
  targetRelease: id(),
  assetCatalog: id(),
  assetCatalogBuild: id(),
};

const fileRefs = {};      // rel -> fileRef id
const buildFiles = {};    // rel -> buildFile id
for (const rel of swiftFiles) {
  fileRefs[rel] = id();
  buildFiles[rel] = id();
}

// 构建目录树（PBXGroup）。返回 group id。
const groupNodes = {}; // 目录路径 -> group id
function ensureGroup(dirPath) {
  if (dirPath === '') return IDs.srcGroup;
  if (groupNodes[dirPath]) return groupNodes[dirPath];
  const gid = id();
  groupNodes[dirPath] = gid;
  return gid;
}

// 先建所有目录 group
const dirs = new Set();
for (const rel of swiftFiles) {
  const parts = rel.split('/');
  for (let i = 1; i < parts.length; i++) {
    dirs.add(parts.slice(0, i).join('/'));
  }
}
for (const d of [...dirs].sort()) ensureGroup(d);

// group -> children 行
const groupChildren = {};
for (const rel of swiftFiles) {
  const parts = rel.split('/');
  const parentDir = parts.slice(0, -1).join('/');
  const parent = ensureGroup(parentDir);
  (groupChildren[parent] ||= []).push(`\t\t\t\t${fileRefs[rel]} /* ${path.basename(rel)} in Sources */,`);
}
// 子 group 挂到父 group
for (const d of [...dirs].sort()) {
  const gid = groupNodes[d];
  const parts = d.split('/');
  const parentDir = parts.slice(0, -1).join('/');
  const parent = ensureGroup(parentDir);
  (groupChildren[parent] ||= []).push(`\t\t\t\t${gid} /* ${parts[parts.length - 1]} */,`);
}

let pb = '';
pb += '// !$*UTF8*$!\n{\n';
pb += '\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n\n';

// PBXBuildFile
pb += '/* Begin PBXBuildFile section */\n';
for (const rel of swiftFiles) {
  pb += `\t\t${buildFiles[rel]} /* ${path.basename(rel)} in Sources */ = {isa = PBXBuildFile; fileRef = ${fileRefs[rel]} /* ${path.basename(rel)} */; };\n`;
}
pb += `\t\t${IDs.assetCatalogBuild} /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = ${IDs.assetCatalog} /* Assets.xcassets */; };\n`;
pb += '/* End PBXBuildFile section */\n\n';

// PBXFileReference
pb += '/* Begin PBXFileReference section */\n';
for (const rel of swiftFiles) {
  pb += `\t\t${fileRefs[rel]} /* ${path.basename(rel)} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "${path.basename(rel)}"; sourceTree = "<group>"; };\n`;
}
pb += `\t\t${IDs.assetCatalog} /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };\n`;
pb += `\t\t${IDs.appProduct} /* LanTransfer.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = LanTransfer.app; sourceTree = BUILT_PRODUCTS_DIR;};\n`;
pb += '/* End PBXFileReference section */\n\n';

// PBXFrameworksBuildPhase
pb += '/* Begin PBXFrameworksBuildPhase section */\n';
pb += `\t\t${IDs.frameworksPhase} = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n`;
pb += '/* End PBXFrameworksBuildPhase section */\n\n';

// PBXGroup
pb += '/* Begin PBXGroup section */\n';
pb += `\t\t${IDs.mainGroup} = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t${IDs.srcGroup} /* LanTransfer */,\n\t\t\t\t${IDs.productsGroup} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t};\n`;
pb += `\t\t${IDs.srcGroup} = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n${(groupChildren[IDs.srcGroup] || []).join('\n')}\n\t\t\t\t${IDs.assetCatalog} /* Assets.xcassets */,\n\t\t\t);\n\t\t\tpath = LanTransfer;\n\t\t\tsourceTree = "<group>";\n\t\t};\n`;
for (const d of [...dirs].sort()) {
  const gid = groupNodes[d];
  const name = d.split('/').pop();
  pb += `\t\t${gid} = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n${(groupChildren[gid] || []).join('\n')}\n\t\t\t);\n\t\t\tpath = "${name}";\n\t\t\tsourceTree = "<group>";\n\t\t};\n`;
}
pb += `\t\t${IDs.productsGroup} = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t${IDs.appProduct} /* LanTransfer.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t};\n`;
pb += '/* End PBXGroup section */\n\n';

// PBXNativeTarget
pb += '/* Begin PBXNativeTarget section */\n';
pb += `\t\t${IDs.target} /* LanTransfer */ = {\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = ${IDs.targetConfigList} /* Build configuration list for PBXNativeTarget "LanTransfer" */;\n\t\t\tbuildPhases = (\n\t\t\t\t${IDs.sourcesPhase} /* Sources */,\n\t\t\t\t${IDs.frameworksPhase} /* Frameworks */,\n\t\t\t\t${IDs.resourcesPhase} /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = LanTransfer;\n\t\t\tproductName = LanTransfer;\n\t\t\tproductReference = ${IDs.appProduct} /* LanTransfer.app */;\n\t\t\tproductType = "com.apple.product-type.application";\n\t\t};\n`;
pb += '/* End PBXNativeTarget section */\n\n';

// PBXProject
pb += '/* Begin PBXProject section */\n';
pb += `\t\t${IDs.project} /* Project object */ = {\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1500;\n\t\t\t\tLastUpgradeCheck = 1500;\n\t\t\t\tTargetAttributes = {\n\t\t\t\t\t${IDs.target} = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\t};\n\t\t\t\t};\n\t\t\t};\n\t\t\tbuildConfigurationList = ${IDs.projectConfigList} /* Build configuration list for PBXProject "LanTransfer" */;\n\t\t\tcompatibilityVersion = "Xcode 14.0";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\t"zh-Hans",\n\t\t\t);\n\t\t\tmainGroup = ${IDs.mainGroup};\n\t\t\tproductRefGroup = ${IDs.productsGroup} /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n\t\t\ttargets = (\n\t\t\t\t${IDs.target} /* LanTransfer */,\n\t\t\t);\n\t\t};\n`;
pb += '/* End PBXProject section */\n\n';

// PBXResourcesBuildPhase
pb += '/* Begin PBXResourcesBuildPhase section */\n';
pb += `\t\t${IDs.resourcesPhase} = {\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t${IDs.assetCatalogBuild} /* Assets.xcassets in Resources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n`;
pb += '/* End PBXResourcesBuildPhase section */\n\n';

// PBXSourcesBuildPhase
pb += '/* Begin PBXSourcesBuildPhase section */\n';
pb += `\t\t${IDs.sourcesPhase} = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n`;
for (const rel of swiftFiles) {
  pb += `\t\t\t\t${buildFiles[rel]} /* ${path.basename(rel)} in Sources */,\n`;
}
pb += `\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n`;
pb += '/* End PBXSourcesBuildPhase section */\n\n';

// XCBuildConfiguration - project
const projectSettings = [
  'ALWAYS_SEARCH_USER_PATHS = NO;',
  'CLANG_ANALYZER_NONNULL = YES;',
  'CLANG_ENABLE_MODULES = YES;',
  'CLANG_ENABLE_OBJC_ARC = YES;',
  'COPY_PHASE_STRIP = NO;',
  'ENABLE_BITCODE = NO;',
  'IPHONEOS_DEPLOYMENT_TARGET = 16.0;',
  'SDKROOT = iphoneos;',
  'SWIFT_VERSION = 5.0;',
  'TARGETED_DEVICE_FAMILY = "1,2";',
  'CODE_SIGN_STYLE = Automatic;',
];
pb += '/* Begin XCBuildConfiguration section */\n';
pb += `\t\t${IDs.projectDebug} /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n${projectSettings.map(s => '\t\t\t\t' + s).join('\n')}\n\t\t\t};\n\t\t\tname = Debug;\n\t\t};\n`;
pb += `\t\t${IDs.projectRelease} /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n${projectSettings.map(s => '\t\t\t\t' + s).join('\n')}\n\t\t\t};\n\t\t\tname = Release;\n\t\t};\n`;

// XCBuildConfiguration - target
const targetCommon = [
  'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;',
  'CODE_SIGN_STYLE = Automatic;',
  'CURRENT_PROJECT_VERSION = 4;',
  'GENERATE_INFOPLIST_FILE = NO;',
  'INFOPLIST_FILE = LanTransfer/Info.plist;',
  'MARKETING_VERSION = 1.0.3;',
  'PRODUCT_BUNDLE_IDENTIFIER = com.lantransfer.ios;',
  'PRODUCT_NAME = "$(TARGET_NAME)";',
  'SWIFT_EMIT_LOC_STRINGS = YES;',
  'SWIFT_VERSION = 5.0;',
  'TARGETED_DEVICE_FAMILY = "1,2";',
  'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";',
];
pb += `\t\t${IDs.targetDebug} /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n${targetCommon.map(s => '\t\t\t\t' + s).join('\n')}\n\t\t\t};\n\t\t\tname = Debug;\n\t\t};\n`;
pb += `\t\t${IDs.targetRelease} /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n${targetCommon.map(s => '\t\t\t\t' + s).join('\n')}\n\t\t\t\tVALIDATE_PRODUCT = YES;\n\t\t\t};\n\t\t\tname = Release;\n\t\t};\n`;
pb += '/* End XCBuildConfiguration section */\n\n';

// XCConfigurationList
pb += '/* Begin XCConfigurationList section */\n';
pb += `\t\t${IDs.projectConfigList} /* Build configuration list for PBXProject "LanTransfer" */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t${IDs.projectDebug} /* Debug */,\n\t\t\t\t${IDs.projectRelease} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n`;
pb += `\t\t${IDs.targetConfigList} /* Build configuration list for PBXNativeTarget "LanTransfer" */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t${IDs.targetDebug} /* Debug */,\n\t\t\t\t${IDs.targetRelease} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n`;
pb += '/* End XCConfigurationList section */\n\n';

pb += '\t};\n\trootObject = ' + IDs.project + ' /* Project object */;\n}\n';

fs.mkdirSync(PROJ_DIR, { recursive: true });
fs.mkdirSync(SCHEME_DIR, { recursive: true });
fs.writeFileSync(path.join(PROJ_DIR, 'project.pbxproj'), pb, 'utf8');

// 共享 Scheme
const scheme = `<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
    <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        <BuildActionEntries>
            <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${IDs.target}" BuildableName="LanTransfer.app" BlueprintName="LanTransfer" ReferencedContainer="container:LanTransfer.xcodeproj">
                </BuildableReference>
            </BuildActionEntry>
        </BuildActionEntries>
    </BuildAction>
    <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
        <Testables>
        </Testables>
    </TestAction>
    <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
        <BuildableProductRunnable runnableDebuggingMode="0">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${IDs.target}" BuildableName="LanTransfer.app" BlueprintName="LanTransfer" ReferencedContainer="container:LanTransfer.xcodeproj">
            </BuildableReference>
        </BuildableProductRunnable>
    </LaunchAction>
    <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
        <BuildableProductRunnable runnableDebuggingMode="0">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${IDs.target}" BuildableName="LanTransfer.app" BlueprintName="LanTransfer" ReferencedContainer="container:LanTransfer.xcodeproj">
            </BuildableReference>
        </BuildableProductRunnable>
    </ProfileAction>
    <AnalyzeAction buildConfiguration="Debug">
    </AnalyzeAction>
    <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES">
    </ArchiveAction>
</Scheme>
`;
fs.writeFileSync(path.join(SCHEME_DIR, 'LanTransfer.xcscheme'), scheme, 'utf8');

console.log(`生成完成：${swiftFiles.length} 个 Swift 文件`);
console.log('project.pbxproj ->', path.join(PROJ_DIR, 'project.pbxproj'));
console.log('LanTransfer.xcscheme ->', path.join(SCHEME_DIR, 'LanTransfer.xcscheme'));
