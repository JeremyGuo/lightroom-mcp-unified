# 实机问题复现与修复验收：2026-09-20

本报告接续首轮 `LIVE_TEST_2026-09-20.md`。测试平台仍为 macOS 26.4、Apple M5 Pro、Lightroom Classic 15.5.1；均通过真实 MCP 客户端调用本机 Lightroom。本次修复尚未发布版本，已同步本机安装。用户当前需求为单张照片处理，后续不再推进批量功能或批量回滚。

## 首轮遗留问题

| 问题 | 原因与修复 | 实机证据 |
| --- | --- | --- |
| 热重载后无响应 / token mismatch | 缺少 `LrShutdownPlugin`。Lightroom 为新实例创建 Lua 环境时，旧后台任务仍可继续运行；新环境的 `_G` 无法停止旧环境。补上卸载、禁用回调及启用入口，通知旧任务退出，随后由上下文清理释放连接 | 运行中重载后，日志明确出现 `Server loop exiting`、`Server task context cleanup`，然后新实例绑定端口。多次重载后 MCP ping 正常 |
| 从 Develop 启动时未自动加载 | 15.5.1 在本机仅有 `LrLibraryMenuItems` 时不会于 Develop 启动阶段加载插件。新增 `LrExportMenuItems` 文件菜单入口，保留 `LrForceInitPlugin` | 对照实验保留所有生命周期修复，只删除文件菜单入口：重启后 ping 未连接、无初始化日志；恢复入口再重启：无需打开管理器或按 Start，ping 成功。此结论限定当前平台与启动模块 |
| Lens Blur 回读失败 | `LensBlurActive` 实际为布尔值，原代码错误使用数字 0/1；Lua 中 0 为真。关闭时控制器还可能返回 nil。改为 true/false，并仅在目录 `LensBlur.Active` 明确未开启时接受 nil 作为关闭状态 | JPEG 开启 35、关闭均成功；NEF 开启 40 + Circle、生成预览、关闭均成功。目录和控制器读回一致 |
| Auto Tone → Reset → Apply 连续调用失败 | 修改照片模块已激活，不等于控制器已就绪。前一操作重建控件期间 `getValue` / `getRange` 可暂时返回 nil；后台 AI 还可能锁定照片 | 等待当前照片可编辑、Exposure 数值与 Contrast 范围有效；写入后允许短暂 nil 再读回。三轮连续 Auto Tone → Reset → Exposure +0.3 / Contrast 9 全部通过，每轮回读值正确，裁剪复位为 0 |
| NEF / DNG、AI Enhance 未验收 | 首轮缺少 RAW 素材。本轮获取 CC0 的原始相机文件并核对公开 SHA-256 | Nikon Z6 NEF、Ricoh GR 原生 DNG 均可导入并预览；两者 AI 降噪完成；NEF Raw Details 与 Super Resolution 可开启/关闭并读回 |

插件管理面板还修复了未指定绑定对象的问题：自动启动复选框从不确定状态恢复为勾选，端口框正常显示 58773 / 58774。

## RAW 与 AI 的具体结果

- **Nikon Z6，14-bit lossless NEF**：30,164,134 字节；原图 6048 × 4024。降噪强度 35，约 7.4 秒后 `denoiseState=true`、`denoiseAmount=35`、`enhanceNeedsUpdate=false` 且照片可编辑。重复开启返回 `state_checked`，没有把降噪关闭。
- **Raw Details**：约 1.5 秒后状态变为 true，再关闭可恢复 false。
- **Super Resolution**：约 5.2 秒后状态为 true；实际导出 JPEG 为 **12096 × 8048**，宽高均为原图两倍。关闭后状态恢复 false。
- **Ricoh GR，原生 DNG**：12,129,815 字节；降噪强度 25，约 4.3 秒后读回已开启、强度 25、无待更新标志；关闭后恢复 false。
- Lightroom 会在降噪或超分辨率开启时自动启用 Raw Details，并限制互斥功能。这是 Lightroom 的正常状态约束，不能把不可点击的组合当成插件缺陷。
- 上述首轮 AI 验收通过后续读取状态确认完成；后续已将这一步收进 `lr_enhance` 的 Lua 实现，默认一次调用等待完成。详见下节。没有要求或宣称生成新的 DNG 文件。

## 对象蒙版与 Lua 内 AI 轮询（追加）

