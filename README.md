# MusTag

用于个人验证的 iOS 18+ 音频元数据编辑器。SwiftUI 原生界面，支持中文/英文、浅色/深色。

## 打开和运行

1. 使用 Xcode 打开 `MusTag.xcodeproj`，选择 `MusTag` Scheme。
2. 选择已安装的 iPhone 或 iPad 模拟器运行。真机运行时，在 Signing & Capabilities 中选择自己的开发团队，并按需修改 Bundle Identifier。
3. 工程已包含固定版本的第三方源码；正常构建不需要下载依赖，也不需要安装包管理器。

工程使用本机已有的 XcodeGen 生成。修改 `project.yml` 后，可以运行 `xcodegen generate` 更新工程；日常使用直接打开 `.xcodeproj` 即可。

## 使用

- **添加音频**：选择多个文件或一个目录，支持 MP3、FLAC、M4A。iCloud Drive 和 NAS 通过系统“文件”提供的访问入口使用；NAS 请先在“文件”中连接服务器。
- **文件夹分类**：首页按“文件夹”和“文件”展示导入内容。点击文件夹查看其中的音频（包含子目录），在文件夹内选择、识别和预览修改仅作用于该文件夹；首页的批量操作仍覆盖整个资料库。空文件夹也会保留入口，重复导入会刷新内容并保留草稿和分组。同名的不同文件夹会显示来源路径以便区分。
- 旧版本没有记录导入来源，原有条目会保留在“文件”分类；重新选择对应文件夹后即可归入文件夹，已有草稿会保留。
- **批量移除**：点击“选择”，勾选文件或“全选”，再点击底部“从列表移除”并确认。仅移除所选文件的列表记录和未保存的修改，原始音频和已保存的备份会保留；空文件夹入口也会保留。
- **手动编辑**：点开文件修改歌名、艺术家、专辑、专辑艺术家、日期、曲序、碟号或流派。
- **识别服务**：默认使用 **ShazamKit**，无需填写 API Key；设置中可切换为 AcoustID，选择会保存在设备上。两种方式都支持所选文件、当前文件夹和全部资料库，不会在服务失败时自动切换到另一家。
- **Shazam 自动匹配**：直接读取文件生成音频签名，不使用麦克风。唯一匹配将歌名、艺术家、流派及可用封面填入草稿；多条匹配需手选，未匹配保留原草稿。不显示或伪造 AcoustID 相似度，不套用 90% 门槛。基础识别结果没有专辑版本、专辑艺术家、年份、曲序及碟号，这些原有字段会保留，可按歌名搜索 MusicBrainz 再选择发行版本。
- **AcoustID 自动匹配**：设置中填入自己的 **Application API Key** 后使用。候选按指纹相似度从高到低排列，自动采用最高分且达到 **90%** 的结果；门槛固定。未配置 Key 时仍可用 ShazamKit、手动编辑及歌名搜索。
- **AcoustID 版本选择**：最高分并列时，优先采用与原文件专辑名称一致的唯一候选；仍无法区分、低于 90% 或未匹配的文件保留原草稿，提示手动处理。同一录音的多个发行版本共用指纹分数，分数不能区分专辑版本，也不代表识别正确率。编辑页展示相似度和已采用标记，可手动改选（包括低于 90% 的候选）。歌名搜索结果需手动选择。
- **批量草稿**：自动匹配将文字标签和对应正面封面填入草稿，非空字段更新现有内容，空缺字段保留原值。每完成一个文件便保存草稿，单个文件失败后继续处理其他文件；结束时汇总已填入、待确认、未匹配及失败数量。点击“停止”保留已完成的草稿，正在处理和未处理的文件保持此前草稿。
- **封面**：列表和编辑页显示文件内嵌封面；点击封面可放大预览。下载失败或版本无封面时保留原封面，重新选择版本可重试；也可以单独撤销封面修改。
- **保存**：打开修改预览，核对文字差异和新旧封面对比，确认后写回原文件。仅更换封面也可以保存。每次写入前保留完整原文件备份。
- **撤销**：设置 → 撤销已保存的修改。文件发生外部修改时拒绝自动覆盖；可使用“导出备份”手动恢复。

AcoustID Key 在 https://acoustid.org/new-application 注册应用后获取。不要使用提交指纹的 User API Key。密钥保存在设备 Keychain，不写进源码、URL 或普通配置文件。

## 文件安全

写入路径：协调读取 → 本地暂存 → 检查导入后的源文件哈希 → 完整备份 → 只修改标签 → 重新读取标签 → 校验编码音频数据哈希 → 保存恢复记录 → 协调替换 → 再次校验。

- MP3 校验首个至最后一个 MPEG 帧；FLAC 校验元数据块之后的音频；M4A 校验 `mdat` 内容。修改标签不重新编码音频。
- 未编辑的属性、多值字段和封面交由 TagLib 保留；无法安全保留的旧 ID3 帧或声明“标签修改时丢弃”的帧会阻止写入。
- MP3/FLAC 更换正面封面时保留背面等其他图片；M4A 更换第一张封面并保留后续图片。写后重新读取并校验封面和音频数据，撤销恢复包含原封面的完整文件。
- 备份保存在本机 Application Support，会占用空间。卸载 App 会删除备份；有长期保留需求时请先导出。
- 文件提供器不支持安全替换时，操作会失败并保留备份。界面完成表示本机文件提供器接受写入，不代表 iCloud/NAS 远端已完成同步。
- 全库处理使用逐文件暂存；云端文件可能需要完整下载和上传。iOS 18 后台可能暂停任务，回到 App 后继续；被系统终止的未完成识别需重试，已保存草稿和备份会保留。

