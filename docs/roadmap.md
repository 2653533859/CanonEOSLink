# Canon EOS Link 后续开发路线图

本文档记录 Canon EOS R10 × iPhone USB 联机工程的后续四阶段开发计划、涉及模块及验收标准。

> 硬件边界说明：软件层协议、UI 与自动化单元测试可在离线 Mac/模拟器环境推进；涉及实体 EOS R10 与 iPhone 的通信兼容、帧率、自动传图与实际姿态识别精度，必须以 [硬件验收](hardware-validation.md) 真机记录为准。

---

## 阶段一：R10 + iPhone 真机验收与 PTP 传图协议兜底（优先级：P0）

**目标**：打通实体相机与 iPhone 的物理链路，解决 `ImageCaptureCore` 目录监听与 Canon `GetEvent (0x9116)` 潜在事件竞争问题，并对齐 R10 扩展属性枚举。

| 任务项 | 涉及文件 | 具体开发内容 | 验收标准 | 状态 |
| --- | --- | --- | --- | --- |
| **1.1 实机 24 项硬件基线测试** | `docs/hardware-validation.md`<br/>`ios/Runner/CameraBridge/USBCameraCoordinator.swift` | 连接真机逐项执行 24 项硬件检查；对比 `0x9153` 参数 `0x00200000` 与 `0x00100000` 在 R10 固件上的首帧耗时与 60 秒持续帧率。 | 连续取景 10 分钟无崩溃，停止取景与切后台均能恢复机身屏幕显示。 | 待真机连接 |
| **1.2 Canon 对象事件传图兜底** | `ios/Runner/CameraBridge/PTPProtocol.swift`<br/>`ios/Runner/CameraBridge/CanonEOS.swift`<br/>`ios/Runner/CameraBridge/USBCameraCoordinator.swift` | 解析 `0x9116` 中的 `0xC181`/`0xC186`/`0xC1A9` 对象新增记录与 `didReceivePTPEvent` 标准 PTP 事件句柄；实现 `0x9117 (TransferComplete)` 确认并在读写曝光期间保留对象句柄、与目录文件对齐下载。 | 遥控快门与机身物理快门在读写参数并发下，新增 JPEG 不因消费 `0x9116` 而漏传。 | 软件层已完成（待真机验收） |
| **1.3 R10 真实属性枚举对齐** | `ios/Runner/CameraBridge/ExposureSettings.swift`<br/>`tests/swift/ExposureAndAITests.swift` | 补充 `Fv` (`0x37`) 等模式映射、`Fv` 四参数可写规则、小光圈 (`f/36`–`f/64`)、高速电子快门 (`1/10000`–`1/16000`)、慢门 (`0.5s`/`0.4s`) 及扩展 ISO (`40000`/`51200`)。 | 常见档位不显示未知十六进制；真机切换镜头/模式后再采集完整报文补充样本。 | 软件层已完成（待真机核对） |

---

## 阶段二：拍摄控制完善与 AI 实时指导增强（优先级：P1）

**目标**：解除因闪光灯状态未知而受限的快门建议应用，补齐半按快门对焦与实时亮度直方图。

| 任务项 | 涉及文件 | 具体开发内容 | 验收标准 | 状态 |
| --- | --- | --- | --- | --- |
| **2.1 闪光灯同步检测与快门建议解锁** | `ExposureSettings.swift`<br/>`CanonEOS.swift`<br/>`AIGuidance.swift`<br/>`ExposureAndAITests.swift` | 请求并解析 `0xD120` 闪光灯状态；关闭时允许应用 AI 快门建议，开启时仅允许不快于 `1/250s` 同步速度的快门建议；状态未知时保持只读。 | 单元测试覆盖未知、关闭、开启超同步速度、开启安全速度四种分支。 | 软件层已完成（待真机验收） |
| **2.2 半按快门自动对焦** | `CanonEOS.swift`<br/>`USBCameraCoordinator.swift`<br/>`shooting_page.dart`<br/>`PTPTests.swift` | 实现 `autofocus()` 发送 `0x9128(1, 0)` 与必达释放 `0x9129(1)`，在取景拍摄页增加「半按对焦」按钮。 | 按钮门控与拍照一致，失败亦尝试释放半按。 | 软件层已完成（待真机验收） |
| **2.3 实时取景直方图与高光溢出提示** | `JPEGTexture.swift`<br/>`USBCameraCoordinator.swift`<br/>`camera_bridge.dart`<br/>`shooting_page.dart` | 解码取景帧时降采样计算 16 桶亮度直方图与高光溢出阈值标记，随快照发布到取景框角部轻量 HUD。 | 不阻塞取景线程，停帧/断线自动清理直方图状态。 | 软件层已完成（待真机验收） |

