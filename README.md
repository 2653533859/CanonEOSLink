# Canon EOS Link

Canon EOS R10 × iPhone 的 USB 联机验证工程，采用 **Flutter + Swift + ImageCaptureCore + Canon EOS PTP**。依据「AI摄影助手方案」最后确定的 USB 路线，包含联机原型、参数控制、AI 摄影指导、姿势参考与 JPEG 修图；无需 CCAPI 激活或拍摄时运行电脑中转。

这是可编译的硬件验证原型。**尚未完成 R10 + iPhone 真机验收，不能把编译通过等同于取景和传图成功。** 第二阶段的软件路径已实现，但相机参数读写和 AI 画面分析尚未经过真实 R10 与实际模型服务验收。姿势参考、基础姿态比较和 JPEG 修图可离线使用；姿态识别的真实表现仍待真机验证，RAW 精修尚未实现。

## 已实现

- 外接相机权限申请、USB 发现、Canon 设备选择、PTP 会话与能力检查。
- GetDeviceInfo、EOS Remote/Event Mode 初始化、EVF 原值读取与恢复。
- Canon 分段 JPEG 提取、后台解码、16 桶亮度直方图与高光溢出指示、像素缓冲池、Flutter Texture、三分构图线、实际显示帧率。
- EOS 半按对焦（`0x9128(1,0)` / `0x9129(1)`）与遥控快门按下/释放；不自动重试快门；命令接受与照片到达分别反馈。
- 完成初始目录枚举后才监听新增 JPEG，结合 `GetEvent (0x9116)` / PTP 对象事件句柄兜底与 `0x9117 TransferComplete` 确认，串行自动下载；支持浏览最近 30 张相机 JPEG、识别同卡 `.cr3`/`.cr2` 同名 RAW 提示（仅提示不传输 RAW）并手动下载。
- 下载先进入缓存，校验后保存到 `Documents/Captures`；保留相机原片。已下载照片支持分页浏览、预览和缩放，重启后仍可读取。
- 单请求 PTP 队列、8 秒命令超时、30 秒连接超时、60 秒下载超时、断线清理、后台限时退出。
- 最近 300 条诊断日志与复制功能。日志不导出相机序列号。
- 读取相机当前曝光模式（含 `Fv` 等 R10 扩展模式）、ISO、快门、光圈、曝光补偿及 `0xD120` 闪光灯状态；根据相机返回的档位与保守模式规则开放调整。每次写入前刷新，写入后要求新事件确认，可撤销上一项修改。
- 配置兼容 Chat Completions 图像输入和 JSON 模式的 HTTPS 服务；API Key 保存在 iOS 钥匙串。用户确认后才上传一张实时取景帧、拍摄目标及相机参数；建议需再次逐项确认，且仅能应用设备当前可用的档位（闪光灯关闭或开启且快门不快于 `1/250s` 时可应用快门建议）。
- 63 组离线姿势参考均配有人像照片，按场景、构图、风格和人数筛选，并提供依据摄影指南整理的基础姿势集合；其中 12 组另有手绘 14 点轮廓可用于实时取景叠加与姿态比较，照片与轮廓是相似动作而非精确匹配。图片来源和许可见 [摄影参考来源](docs/pose-photo-credits.md)。
- 用户确认发送实时取景帧后，AI 可从本地姿势目录推荐最多三项，点击查看参考；推荐基于上次分析的画面，需自行判断适用性。
- 可选本机人体关键点识别（支持读取帧内 EXIF 方向）：开启后在取景中显示关键点，并与所选参考图比较可见肢体角度，给出基础调整提示。默认关闭、最多每秒处理一帧；不上传或保存关键点。
- 已下载 JPEG 支持非破坏性曝光、对比度、饱和度、冷暖、高光与阴影调整、预设、基于平均亮度的自动优化、撤销与原片对比；可保存调整记录并导出独立 JPEG，导出时可选白名单保留安全拍摄参数 EXIF（始终剥离 GPS 与序列号）。
- 用户可将上一次导出的 JPEG 保存到系统相册；首次使用时请求添加照片权限。
- 可选 AI 照片分析：确认后发送去除原片元数据、最长边 1024 像素的调整后预览；模型可建议范围受控的调色参数，需再次确认后才应用，并可撤销。

## 运行

环境：Flutter **3.47.9** / Dart **3.13.7**（本次验证版本）、Xcode、iOS **15.2+**。工程使用 Flutter 当前的 UIScene / implicit engine 注册方式与 Swift Package Manager，无第三方运行时插件。

```bash
# 在仓库根目录；Flutter 应已加入 PATH
./scripts/bootstrap_macos.sh
open ios/Runner.xcworkspace
flutter devices
flutter run -d <iPhone设备ID>
```

在 Xcode 的 Runner → Signing & Capabilities 选择自己的 Development Team，并按需修改 Bundle Identifier。当前为 `com.parado.canonEosLink`。需要 iPhone 开启开发者模式并信任这台 Mac；USB 相机直接连接手机。

本次开发临时使用的 Flutter SDK 位于 `/tmp/canoneoslink-flutter`，未修改系统 PATH。它仍存在时可运行：

```bash
FLUTTER_BIN=/tmp/canoneoslink-flutter/bin/flutter ./scripts/bootstrap_macos.sh
/tmp/canoneoslink-flutter/bin/flutter run -d <iPhone设备ID>
```

