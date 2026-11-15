# 实现与协议边界

## 数据流

```text
EOS R10 → USB → ImageCaptureCore → 串行 PTP transport → CanonEOS
                                                    ↓ JPEG
Flutter 拍摄页 ← Texture ← 像素缓冲池 ← 后台 JPEG 解码
       ↑ 状态与文件路径
       └ EventChannel ← USBCameraCoordinator ← 目录新增 / 原生文件下载
       └ MethodChannel → USBCameraCoordinator
```

控制通道 `com.parado.canoneos/control`；状态通道 `com.parado.canoneos/events`。整帧和照片二进制不经过 Dart。状态事件是完整快照；命令返回的快照不覆盖更新较新的事件。所有 IC delegate 入口转交 MainActor，解码使用单独串行队列；取帧等待上一帧解码完成，限制在约 10 fps 的请求上限，不承诺实际帧率。

状态：disconnected → discovering → connecting → ready → liveview_starting → liveview_running。解码前不会标记运行成功。命令超时后 transport 作废并关闭会话，必须重新连接；不会放行下个命令与超时请求重叠。下载与取帧互斥，下载期间暂停帧请求。后台限时等待当前操作结束、恢复 EVF 并关闭会话；期限或系统后台时间耗尽则强制清理。拔线时无法保证相机收到恢复命令。

## 对原方案的必要修正

以本机 iOS 27.2 SDK 头文件与上游 libgphoto2 提交 `c4cd525d7461c26b89b4705dc74fc4b84d57ff3a` 核对，代码为按协议重新实现，没有复制 libgphoto2 源码。

- `requestTakePicture` 在 iOS 不可用，使用 EOS `0x9128(3,0)` / `0x9129(3)`；失败也尝试释放，绝不自动重试拍照。
- R10 remote mode 为 `0x9114(1)`，event mode 为 `0x9115(1)`。
- `D1B0` 为 EVF 输出，PC 位为 2；`D1B1` 为 EVF 模式，开启值为 1。不是交换写入这两个属性。
- `0x9110` 零参数，发送 12 字节小端 `[长度12, 属性, 值]`。
- 初始 `0x9116` 属性事件保存 EVF 原值；若未取得，不猜测原值、不启动取景。PC 输出使用 `原值 | 2`，停止时恢复。
- R10 上游转储未声明 `0x9151/0x9152`，不盲发这些命令。默认取帧 `0x9153(0x00200000,0,0)`，另提供 `0x00100000` 手动验证选项。
- 取景数据按 `[length,type,payload]` 分段校验；只接受 type 1/11 的 JPEG，不把 RAW 块或任意缩略图当取景帧。
- 退出恢复 EVF 后执行 RemoteMode(0) → RemoteMode(1) → EventMode(0)，随后关闭 ImageCaptureCore 会话。

## 传图限制

当前是**存储卡 JPEG + ImageCaptureCore 目录监听**，保持相机现有 CaptureDestination，不写 Host/SDRAM 模式。初次完整枚举用于基线，旧照片不会自动全盘下载。新增 JPEG 可自动下载，也可手动下载目录已有 JPEG。

ImageCaptureCore 不保证将每条 Canon 私有 GetEvent 对象记录变成目录新增通知。软件层在初始化及参数读取期间会保留 `0x9116` 中的 `0xC181`/`0xC186`/`0xC1A9` 新增对象句柄与 `didReceivePTPEvent` 标准对象事件（如 `0x4002` 等），在目录文件对账后下载并在下载完成后发送 `0x9117 (TransferComplete)` 确认，降低与物理快门及目录事件的竞争。实机传图表现仍须以真机日志验收为准。「刷新目录」只刷新系统当前快照，不伪称强制重新扫描相机。相机文件扫描同步统计 `.cr3`/`.cr2` 伴随 RAW 数量（`rawCount`）与同文件名标识（`hasRAW`），仅作列表提示而不传输或解码 RAW。

## 参数控制与 AI 指导

