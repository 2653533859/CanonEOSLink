# 验证记录

日期：2026-11-11。环境：Apple Silicon macOS、Xcode 27.2、Flutter 3.47.9、Dart 3.13.7。

## 第一阶段

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Flutter analyze | 通过，无问题 | Dart 静态检查 |
| Flutter test | 8 项通过 | 重复快门门控、断线状态、原生错误、通道契约、428×926 / 320×568 / 926×428 布局、首帧状态 |
| swift test | 10 项通过 | PTP 字节布局、坏包、EOS 事件、EVF 恢复、关闭顺序、快门失败释放、缺少属性和非 Canon 设备 |
| Xcode RunnerTests | 2 项通过 | 原生 JPEG 拒绝损坏输入、缓冲尺寸/BGRA格式/上下方向、帧清理 |
| iOS simulator debug build | 通过 | 完整 Flutter + Swift + 原生框架链接 |
| iOS device debug build --no-codesign | 通过 | arm64 真机架构编译；没有签名或安装到实体 iPhone |
| 模拟器启动与截图检查 | 通过 | iPhone 17 Pro Max / iOS 26.5；初始真实断开状态，没有模拟连接 |
| plist / Xcode project lint | 通过 | 权限、工程注册、文件结构 |
| R10 + iPhone 实际 USB | 未执行 | 本机无在线 iPhone；实机连接、取景、快门和自动传图均待验收 |

原生测试运行方式（将设备 ID 替换为本机 `xcrun simctl list devices available` 中的 iPhone）：

```bash
xcodebuild test \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=<模拟器ID>' \
  CODE_SIGN_IDENTITY=-
```

测试只证明受测协议与软件路径，不代表 R10 的厂商协议在当前固件和线材上已通过。自动下载依赖 ImageCaptureCore 发出新增文件通知；如未触发，需按硬件验收日志继续适配 Canon 对象事件。

## 第二阶段

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Flutter analyze | 通过 | Dart 静态检查 |
| Flutter test | 13 项通过 | 首帧、布局、参数确认与版本、AI 上传确认、建议应用确认、过期建议和配置校验 |
| swift test | 25 项通过 | EOS 事件与档位、模式限制、写入确认、撤销、外部变更、AI 结构与安全校验、模拟 HTTP 请求与错误处理 |
| Xcode RunnerTests | 3 项通过 | 原生 JPEG 解码与方向、模拟器钥匙串存取与密钥绑定 |
| iOS simulator debug build | 通过 | Flutter、Swift 与原生模块编译 |
| iOS device debug build --no-codesign | 通过 | 真机架构编译；未签名、未安装 |
| 实际相机和模型服务 | 未执行 | 无实体设备演示，模型请求使用本地 URLProtocol 模拟 |

钥匙串测试需要模拟器本地临时签名（`CODE_SIGN_IDENTITY=-`）；完全关闭签名时模拟器 Keychain 拒绝访问。此签名仅用于本机模拟器，不涉及发布。Xcode 27.2 的测试链接输出了 XCTest 最低版本提示，模拟器测试通过；这不改变 App 的 iOS 15.2 部署目标。

目前没有真实 Canon R10 的参数事件、外接闪光灯同步状态或真实云端模型的测试证据；不要把自动化测试结果视为硬件兼容或建议质量的证明。

## 第三阶段（2026-11-12）

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Flutter analyze | 通过 | Dart 静态检查 |
| Flutter test | 22 项通过 | 姿势目录筛选与选择、大小屏布局、调色预设、撤销、原片对比、导出、AI 确认和过期建议、预览请求合并，以及原有功能回归 |
| swift test | 34 项通过 | JPEG 方向、预览与全尺寸导出、EXIF/GPS 去除、亮度自动优化、冷暖方向、参数范围、编辑记录、原片保护、路径与符号链接校验、模拟 AI 请求和建议校验 |
| Xcode RunnerTests | 4 项通过 | iOS 模拟器上的照片调整、记录与原片保护，以及原有 Texture、钥匙串回归 |
| iOS simulator debug build | 通过 | Flutter 与原生模块完整编译 |
| iOS device debug build --no-codesign | 通过 | 真机架构编译；未签名、未安装 |
| 实际相机、真实人物和模型服务 | 未执行 | 无实体设备演示；姿势轮廓、AI 效果及真实照片表现需后续验收 |

