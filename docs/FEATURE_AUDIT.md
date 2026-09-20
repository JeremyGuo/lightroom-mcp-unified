# 功能审计与 SDK 核对

更新：本页保留 2026-09-18 的历史审计基线。2026-09-20 的真实 Lightroom 验证及修复情况见 [实机验收报告](LIVE_TEST_FOLLOWUP_2026-09-20.md)，包括 NEF/DNG、AI Enhance、启动与热重载等项目。

核查日期：2026-09-18。结论：两个上游的功能宣传不能直接等同于完整可用。本项目包含 Automaat 的 18 个 MCP 工具，以及独立实现的 12 个 `lr_*` 工具，再增加 1 个运行时能力查询工具。对于公开 SDK 不提供的能力，明确拒绝或报告需要交互，不用空操作冒充成功。

## 固定审计来源

| 来源 | 审计基线 | 处理 |
| --- | --- | --- |
| [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp/tree/710dcb022c36c5fd04fef2643115290e2fb11657) | `710dcb022c36c5fd04fef2643115290e2fb11657`，0.15.0 | MIT；保留声明并修改复用 |
| [varunkumar/lightroom-mcp](https://github.com/varunkumar/lightroom-mcp/tree/04f872fd1b6b0f7e2ee16c88121b9f0695fc1ffc) | `04f872fd1b6b0f7e2ee16c88121b9f0695fc1ffc` | 未发现许可证；仅核对接口与宣传，不复制代码或文档 |
| [MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk) | 官方 v2 稳定版；npm `server` / `client` 均为 2.0.0 | 精确固定版本；执行真实客户端握手和工具调用测试 |
| [Adobe Lightroom Classic 开发入口](https://developer.adobe.com/lightroom-classic/) | 下载跳转要求 Adobe Developer 登录 | 无法验证登录后的最新 SDK 下载版本 |
| [Adobe 编写的 SDK 15 API 文档镜像](https://github.com/manuzzi-photo/LightroomClassicSplitImagePlugin/tree/9a108ae8a23ac11f8448f51c708e30fc6f0bc7b4/AdobeDocs/LrC_15/API%20Reference) | 固定镜像提交 `9a108ae8…` | 核对 API 签名与限制；没有重新分发 Adobe 文档；该镜像不是最新版认证渠道 |

Automaat 使用旧的统一包 `@modelcontextprotocol/sdk` ^1.29.0，审计时它的 v1 维护线最新为 1.30.0；本项目采用稳定 v2 拆分包，迁移了 stdio 导入、协议类型和 `setRequestHandler` 的方法名注册方式。没有继续保留 varunkumar 的 Python MCP 服务，因此不再需要维护它宽泛的 `mcp>=1.0.0` 依赖。

Adobe SDK 并非 Node 依赖，运行 API 由用户安装的 Lightroom 提供。`LrSdkVersion=15.0` 是开发目标声明，`LrSdkMinimumVersion=8.0` 是加载下限，**都不是所有新 API 可用的保证**。Enhance 的三个方法从 SDK 14.5 提供；镜头散景方法从 13.3 提供；运行时继续检查方法是否存在及图像是否允许操作。

## 逐项工具覆盖

A = 从 MIT 上游移植并修正；V = 对另一项目接口独立实现；N = 新增。下表的“实现”不代表通过 Lightroom 实机验收。

| 工具 | 来源 | 已实现行为及边界 |
| --- | --- | --- |
| `search_photos` | A | 文件名、关键词、评级和日期查询；分页 |
| `get_selected_photos` | A | 读取选择；无明确选择时可能返回胶片带，保留上游语义 |
| `get_photo_metadata` | A | 原始/格式化照片元数据和开发设置；字段仍受照片类型影响 |
| `list_collections` | A | 遍历嵌套集合并给出路径；不单独输出空集合组节点 |
| `create_collection` | A | 创建集合；已修复原实现忽略 `parent`；要求已有父集合组 |
| `add_to_collection` | A | 全路径或唯一名称定位；缺失照片为部分失败；歧义名称拒绝 |
| `set_keywords` | A | 添加/删除关键词；未找到全部照片时 `success=false` |
| `set_rating` | A | 0–5 星，0 清除；缺失照片为部分失败 |
| `import_photos` | A | 单文件/递归目录；修复被忽略的目标复制目录、缺失集合与失败计数；复制为平铺文件名，冲突拒绝 |
| `export_photos` | A | JPEG/TIFF/原格式；质量单位已修正；等待真实 rendition 结果；PNG 明确不支持 |
| `list_develop_presets` | A | Lightroom 可见预设及插件管理的检查点 |
| `get_develop_preset` | A | 精确预设选择及设置读取；同名需消歧 |
| `compare_develop_presets` | A | 两个预设的设置差异；不是图像相似度比较 |
| `create_develop_preset` | A | 指定设置键、创建不覆盖同名的检查点 |
| `export_develop_preset` | A | 复制存在的预设文件，不覆盖目标；无法访问 backing file 时报错 |
| `apply_develop_preset` | A | 应用精确预设到指定照片；缺失照片为部分失败 |
| `copy_develop_settings` | A | 复制全部或白名单设置；不会复制不存在的源设置值；缺失目标为部分失败 |
| `set_develop_settings` | A | 按已有白名单写目录设置；不是任意 Lightroom 内部参数通道；SDK 接受不等于所有组合视觉一致 |
| `lr_ping` | V | 认证连接与 Lightroom/插件版本 |
| `lr_get_settings` | V | 当前照片设置、有效滑块/范围及可用 Enhance 状态 |
| `lr_apply_settings` | V | 大小写不敏感别名、绝对值、动态范围校验、写后回读与部分失败 |
| `lr_batch_apply_settings` | V | 明确选中最多 1000 张；转换 UI 与目录参数名；白平衡单位冲突拒绝 |
| `lr_auto_tone` | V | 调用当前照片的 Auto Tone API |
| `lr_reset` | V | 重置当前照片的全部开发调整 |
| `lr_export_preview` | V | Lightroom 当前编辑渲染为 sRGB JPEG；返回 MCP 图片；限制尺寸/字节数并清理临时文件 |
| `lr_crop` | V | 归一化边界、角度和最终矩形校验；写入 `HasCrop` |
| `lr_add_mask` | V | SDK 蒙版类型；仅新选中的自动蒙版写局部值；交互型返回需用户完成；不支持几何参数 |
| `lr_update_mask` | V | 校验有已选蒙版，再写文档化的局部滑块并回读 |
| `lr_lens_blur` | V | 启用、强度、散景、猫眼、高光；不支持主体自动焦距范围；不保证 AI 计算完成 |
| `lr_enhance` | V | 检查状态后调用文档化 API；一次变更一个选项；请求提交与计算完成明确区分 |
| `lr_capabilities` | N | Lightroom 版本、API 是否存在、可识别滑块名称、已知限制 |

## 发现并修复的问题

1. **不存在的 Enhance 调用**：另一个上游使用 `setEnhance`。核对 SDK 15 文档后改为 `toggleEnhance(paramName, denoiseAmount, ...)`、`getEnhancePanelState()`、`changeDenoiseAmount()`；不盲目 toggle、不吞异常。
2. **蒙版几何被忽略**：公开 `createNewMask(maskType, maskSubtype)` 只有两个类型参数，不能据此设置渐变起终点或径向椭圆。非空 `params` 会在修改前被拒绝。
3. **局部参数不等于全局参数**：建立文档化局部名称表；Moire 对应 `local_Moire`；没有把全局 Vibrance/ColorNoiseReduction 当作可写局部滑块。
4. **UI 与目录键不同**：批量目录写入把 Exposure、Contrast、Highlights 等映射到相应 `*2012` 名称。白平衡范围由当前图片 SDK 返回，避免固定 Kelvin 范围误用于 JPEG。
5. **虚假的“预览”**：返回实际 base64 JPEG 的 MCP `image`，不把本机文件路径当作远端客户端可见的图片，也不让服务端读取任意路径来拼装预览。
6. **导出计数和单位错误**：JPEG 质量转换为 0–1；等待 `waitForRender` 的逐张结果；不按请求照片数假报导出成功；仅保留已文档化的三种既有格式。
7. **被忽略的导入与父集合参数**：实现复制目标与父集合选择。复制冲突预检、目标集合预检、逐张结果、歧义名称报错。
8. **部分错误未传播到 MCP**：结果 `success=false` 变成 `isError=true`，仍保留已完成项和失败明细。目录批量调用仍可能已经产生部分效果，不是可回滚事务。
9. **共享 UI 的并发写入**：插件串行执行普通请求，心跳独立响应；开始执行前检查排队请求的截止时间。已经开始的 Lightroom 调用不会因 MCP 客户端超时而自动撤销，超时后先读状态再决定是否重试。
10. **认证和体积限制**：不记录原始无效 JSON 以免泄露 token；限制响应行长度与 JPEG 字节数；POSIX token 限权；独立工具包标识、端口、token 和状态目录。

## 尚未证实 / 明确不承诺

- 没有 Adobe 登录，不能证实最新可下载 SDK 的准确版本。
- 没有在真实 Lightroom、真实 GPU 或 NEF 文件上执行测试；自动化通过只证明代码、协议与模拟 SDK 分支。
- 自动蒙版“已选中”不等于图像分割计算完成；Enhance “submitted”不等于处理完成；不会承诺生成新 DNG。
- 不支持公开 SDK 未暴露的自动几何蒙版与主体焦距范围接口；也没有尝试 UI 点击脚本作为隐藏替代。
- 目录导入的递归扩展名过滤沿用 JPEG/PNG/TIFF/DNG/CR2/NEF/ARW 集合；其他 Lightroom 支持的类型可尝试单文件导入，但未被宣称完整覆盖所有相机格式。
- 使用 Lightroom 原生撤销/历史管理恢复编辑；没有自建跨文件、跨照片事务回滚。发布包未签名或公证。