曝光属性包括 D101 光圈、D102 快门、D103 ISO、D104 曝光补偿、D105 曝光模式与 `0xD120` 闪光灯状态，模式表及档位目录已扩展对齐 R10 常见档位（含 `Fv` 四参数可写、扩展光圈/高速快门/慢门/高 ISO）。解析 GetEvent 的 C189 当前值与 C18A 可选值；档位只取相机报告列表和已识别编码的交集，未知值以十六进制显示、不可写。模式限制采用保守规则：Av/M/Fv 可调整光圈、Tv/M/Fv 可调整快门、P/Tv/Av/M/Fv 可调整 ISO、P/Tv/Av/Fv 可调整曝光补偿；M + Auto ISO 的曝光补偿保持只读。半按自动对焦使用 `0x9128(1, 0)` 与必达释放 `0x9129(1)`。实时取景解码时降采样统计 16 桶亮度直方图与高光溢出标记（`highlightClipped`）并随快照下发。所有枚举、对焦和闪光灯属性均需真机验证。

手动修改与模型建议均使用同一写入路径。应用前通过 `0x9127` 请求当前模式和参数值，重新消费 `0x9116` 事件；若参数版本、模式或可选列表变化，拒绝写入。`0x9110` 成功只表示请求被接受；还需请求并收到目标参数和模式的新 C189 事件才报告确认。失败或无读回时，状态标记为未确认；撤销前重新读取，并要求当前值仍为上次设置值、模式未变、原值仍在可用列表。只保留本次连接中最近一项的撤销记录；断线或 App 退出后不自动写回。

读取曝光参数需要按需使用 Canon `GetEvent`，可能与 ImageCaptureCore 对私有事件的处理存在竞争；虽已保留并排队 `0x9116` 中的对象事件，真机高并发场景下的传图完整性与 `RequestDevicePropValue` 对 R10 属性的具体行为仍需真机验证。无法取得当前值或可用列表时，界面保持只读。

AI 接口由用户指定完整的 HTTPS Chat Completions 地址和图片模型 ID，密钥使用 iOS Keychain `WhenUnlockedThisDeviceOnly` 存储，不写入日志或普通设置；切换地址须提供该地址对应的密钥。应用只在用户确认后发送一张近期实时取景 JPEG、拍摄目标和当前参数；不跟随 HTTP 重定向，避免向跳转目标发送密钥和画面。要求服务支持 `image_url` 的 base64 JPEG 和 `response_format: json_object`，不同兼容服务的实际支持情况需自行验证。

模型只能生成文本建议，不能直接调用相机。客户端对结构、数字、置信度、模式、参数版本及相机实际可用档位进行校验；低置信度、未知或未读回的建议只能显示，不能应用。当读回 `0xD120` 明确为闪光灯关闭时可应用 AI 快门建议；开启时仅允许应用不快于 `1/250s` 的同步快门建议；状态未知时快门建议仍只读，用户可自行手动调整。逐项确认后仍通过普通参数写入与读回流程。未配置服务或没有网络时不提供本地画面分析。

## 姿势参考与 JPEG 编辑

姿势目录含 12 组手工定义的单人 14 点轮廓示意（可在 `poseReferences` 叠加和本机匹配）与纯真人照片参考（`photoPoseReferences` 仅作浏览借鉴，不提供未校验骨架叠加），可按场景、全身/半身构图及风格筛选；每组包含动作提示、机位、等效焦段和常见问题。可在实时取景中居中叠加轮廓、镜像并调整透明度。可手动开启本机 Vision 二维人体关键点检测，结果以青色线条叠加取景画面，并与参考示意比较可见肘、膝角度和肢体相对躯干的方向；白色线条为参考。模式默认关闭，不识别人脸或身份，不存储或上传关键点。多人、人物太小、关键点不足和过期帧不会给出完整匹配结论。轮廓和姿势选择只保存在当前应用会话中。

照片编辑仅接受本应用 `Documents/Captures` 内的 JPEG，拒绝指向目录外的符号链接、超大文件和无效图片，支持曝光、对比度、饱和度、冷暖、高光与阴影非破坏性调整（高光还原使用 `CIHighlightShadowAdjust`，提亮使用高光肩部曲线）。调整记录按照片单独存放在 `Documents/EditRecipes`；保存记录或导出不会改写原片。预览最长边为 1280 像素，导出为独立的全尺寸 sRGB JPEG；先生成临时文件再移动到唯一导出路径。默认不保留任何原始 EXIF/GPS；仅当用户显式开启「保留拍摄参数 EXIF」且仅在最终导出路径下，白名单提取快门、光圈、ISO、焦距、镜头型号、机身制造商与拍摄时间写入输出 JPEG，仍严格剔除 GPS、机身/镜头序列号与方向标记（预览与 AI 上传强制剥离元数据）。每次编辑会话提供最多 30 步撤销，已保存的最后一份调整记录可在下次打开时恢复；历史步骤不跨会话保存。