`/tmp` 可能被系统清理，长期开发请安装 Flutter 并重新运行初始化脚本。源码、Xcode 工程与测试均在本仓库，SDK 不随项目提交。

## 真机验收顺序

1. 关闭像素蛋糕等其他联机 App，沿用已验证的线材；相机保持开机、iPhone 解锁；选择 JPEG 或 RAW + JPEG。
2. 点击「搜索 USB 相机」，允许访问权限；设备出现后点击连接。等待目录枚举结束。
3. 展开「连接诊断」，读取 GetDeviceInfo，确认日志 `0x1001 → 0x2001` 和真实机型。
4. 点击「开启取景」。只有 JPEG 解码并发布后才显示「实时取景」；等待状态不代表成功。持续观察画面是否更新，再停止并检查相机屏幕恢复。
5. 点击「遥控拍照」，确认相机实际曝光；在日志中分别检查快门命令、新增 JPEG、下载完成。打开已下载照片验证内容。
6. 测试物理快门拍照自动传图、关闭自动下载、手动下载、拔线、关机、切到后台和重新连接。
7. 取景失败时先记录日志，再在诊断中将 `0x200000` 改为 `0x100000` 重试。禁止同时运行多个联机 App。
8. 点击「读取相机参数」，在 P/Tv/Av/M 模式分别验证当前值、可调档位、逐项修改与撤销。无法读回或当前模式不支持的参数应保持不可写。
9. 在 AI 服务设置中输入完整 HTTPS `/chat/completions` 地址、支持图片输入的模型 ID 与 API Key；开启取景，确认发送后检查结果和参数建议。模型输出不会自动操作相机。
10. 打开「姿势参考」筛选并选择姿势；开启取景后检查叠加轮廓、透明度及镜像方向。可选开启「本机姿态识别」，测试单人、遮挡、多人和离开画面时的提示。匹配结果仅供参考。
11. 从「已下载照片」打开 JPEG，测试保存调整、撤销、原片对比和导出；检查原图不变，导出文件位于「文件」App 的 `EOS Link/Exports`。点击「将上次导出保存到相册」，检查权限允许、拒绝和保存结果。可选照片 AI 分析须先确认上传。

详细记录表见 [硬件验收](docs/hardware-validation.md)。通过「文件」App 的 EOS Link 目录或 Finder 文件共享可取出照片。

## 验证

```bash
./scripts/verify.sh
# 完整 iOS 编译（不签名）
flutter build ios --simulator --debug --no-codesign
flutter build ios --debug --no-codesign
```

当前检查记录见 [验证结果](docs/validation.md)。模拟器可以验证启动和界面，无法验证 USB 相机协议。

## 代码组织

| 路径 | 职责 |
| --- | --- |
| `lib/core/camera` | 通道契约、相机状态与操作门控 |
| `lib/features/shooting` | 拍摄、相机文件、本地照片、诊断界面 |
| `lib/features/pose_guide` | 离线姿势目录、轮廓、识别关键点展示和基础角度比较 |
| `lib/features/photo_editor` | 非破坏性调色、对比、导出与照片分析界面 |
| `ios/Runner/CameraBridge/PTPProtocol.swift` | 边界检查、PTP 编解码、EOS 属性事件与取景记录解析 |
| `ios/Runner/CameraBridge/PTPTransport.swift` | ImageCaptureCore 命令串行化与超时 |
| `ios/Runner/CameraBridge/CanonEOS.swift` | EOS 初始化、取景、快门、曝光参数与恢复 |
| `ios/Runner/CameraBridge/ExposureSettings.swift` | 曝光属性事件、相机档位与模式校验 |
| `ios/Runner/CameraBridge/AIGuidance.swift` | AI 结构化请求、响应与档位校验 |
| `ios/Runner/CameraBridge/AIConfigurationStore.swift` | AI 服务设置与钥匙串密钥 |
| `ios/Runner/CameraBridge/PoseTracking.swift` | 本机 Vision 关键点检测、限频和过期清理 |
| `ios/Runner/CameraBridge/PhotoEditCore.swift` | Core Image 调色、方向处理与去元数据 JPEG |
| `ios/Runner/CameraBridge/PhotoEditStorage.swift` | 原片路径校验、编辑记录与独立导出 |
| `ios/Runner/CameraBridge/PhotoEditorBridge.swift` | 照片处理通道与照片 AI 分析 |
| `ios/Runner/CameraBridge/USBCameraCoordinator.swift` | 权限、连接生命周期、目录和下载 |
| `ios/Runner/CameraBridge/JPEGTexture.swift` | 原生 JPEG 解码与 Texture 缓冲 |
| `ios/Runner/CameraBridge/CameraFlutterBridge.swift` | MethodChannel / EventChannel |
| `tests/swift`、`test` | 协议、失败释放、状态、通道和布局测试（`CanonPTPCore` 核心层保持不依赖 UIKit/Flutter/ImageCaptureCore，可直接在 macOS 执行 `swift test`） |

后续四阶段规划见 [开发路线图](docs/roadmap.md)；协议依据、与原方案的必要修正及尚待实现的能力见 [实现边界](docs/architecture.md)。
