# MusTag MVP 验证结果

日期：2026-11-03。工程：`/Users/liang/workspace/MusTag/MusTag.xcodeproj`。

| 验证项 | 结果 |
| --- | --- |
| 最低部署版本 | iOS 18.0 |
| 编译工具 | Xcode 27.2 / Swift 5 language mode |
| 模拟器 | iPhone 16 Pro / iOS 18.6 |
| 文件安全测试 | 17 / 17 通过 |
| 识别协议与响应测试 | 15 / 15 通过 |
| 原生标签、封面与音频指纹测试 | 8 / 8 通过 |
| 封面下载协议测试 | 12 / 12 通过 |
| 候选选择与封面草稿流程测试 | 5 / 5 通过 |
| UI 流程测试 | 6 / 6 通过 |
| iPhone Release 构建 | 通过，未签名 |
| 第三方源码完整性 | 997 个文件通过，与上游一致 |

实际验证：MP3、FLAC、M4A 的标签修改保持编码音频数据不变；旧 ID3 丢弃标志会阻止不安全写入；真实 Chromaprint 指纹可重复计算；完整备份可恢复到原始字节；源文件外部修改、备份损坏和撤销顺序错误被拦截。UI 测试通过真实生成的 AAC/M4A 文件完成编辑、差异预览、保存和恢复。

封面验证：三种格式新增/替换封面、文字编辑保留封面、仅封面保存与精确撤销通过。MP3 保留背面图片。覆盖所选版本缩略图 404 时回退同版本原图、两者缺图、下载失败、无效/超大图片、取消及重新选择版本不残留其他版本封面。旧资料库读取内嵌封面并保留待定草稿。UI 覆盖选择版本、放大新封面、取消预览后草稿仍待保存、确认保存和撤销。

公开接口检查：官方文档示例发行 ID `76df3287-6cda-33eb-8e9a-044b5e15ffdd` 的 `front-1200` 经 HTTPS 跳转到 Internet Archive，返回 HTTP 200、JPEG、40,684 字节。未发送用户音频或密钥。电脑当时存在系统网络隧道，此结果不代表手机直连可用。

网络诊断增补：用户反馈手机在当前 Wi-Fi 下通过 Safari 也无法打开封面链接；电脑经系统隧道可下载《我很忙》2007 年大陆版和台湾版封面。现象与网络访问限制相符，未取得手机底层错误码，不能确定具体阻断环节。代码已增加网络错误分类、失败域名及错误码；相关 17 项封面下载测试和 5 项草稿流程测试通过，结果位于 `work/MusTag-cover-network-diagnostics.xcresult`，日志为 `work/cover-network-diagnostics-test.log`。收到停止测试要求后未再执行测试。

未验证：AcoustID 的真实在线命中（无 API Key），真实 iCloud/NAS 的下载、同步、断网和各文件提供器兼容性。识别网络测试使用固定响应，不会伪造生产环境识别结果。

本次 57 项核心测试结果位于 `work/MusTag-cover-core-final.xcresult`，日志为 `work/cover-core-final-test.log`。6 项 UI 测试在 `work/MusTag-cover-full.xcresult` 中全部通过；该次运行还包含一项已在最终核心测试中修正并复验的回退路径断言。Release 构建日志为 `work/cover-device-build.log`。

截图均为真实模拟器画面，使用隔离的测试音频：

- [文件列表](01-library-ios18.png)
- [标签编辑](02-editor-ios18.png)
- [修改预览](03-review-ios18.png)
- [封面对比预览](04-cover-review-ios18.png)（隔离的固定响应与测试图片）


## ShazamKit 接入增补（2026-11-04）

分支：`codex/shazamkit-integration`，基于 `dev`。系统 ShazamKit 框架接入；未安装新依赖，未修改 Vendor。

- **核心测试：119 / 119 通过**。包含真实 48kHz 双声道音频转为受限时长 Shazam 签名、三窗口匹配、未命中、取消、超时、错误脱敏、独立服务偏好、无 Key 识别、缺失标签保留、封面失败回退、草稿持久化、确认保存及完整备份恢复。Shazam 标识不用于 MusicBrainz/CAA 请求，不伪造 AcoustID 分数。
- **UI：首轮 14 项中 13 项通过**。候选行改成独立按钮后，空白区域未命中按钮导致旧封面流程失败；已为完整候选行设置命中区域。最终重跑封面选择/预览/保存/恢复、AcoustID 自动匹配、Shazam 无 Key 自动匹配三项，全部通过。最后两项同时覆盖候选状态、Apple Music 独立链接及来源记录展示。
- **通用 iPhone Release：通过，未签名**。保留原有签名团队与 Bundle Identifier，新增系统 ShazamKit 链接。
- **账户服务已启用并复查**。已在团队 `947X8JA62C` 下注册明确的 App ID `app.mustag.personal`，开启 ShazamKit App Service，并重新打开后台记录确认保存成功。
- **服务启用后的真机联网识别尚未验证**。自动化测试注入固定匹配/封面响应，真实命中及封面仍需实测，并使用对应团队签名。此验证不代表内容永久写入文件的许可已确认。

日志分别为 `work/shazam-core-test.log`、`work/shazam-ui-test.log`、`work/shazam-ui-final-test.log`、`work/shazam-device-build.log`。最终 UI 结果：`work/DerivedData/Logs/Test/Test-MusTag-2026.11.04_12-58-00-+0800.xcresult`。