一键自动优化依据平均亮度生成有限范围的曝光调整，属于本地规则而非 AI 场景识别。可选 AI 照片分析使用当前调整的 1024 像素预览、强制移除原始 EXIF/GPS，先征得用户确认，再使用其配置的模型服务；返回文字分析及可选调色参数；只接受完整、数值合法且处于范围内的参数（兼容四参数或带高光/阴影配方）。置信度不足或调整版本发生变化时不能应用，用户确认后才更新预览，且可撤销；不会自动保存或导出。预览请求合并为当前请求与最新请求，原生处理串行化，降低快速拖动时的内存占用。对比使用同一处理管线的默认参数，不会替换原片。

姿态检测通过 `VNDetectHumanBodyPoseRequest` 对当前 JPEG 的最长边 960 像素缩略图执行（读取图片 `kCGImagePropertyOrientation` 传入 Vision 处理器；取景纹理解码时也应用该方向，确保关键点与预览一致）；每秒最多提交一帧且最多一帧在处理，不阻塞 PTP 取景队列。只保留置信度至少 0.35 的身体关键点，Vision 的左下角坐标转换为取景画面的左上角坐标。停止取景、断线、切后台和移除参考时关闭或清除状态；暂停帧时作废旧请求，迟到结果通过代次检查丢弃，2.5 秒内无新结果则清除关键点。

匹配按画面左右对齐，比较相对躯干方向和肘、膝关节角度，并按半身/全身要求检查可见性。其阈值是未经真实人物校准的启发式规则，不是人体姿态识别准确率或评分；不能判断身体深度、手指、表情、摄影效果或人物身份。侧身、交叉、遮挡、暗光、多人以及实际取景方向可能导致识别失败或提示不准确。只在用户开启后分析，用户可随时关闭；最后一个已提交的识别请求可能运行至返回，其结果会被丢弃。

已导出的 JPEG 可由用户主动保存到系统相册，仅请求添加照片权限；保存的是上次导出版本，原片与导出文件均保留。暂不提供 CR3 下载、多人姿态匹配、自动人像分割或 RAW 精修。相机通信、真实人物识别、性能与真实模型服务仍待真机验收。

## 主要来源

- [Apple ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore)：公开框架与外接相机权限。
- [Flutter iOS UIScene 生命周期](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate)：implicit engine 注册通道。
- [R10 能力转储](https://github.com/gphoto/libgphoto2/blob/c4cd525d7461c26b89b4705dc74fc4b84d57ff3a/camlibs/ptp2/cameras/canon-eos-r10.txt)：操作码、EVF 与存储目标属性。
- [EOS 操作实现](https://github.com/gphoto/libgphoto2/blob/c4cd525d7461c26b89b4705dc74fc4b84d57ff3a/camlibs/ptp2/ptp.c#L5010-L5026)：取景命令。
- [上游取景流程](https://github.com/gphoto/libgphoto2/blob/c4cd525d7461c26b89b4705dc74fc4b84d57ff3a/camlibs/ptp2/library.c#L3707-L3815)：属性和分段格式。
- [EOS 初始化与退出](https://github.com/gphoto/libgphoto2/blob/c4cd525d7461c26b89b4705dc74fc4b84d57ff3a/camlibs/ptp2/config.c#L373-L604)：远程模式与清理顺序。

- [OpenAI Chat Completions 图像输入格式](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)：本项目使用兼容请求格式，具体提供商需自行验证。
- [EOS 属性事件与可用档位解析](https://github.com/gphoto/libgphoto2/blob/c4cd525d7461c26b89b4705dc74fc4b84d57ff3a/camlibs/ptp2/ptp-pack.c#L2065-L2145)。

- [Apple Vision 人体姿态检测](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images)：关键点置信度与归一化坐标。