## 识别服务

ShazamKit 使用系统框架，不新增第三方依赖。AVFoundation 分块解码开头最多三个片段，每段通常最多 12 秒，并遵守 Shazam 曲库的查询时长限制；只向 Apple 发送不可逆音频签名。未命中时尝试下一段，命中后停止；每次匹配最多等待 30 秒，可以取消。没有麦克风权限、Apple Music 播放授权或写入 Shazam 历史的请求。

首次真实识别前，需要在 [Apple Developer → Certificates, Identifiers & Profiles](https://developer.apple.com/help/account/services/shazamkit/) 中为实际使用的 App ID 启用 **App Services → ShazamKit**，并用对应开发团队签名。工程已链接系统 ShazamKit.framework，但代码和模拟测试无法替代账户侧服务启用。项目保留现有 Bundle Identifier/签名团队；若使用自己的团队，请同步修改 App ID 和签名配置。

Shazam 返回的标识与 MusicBrainz recording/release UUID 分开存储，不会自动送往 MusicBrainz 或 Cover Art Archive。封面仅接受返回的 HTTPS `mzstatic.com` 及其子域链接；缺失、格式不支持、超限或下载失败时保留原封面。候选和已采用内容显示 Apple Music 链接（返回链接时）；最近采用的 Shazam 识别记录随草稿、保存和备份恢复持久化，重启后仍可查看。后续手工编辑或 MusicBrainz 选择可能只保留部分 Shazam 字段，因此这条记录不表示当前全部标签均来自 Shazam。此分支用于技术验证，接入和测试并不解决“元数据/封面永久写入用户文件”的许可范围问题，上线前仍需确认。

选择 AcoustID 时，端侧使用 AVFoundation 解码、Chromaprint 计算真实指纹，向 AcoustID 仅上传指纹与时长。MusicBrainz 提供文字元数据及发行版本候选。歌名搜索会发送填写的歌名与艺术家。

选择发行版本后，向 Cover Art Archive 请求该版本的正面封面，并跟随 HTTPS 跳转从 Internet Archive 下载；不向封面服务发送音频、指纹或 AcoustID Key。优先请求 1200px 缩略图，缺失时尝试同一版本原图，不使用其他发行版本代替。支持 JPEG/PNG，单张最多 8 MiB、4000 万像素。未确认保存的封面随草稿保留，下载或取消操作不会改动原文件。

这是个人验证配置。公共 MusicBrainz 请求限制为至少 1.05 秒间隔，AcoustID 至少 0.35 秒间隔。商业上线前确认服务商使用条件，并在 Info.plist 配置 `MusicBrainzContact` 为项目的真实联系邮箱或网站。当前自动化测试使用固定匹配响应，不代表 ShazamKit 或 AcoustID 的真实在线命中率。

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
- iPhone 16 Pro / iOS 18.6 模拟器：57 项核心测试 + 6 项 UI 测试，全部通过。
- iPhone 通用设备目标 Release 构建通过（未签名，真机运行需配置自己的 Team）。
- 997 个第三方源码文件校验通过，与固定版本官方源码一致。
- Cover Art Archive 公开示例在电脑当前系统网络隧道下的 HTTPS 重定向及实际封面下载通过，不代表手机直连可用；固定响应测试覆盖缺图回退、无效图片、超限、取消和服务错误。
- 网络诊断增补验证：17 项封面下载测试及 5 项草稿流程测试通过。下载错误提示区分超时、DNS、连接和证书等原因，并显示失败域名及错误码。部分地区或网络可能无法访问封面服务及 Internet Archive 图片服务器。
- 文件夹分类增补验证：71 项核心测试、9 项 UI 测试通过，覆盖混合导入、嵌套及空文件夹、重复导入保留草稿、旧资料库迁移、恢复后分组，以及文件夹导航和批量操作范围。
- 批量自动匹配增补验证：88 项核心测试、12 项 UI 测试通过，覆盖固定 90% 边界、候选排序、同分原专辑选择、发行信息不完整时转人工、处理范围、失败继续、封面回退、取消时草稿持久化及预览后保存；网络响应使用本地测试数据。
- AcoustID 在线匹配尚未验证（未提供 API Key）；iCloud/NAS 的实际远端同步和各设备兼容性需要真机验证。

界面截图：[文件列表](outputs/01-library-ios18.png)、[标签编辑](outputs/02-editor-ios18.png)、[修改预览](outputs/03-review-ios18.png)、[封面对比预览](outputs/04-cover-review-ios18.png)。截图使用本地生成的真实测试音频；封面流程截图使用隔离的固定网络响应和测试图片。

### ShazamKit 接入验证（2026-11-04）

- iPhone 16 Pro / iOS 18.6：119 项核心测试全部通过；新增签名转换、匹配超时/取消、Shazam 草稿及来源持久化、封面域隔离等测试。
- 14 项 UI 用例首轮 13 项通过；修复候选行空白区域无法点击后，封面选择/保存/恢复、AcoustID 自动匹配及 Shazam 无 Key 识别三条相关流程复测全部通过。
- 通用 iPhone Release 构建通过（未签名）；保留原 Bundle Identifier 和开发团队。
- 已在开发者团队 `947X8JA62C` 下注册明确的 App ID `app.mustag.personal`，启用 ShazamKit App Service，并重新打开后台记录确认保存成功。
- 测试使用真实本地音频与固定服务响应，不发送实际识别请求。服务启用后的真机联网识别及真实返回的封面链接尚未验证。
- 日志：`work/shazam-core-test.log`、`work/shazam-ui-test.log`、`work/shazam-ui-final-test.log`、`work/shazam-device-build.log`。

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
