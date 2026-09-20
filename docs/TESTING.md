# 验证范围

自动化分为三层：TypeScript 单元测试、Lua 5.1 的 SDK mock 测试，以及启动构建后 CLI 的真实 stdio/TCP 集成测试。集成测试使用 MCP v2 客户端和模拟 Lightroom TCP 对端，核对握手、31 个工具、token、截止时间、心跳和 MCP 图片返回；**它不是 Lightroom 的替身验收**。

本次本地验证使用 Node.js 24.19.0 / Lua 5.1.5。准确测试数量和发布校验结果记录在发布说明；CI 的平台结果以对应提交的 Actions 为准。

```sh
npm ci --prefix server
npm run check --prefix server
npm run lint --prefix server
npm test --prefix server -- --runInBand
# 需要 Lua 5.1 + LuaRocks
luarocks --lua-version=5.1 install busted 2.3.0
busted --lua=lua5.1
npm audit --prefix server --omit=dev
```

关键回归涵盖：认证失败/重连/端口占用、单进程锁、失联客户端退出、工具 schema 与 Lua dispatch 对应、MCP v2 连接、真实图片内容类型、预览体积校验、别名冲突、滑块读回不一致、活动照片变化、空选择、蒙版选择与交互状态、无效 Enhance API、导出 rendition 错误、复制冲突、父集合解析与部分失败。

## 真实 Lightroom 验收清单

在副本目录与测试照片上完成以下步骤，并记录 Lightroom 完整版本、操作系统、相机 RAW 类型和 GPU 信息。

| 步骤 | 操作与期望 |
| --- | --- |
| 加载 | 安装插件、重启 Lightroom；插件启动并显示 58773/58774；`lr_ping` 返回真实版本 |
| 能力 | `lr_capabilities` 的 API 状态与真实运行版本一致；缺少功能明确报错 |
| 基础元数据 | 搜索一张 NEF、一张 JPEG；照片 ID、评级和元数据对应正确 |
| 调色与预览 | `lr_get_settings`，使用返回的 `photo_id` 设置 Exposure，再导出预览；核对 UI 值及图片变化 |
| 参数失败 | 未知键、越界值、错误 photo_id 应无写入；已完成部分写入的结果应显示失败和已完成项 |
| 批量 | 选中两张同类照片并应用参数；无选择时报错；RAW/JPEG 混合白平衡必须拒绝不同单位项 |
| 裁剪 | 设置合法矩形与角度后核对；上下界颠倒时应无修改 |
| 蒙版 | 主体/天空自动创建并检查局部调整；手工渐变返回交互状态，完成后 `lr_update_mask`；几何 params 明确拒绝 |
| Enhance | 先查状态，再请求 denoise；观察 Lightroom 完成，重新读状态；相同 enable 请求不能关闭功能 |
| Lens Blur | 适配图像上开启、调整强度与散景；不支持的焦距自动化应在写入前报错 |
| 集合 | 创建父组下的集合；全路径定位；同名歧义报错；缺失 ID 产生部分失败 |
| 导入 | 指定目标目录确认源文件保留、副本被导入；目标冲突在复制前拒绝；集合不存在时不导入 |
| 文件导出 | JPEG/TIFF/原格式；验证质量、尺寸、已存在处理和真实导出数；模拟磁盘失败应报错 |
| 预设 | 列出、读取、比较、创建、导出、应用、复制；检查同名消歧和不覆盖文件策略 |
| 生命周期 | Lightroom 重启、插件重载、长时间空闲、客户端退出再启动；不残留占用端口的桥接 |

2026-09-20 已在 macOS / Lightroom Classic 15.5.1 上完成 JPEG、Nikon NEF、Ricoh DNG 实机测试。历史发现见 [首轮报告](LIVE_TEST_2026-09-20.md)，最新修复、回归与未覆盖范围见 [后续验收报告](LIVE_TEST_FOLLOWUP_2026-09-20.md)。剩余条件满足后再将版本转为稳定发布。
