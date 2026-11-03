# MusTag MVP 验证结果

日期：2026-11-03。工程：`/Users/liang/workspace/MusTag/MusTag.xcodeproj`。

| 验证项 | 结果 |
| --- | --- |
| 最低部署版本 | iOS 18.0 |
| 编译工具 | Xcode 27.2 / Swift 5 language mode |
| 模拟器 | iPhone 16 Pro / iOS 18.6 |
| 文件安全测试 | 12 / 12 通过 |
| 识别协议与响应测试 | 8 / 8 通过 |
| 原生标签与音频指纹测试 | 4 / 4 通过 |
| UI 流程测试 | 5 / 5 通过 |
| iPhone Release 构建 | 通过，未签名 |
| 第三方源码完整性 | 997 个文件通过，与上游一致 |

实际验证：MP3、FLAC、M4A 的标签修改保持编码音频数据不变；旧 ID3 丢弃标志会阻止不安全写入；真实 Chromaprint 指纹可重复计算；完整备份可恢复到原始字节；源文件外部修改、备份损坏和撤销顺序错误被拦截。UI 测试通过真实生成的 AAC/M4A 文件完成编辑、差异预览、保存和恢复。

未验证：AcoustID 的真实在线命中（无 API Key），真实 iCloud/NAS 的下载、同步、断网和各文件提供器兼容性。识别网络测试使用固定响应，不会伪造生产环境识别结果。

最终完整测试结果位于 `work/MusTag-final-iOS18.xcresult`；日志为 `work/final-test.log` 和 `work/device-build-final.log`。

截图均为真实模拟器画面，使用隔离的测试音频：

- [文件列表](01-library-ios18.png)
- [标签编辑](02-editor-ios18.png)
- [修改预览](03-review-ios18.png)