---

## 阶段三：手绘骨架姿势库扩充与姿态比对旋转适配（优先级：P1）

**目标**：在不污染「纯真人参考图（不提供未校验叠加骨架）」安全契约的前提下，扩充可叠加并支持本机比对的 14 点骨架姿势库，并适配 EXIF 方向。

| 任务项 | 涉及文件 | 具体开发内容 | 验收标准 | 状态 |
| --- | --- | --- | --- | --- |
| **3.1 扩充手绘 14 点骨架姿势（6 → 12 组）** | `lib/features/pose_guide/pose_reference.dart` | 新增 6 组几何校验通过的单人 14 点骨架姿势（复用本地授权 Pexels 照片与完整署名），保持 `photoPoseReferences` 纯参考不叠加不变。 | `pose_tracking_test.dart` 在镜像与 `1.5`/`0.67` 画幅下全部通过；`stage3_test.dart` 全部通过。 | 软件层已完成（待真机验收） |
| **3.2 Vision 姿态检测 EXIF 方向适配** | `ios/Runner/CameraBridge/PoseTracking.swift` | 读取取景帧 `kCGImagePropertyOrientation` 转换为 `CGImagePropertyOrientation` 传入 `VNImageRequestHandler`。 | 不破坏既有无旋转帧方向行为，支持带方向标记的竖拍帧。 | 软件层已完成（待真机验收） |

---

## 阶段四：修图管线升级、安全 EXIF 保留与 CR3 伴随识别（优先级：P2）

**目标**：升级外拍修图管线，支持高光/阴影精细调整、隐私安全的拍摄参数 EXIF 保留及 RAW+JPEG 伴随文件识别。

| 任务项 | 涉及文件 | 具体开发内容 | 验收标准 | 状态 |
| --- | --- | --- | --- | --- |
| **4.1 高光与阴影调节** | `PhotoEditCore.swift`<br/>`photo_repository.dart`<br/>`photo_editor_page.dart`<br/>`PhotoEditTests.swift` | `PhotoRecipe` 扩展 `highlights` / `shadows`（`-1...1`），接入 `CIHighlightShadowAdjust`，兼容既有 AI 调色四参数 JSON 与历史配方。 | 范围越界/布尔值拒绝，滑块实时预览与撤销正常，既有测试兼容通过。 | 软件层已完成（待真机验收） |
| **4.2 隐私安全 EXIF 可选保留** | `PhotoEditCore.swift`<br/>`PhotoEditorBridge.swift`<br/>`photo_repository.dart`<br/>`photo_editor_page.dart` | 新增 `safeExifMetadata` 白名单提取快门、光圈、ISO、焦距、镜头/机型与拍摄时间，绝不复制 GPS 与序列号；导出开关默认关闭、AI 分析强制剥离。 | 单元测试校验启用保留时写回安全 EXIF 且 `GPSDictionary` 为空。 | 软件层已完成（待真机验收） |
| **4.3 CR3/CR2 伴随文件识别** | `USBCameraCoordinator.swift`<br/>`camera_bridge.dart`<br/>`shooting_page.dart` | 扫描相机目录 `.cr3`/`.cr2` 同名文件，快照下发 `rawCount` 与每张照片的 `hasRAW` 标识，在相机文件列表中展示 `RAW+JPEG` 标签。 | 不影响现有仅 JPEG 列表与分页下载流程。 | 软件层已完成（待真机验收） |
