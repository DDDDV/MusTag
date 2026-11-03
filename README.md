# MusTag

用于个人验证的 iOS 18+ 音频元数据编辑器。SwiftUI 原生界面，支持中文/英文、浅色/深色。

## 打开和运行

1. 使用 Xcode 打开 `MusTag.xcodeproj`，选择 `MusTag` Scheme。
2. 选择已安装的 iPhone 或 iPad 模拟器运行。真机运行时，在 Signing & Capabilities 中选择自己的开发团队，并按需修改 Bundle Identifier。
3. 工程已包含固定版本的第三方源码；正常构建不需要下载依赖，也不需要安装包管理器。

工程使用本机已有的 XcodeGen 生成。修改 `project.yml` 后，可以运行 `xcodegen generate` 更新工程；日常使用直接打开 `.xcodeproj` 即可。

## 使用

- **添加音频**：选择多个文件或一个目录，支持 MP3、FLAC、M4A。iCloud Drive 和 NAS 通过系统“文件”提供的访问入口使用；NAS 请先在“文件”中连接服务器。
- **手动编辑**：点开文件修改歌名、艺术家、专辑、专辑艺术家、日期、曲序、碟号或流派。
- **识别**：设置中填入自己的 AcoustID **Application API Key**。未配置时仍可编辑标签，并按歌名/艺术家搜索 MusicBrainz。
- **选择结果**：识别只产生候选。选择对应发行版本后，修改进入草稿，不会自动写入。
- **保存**：打开修改预览、确认后写回原文件。每次写入前保留完整原文件备份。
- **撤销**：设置 → 撤销已保存的修改。文件发生外部修改时拒绝自动覆盖；可使用“导出备份”手动恢复。

AcoustID Key 在 https://acoustid.org/new-application 注册应用后获取。不要使用提交指纹的 User API Key。密钥保存在设备 Keychain，不写进源码、URL 或普通配置文件。

## 文件安全

写入路径：协调读取 → 本地暂存 → 检查导入后的源文件哈希 → 完整备份 → 只修改标签 → 重新读取标签 → 校验编码音频数据哈希 → 保存恢复记录 → 协调替换 → 再次校验。

- MP3 校验首个至最后一个 MPEG 帧；FLAC 校验元数据块之后的音频；M4A 校验 `mdat` 内容。修改标签不重新编码音频。
- 未编辑的属性、多值字段和封面交由 TagLib 保留；无法安全保留的旧 ID3 帧或声明“标签修改时丢弃”的帧会阻止写入。不提供封面下载或修改功能。
- 备份保存在本机 Application Support，会占用空间。卸载 App 会删除备份；有长期保留需求时请先导出。
- 文件提供器不支持安全替换时，操作会失败并保留备份。界面完成表示本机文件提供器接受写入，不代表 iCloud/NAS 远端已完成同步。
- 全库处理使用逐文件暂存；云端文件可能需要完整下载和上传。iOS 18 后台可能暂停任务，回到 App 后继续；被系统终止的未完成识别需重试，已保存草稿和备份会保留。

## 识别服务

端侧使用 AVFoundation 解码、Chromaprint 计算真实指纹，向 AcoustID 仅上传指纹与时长。MusicBrainz 提供文字元数据及发行版本候选。歌名搜索会发送填写的歌名与艺术家。

这是个人验证配置。公共 MusicBrainz 请求限制为至少 1.05 秒间隔，AcoustID 至少 0.35 秒间隔。商业上线前确认服务商使用条件，并在 Info.plist 配置 `MusicBrainzContact` 为项目的真实联系邮箱或网站。当前没有配置 API Key，因此交付验证不包含真实 AcoustID 在线命中率。

## 测试

运行 Xcode 的 Product → Test；或者使用本机已安装的模拟器：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project MusTag.xcodeproj -scheme MusTag \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -derivedDataPath work/DerivedData -parallel-testing-enabled NO \
  -disableAutomaticPackageResolution -skipPackageUpdates test
```

如果本机存在重名模拟器，请使用 `id=设备 UUID` 替代名称。测试不自动下载运行时或依赖。

测试覆盖三种真实格式的标签读写/音频负载保持、真实指纹确定性、备份恢复和冲突、识别响应解析，以及基本 UI 流程。网络测试使用固定响应，不会消耗服务额度。

### 本次验证（2026-11-03）

- Xcode 27.2，最低部署版本 iOS 18.0。
- iPhone 16 Pro / iOS 18.6 模拟器：24 项核心测试 + 5 项 UI 测试，全部通过。
- iPhone 通用设备目标 Release 构建通过（未签名，真机运行需配置自己的 Team）。
- 997 个第三方源码文件校验通过，与固定版本官方源码一致。
- AcoustID 在线匹配尚未验证（未提供 API Key）；iCloud/NAS 的实际远端同步和各设备兼容性需要真机验证。

界面截图：[文件列表](outputs/01-library-ios18.png)、[标签编辑](outputs/02-editor-ios18.png)、[修改预览](outputs/03-review-ios18.png)。截图使用本地生成的真实测试音频。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/Core` | 模型、界面状态和批处理编排 |
| `Sources/Views` | 文件列表、编辑、修改预览和设置 |
| `Sources/Services` | 安全写入、识别 API、Keychain、音频处理 |
| `Native` | 自写 TagLib 桥接及构建配置 |
| `Vendor` | 未修改的上游固定版本源码 |
| `Tests` / `UITests` | 核心及界面测试 |
| `work` | 本地构建和验证过程产物 |

第三方版本与许可见 `THIRD_PARTY.md`。本项目自身代码的最终开源许可证由维护者决定。