姿势参考使用手工绘制的二维示意轮廓；没有进行人体识别或姿态匹配。JPEG 导出会生成独立文件并去掉原始 EXIF/GPS；调整历史仅在当前编辑会话中可撤销，已保存的最后一份调整记录可重新加载。自动优化是本地亮度规则，不是 AI；照片 AI 调色仅在用户确认后应用到预览，不会自动保存或导出。

## 本机姿态识别与基础匹配（2026-11-12）

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Flutter analyze | 通过 | Dart 静态检查 |
| Flutter test | 27 项通过 | 关键点过滤、镜像与画幅、遮挡和多人状态、匹配提示及识别开关流程 |
| swift test | 39 项通过 | 关键点坐标和置信度、任务节流与过期、暂停和关闭、macOS Vision 空白图检测及原有功能回归 |
| Xcode RunnerTests | 4 项通过，1 项跳过 | iOS 模拟器 Vision 人体姿态请求初始化返回 Code 9，空白图检测跳过；其余测试通过 |
| iOS simulator debug build | 通过 | Flutter 与原生模块编译 |
| iOS device debug build --no-codesign | 通过 | 真机架构编译；未签名、未安装 |
| 真实人物与相机 | 未执行 | 识别准确度、实际取景表现和设备性能待后续验收 |

人体关键点仅在用户开启后本机处理；自动化测试中的姿态匹配使用合成关键点，不能证明真实人物识别或匹配效果。模拟器的 Vision 初始化失败也不能证明真机是否支持该请求。

## 导出照片保存到系统相册（2026-11-13）

Flutter 静态检查通过；照片编辑相关 Flutter 测试 9 项通过，覆盖导出后的保存入口和通道参数。Swift 测试覆盖导出目录校验、拒绝原片路径与跨目录符号链接。iOS 模拟器调试版本编译通过。

系统相册授权弹窗、拒绝权限后的实际系统行为与照片写入结果尚未在设备上验证；模拟通道测试不代表照片已实际写入相册。

## 已下载照片分页（2026-11-13）

本地目录按文件名倒序分页，每页最多 30 张；状态事件只传数量，打开列表或手动刷新时重新读取目录。Swift 测试覆盖 125 张、空目录、恰满一页和翻页过程中新增照片；Flutter 测试覆盖分页、失败重试、刷新与通道参数。模拟器版本编译通过；未进行实体相机或 iPhone 演示。

## 取景姿势推荐（2026-11-13）

姿势推荐复用需用户确认的取景 AI 请求，发送当前帧、目标、曝光设置和本地姿势目录的文字信息；模型只能返回目录中的 ID，未知和重复 ID 被过滤。测试覆盖模拟模型响应、候选白名单、推荐跳转和原有流程；真人照片仅供参考，不产生未经验证的叠加骨架。真实相机画面、实际模型服务与推荐质量尚未验收。

## 后续四阶段演进开发验证（2026-11-15）

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Flutter analyze | 通过，无问题 | Dart 静态检查 |
| Flutter test | 40 项通过 | 半按对焦、闪光灯快门同步建议、直方图与高光溢出 HUD、12 组 14 点骨架几何与镜像、高光/阴影/安全 EXIF 导出开关、CR3 伴随提示及既有回归 |
| swift test | 50 项通过 | `0x9116`/`didReceivePTPEvent` 对象句柄解析与 `0x9117 TransferComplete`、R10 `Fv` 与扩展档位、`0xD120` 闪光灯同步判定、半按对焦必达释放、Vision EXIF 方向适配、高光/阴影渲染与安全 EXIF 白名单剥离 GPS/序列号 |
| R10 + iPhone 实际硬件与真实模型服务 | 未执行 | 本机未连接物理相机与真机，软件层已完成，待连接实体设备按 [硬件验收](hardware-validation.md) 逐项验收 |