- **对象识别支持**：`createNewMask('aiSelection','objects')` 能打开“选择对象”。本机实测进入该模式后，通过界面指定目标区域，Lightroom 显示“正在检测对象”，生成 `对象 1`（`Mask/Image`）蒙版；`lr_update_mask` 成功写入局部曝光 +0.2。目标粗选使用界面，不是通过 Lua 传入几何坐标；未把这项测试当作分割质量验收。
- Lightroom 的“选择对象”会根据粗略画笔/矩形区域自动识别边缘；“选择主体”则可直接自动寻找主体。“风景”“人物”还能自动识别类别后由界面选择分项。参见 [Adobe 官方蒙版说明](https://helpx.adobe.com/fi/lightroom-classic/desktop/process-and-develop-photos/masking.html)。本插件并非不支持 AI 对象识别，而是当前公开创建接口没有指定对象区域的参数。
- **完成确认已内置**：`lr_enhance` 默认每 0.25 秒在 Lua 中协作轮询，核对所请求的开关和强度、`enhanceIsRunning` / `enhanceNeedsUpdate`、照片编辑锁和控制器可用性；连续两次确认就绪才返回 `completed`。不会在轮询过程中重复 toggle。
- 默认等待 120 秒，允许 `timeout_seconds=1..240`；`wait=false` 保留只提交行为。超时返回 `success=false, status=timeout, completion_verified=false, may_still_be_running=true`，不擅自取消 Lightroom 运算。照片切换会停止轮询，旧运行时不提供可用完成状态时明确返回未确认。
- 单元回归覆盖：开关已开但后台仍忙、长时间未完成、SDK 未应用请求、显式后台提交、选中照片变化、旧运行时状态缺失，以及不合法超时和冲突选项。
- 本机已验证启用、重复启用、关闭降噪及超分辨率均直接返回 `completed`。缓存素材的完成时间约 0.25–0.68 秒；新的 NEF 副本另用于验证未缓存处理及短超时。
- 新 NEF 副本实际触发 1 秒超时，返回未完成，Lightroom 继续运算；后续等待成功确认降噪强度 37，未盲目重复 toggle。
- 追加排查中发现测试探针仍按旧 SDK 的三参数形式传入超时，MCP v2 实际要求第二参数，导致原超时设置被忽略、请求在 60 秒中断；已修正为第二参数，客户端等待设为 330 秒，覆盖服务端 300 秒上限。
- 连续切换旧 `toggleEnhance`、重复调用相同降噪强度时出现过状态反复，未将其误报为完成。现在优先调用本机确实提供的 `setEnhance(feature, boolean, amount)`，旧运行时才回退；相同强度不再调用 `changeDenoiseAmount`。新路径已在本机验证，记录见 `enhance-absolute.log` 和 `enhance-polling-final.log`。此前 15.0 文档审计对 `setEnhance` 不存在的判断不能推广到 15.5.1。
- 记录：`object-mode.log`、`object-recognized.log`、`object-state.log`、`enhance-polling.log`、`enhance-polling-fresh.log`。额外保留一份 NEF 测试副本，测试集合共六张图片。

样本来自 [raw.pixls.us](https://raw.pixls.us/)，按其条目所示 CC0 使用。只用于本机测试，不加入仓库：

| 素材 | 条目 | SHA-256 |
| --- | --- | --- |
| Nikon Z6 NEF | [3582](https://raw.pixls.us/getfile.php/3582/nice/Nikon%20-%20Z%206%20-%2014bit%2014bit%20lossless%20compressed%20(3:2).NEF) | `c079345fc93f53a4f0d322f8ddaae505f920c36015f25b58befccaa61db1af31` |
| Ricoh GR DNG | [996](https://raw.pixls.us/getfile.php/996/nice/Ricoh%20-%20GR%20-%2012bit%20(4:3).DNG) | `7ceec1ea31c56b6e0414202504581b915f17818ffe018b4c8bba1393332c405e` |

## 扩展检查发现并修复

1. **JPEG 批量白平衡**：JPEG 目录字段使用 `IncrementalTemperature` / `IncrementalTint`，同时必须写入 `WhiteBalance='Custom'`；只写数值时 Lightroom 会忽略修改。修复后从 As Shot 开始，两个 JPEG 均成功写入 +7 / +3，逐项读回确认。
2. **RAW/JPEG 混合白平衡**：旧逻辑可能先修改前面的 RAW 才在后面的 JPEG 报错。现在整组选中照片先预检，再开始写入。实测 RAW 温度 3050，请求混合批量 6500 被拒绝，RAW 仍为 3050，JPEG 设置也未变化。
3. **导出 skip 误报错误**：Lightroom 会在开始遍历前剔除已有文件的 rendition。现在结合 `countRenditions` 和 `wasSkipped` 计数；实测返回 `success=true, exported=0, skipped=1`。另已验证 rename 生成新文件、overwrite 覆盖指定测试输出。
4. **失败目标路径**：导出至 `/dev/null/mcp-test` 明确失败并提示无法创建目录，不假报导出成功。自动化另覆盖复制失败、渲染失败等路径；没有用填满磁盘的方法制造真实磁盘满。
5. **测试探针日志**：不再打印原始认证 token。日志只保留脱敏占位符。

## 验证与范围

- 最新回归：220 项 Node 测试、236 项 Lua 测试；类型检查、ESLint 与补丁空白检查。
- 空闲连接：保持同一 MCP 客户端连接并空闲 110 秒，期间心跳工作；跨过 90 秒失联阈值后 ping 仍在 3 ms 内成功，并可继续读取当前设置。此项不等于数小时运行验收。
- 在线热重载：保持同一 Node/MCP 客户端运行，14:24:10 重载插件，旧任务完成清理，14:24:12 新连接建立；14:24:28 原客户端的 ping 和设置读取均成功，无需重启客户端。记录见 `connected-reload.log`。
- 实机记录：`artifacts/live-2026-09-20/` 下的 `fixes-round1.log`、`blur-final.log`、`nef-blur.log`、`nef-denoise.log`、`nef-extended.log`、`dng.log`、`mixed-wb.log`、`edge-final.log`、`repeat-idle.log`。
- 相机样本和测试输出保留在上述忽略目录；本机 Lightroom 测试集合现有三个 JPEG、两张 NEF（一份为测试副本）、一张 DNG。
- Windows 原生 Lightroom 无法在本机验证。数百张压力测试、数小时空闲、所有相机型号、所有蒙版类型及参数组合仍未穷尽，不能由本轮样本推断全部兼容。
- 手动画笔、渐变、人物/对象选择等仍可能需要 Lightroom 内交互；公开 API 无法接收的几何参数仍明确拒绝。这是已知接口边界，不以空操作冒充完成。

参考接口文档：[LrDevelopController](https://lrc.mcor.dev/modules/LrDevelopController.html)、[LrExportRendition](https://lrc.mcor.dev/modules/LrExportRendition.html)、[LrExportSession](https://lrc.mcor.dev/modules/LrExportSession.html)（Adobe 编写的 SDK 文档镜像）。具体布尔/nil 行为及启动差异以上述实机对照为准。
