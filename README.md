# Lightroom MCP Unified

在一个 MCP 服务中整合 Lightroom Classic 的目录管理、预设、全局调色、局部蒙版、裁剪、预览和 AI Enhance：**31 个工具，Node.js + Lua，无需 Python 服务**。

最新发布包仍为 **0.1.0，预发布**；`main` 已包含后续修复，使用这些修复请从源码构建。已在 macOS / Lightroom Classic 15.5.1 上验证 JPEG、Nikon Z6 NEF 和原生 DNG，修复热重载、自动启动、镜头模糊、连续操作时序及批量白平衡等问题；RAW 降噪、Raw Details 和超分辨率也已实测。详情见 [问题修复与验收](docs/LIVE_TEST_FOLLOWUP_2026-09-20.md)。**Windows 与全部相机型号尚未实机验收**；接口存在不代表所有照片、显卡和版本都支持对应效果，先运行 `lr_capabilities`。

## 安装

需要 Node.js 22 或更新版本，以及 macOS/Windows 上的 Lightroom Classic。新开发功能以 Adobe SDK 15.0 文档为目标；Enhance 所用 API 首次出现在 14.5。旧版本仅支持其实际提供的功能。**不支持 Lightroom 云端版、网页版或移动版。**

### 方式一：下载发布包

从 [Releases](https://github.com/JeremyGuo/lightroom-mcp-unified/releases) 下载：

- `lightroom-mcp-unified.mcpb`：供支持 MCPB 的桌面客户端安装，内含运行依赖与 Lua 插件。
- `lightroom-mcp-unified-0.1.0.zip`：通用运行包，解压后直接使用 `server/dist/index.js`；已内含生产依赖。
- `LightroomMCPUnified-0.1.0.lrplugin.zip`：单独的 Lightroom 插件。
- `SHA256SUMS`：核对下载完整性。发布包没有开发者代码签名，SHA-256 不等于签名证书。

使用通用运行包时，在解压目录运行：

```sh
node server/dist/index.js install-plugin
```

重启 Lightroom Classic，在「文件 → 增效工具管理器 / Plug-in Manager」确认 **Lightroom MCP Unified** 已启用、服务器已启动。也可以在管理器中手动添加解压得到的 `LightroomMCPUnified.lrplugin` 文件夹。工具名称因 Lightroom 语言设置而异。

### 方式二：从源码构建

```sh
gh repo clone JeremyGuo/lightroom-mcp-unified
cd lightroom-mcp-unified
npm ci --prefix server
npm run build --prefix server
node server/dist/index.js install-plugin
```

源码与发布包在本仓库提供；建议从源码构建使用最新修复。插件安装器不会覆盖已安装版本；升级时先停止桥接，再在 Lightroom 管理器中移除旧插件并添加新目录。

### MCP 客户端配置

将下面路径换成你电脑上的**绝对路径**。客户端若要求 Node 可执行文件的绝对路径，也需要相应替换 `node`。

```json
{
  "mcpServers": {
    "lightroom-unified": {
      "command": "node",
      "args": ["/absolute/path/lightroom-mcp-unified/server/dist/index.js"]
    }
  }
}
```

Windows 路径示例：`C:/Tools/lightroom-mcp-unified/server/dist/index.js`。MCPB 安装方式由客户端生成配置。首次启动会尝试把插件复制到 Lightroom Modules 目录，之后仍需重启 Lightroom。

连接检查顺序：`lr_ping` → `lr_capabilities` → 选中一张照片 → `lr_get_settings` → `lr_export_preview`。单个 Lightroom 插件只连接一个桥接进程；多个客户端同时启动同一端口的桥接会被拒绝。

## 功能与实际边界

| 范围 | 工具 |
| --- | --- |
| 目录、元数据、选择 | `search_photos`、`get_selected_photos`、`get_photo_metadata` |
| 集合与整理 | `list_collections`、`create_collection`、`add_to_collection`、`set_keywords`、`set_rating` |
| 文件导入导出 | `import_photos`、`export_photos` |
| 预设与目录开发设置 | `list_develop_presets`、`get_develop_preset`、`compare_develop_presets`、`create_develop_preset`、`export_develop_preset`、`apply_develop_preset`、`copy_develop_settings`、`set_develop_settings` |
| 状态与开发滑块 | `lr_ping`、`lr_capabilities`、`lr_get_settings`、`lr_apply_settings`、`lr_batch_apply_settings`、`lr_auto_tone`、`lr_reset` |
| 预览、裁剪、局部与 AI | `lr_export_preview`、`lr_crop`、`lr_add_mask`、`lr_update_mask`、`lr_lens_blur`、`lr_enhance` |

- `lr_apply_settings` 接受绝对值，按当前照片的 SDK 范围预检，并读取修改后的值。`photo_id` 是防止选错照片的校验，不会切换照片。批量修改只使用明确选中的照片；白平衡切换为 Custom，JPEG 使用增量字段，RAW/JPEG 单位冲突在任何修改前整组拒绝。
- 预览由 Lightroom 渲染当前编辑结果，返回真正的 MCP `image` 内容；最长边 64–2048 像素，JPEG 上限 8 MiB，临时文件随后清理。NEF 解码由 Lightroom 完成，未在本环境验证特定相机文件。
- 蒙版的画笔、渐变、范围、人物和对象等可能需要你在 Lightroom 中完成交互。公开 SDK 的 `createNewMask` 没有几何参数；本项目明确拒绝这类参数。只有新蒙版被确认选中后，才会写局部调整。
- AI Enhance 优先使用运行时提供的绝对设置接口 `setEnhance`，旧版回退到 `toggleEnhance`；相同状态和降噪强度不会重复提交。默认在 Lua 内协作轮询请求值、处理状态和照片编辑锁，确认完成后返回 `status=completed` / `completion_verified=true`。默认等待 120 秒，可用 `timeout_seconds` 设置 1–240 秒；超时明确返回 `timeout`，处理可能仍在后台继续。`wait=false` 可仅提交。旧运行时缺少可靠处理状态时不宣称完成，也不宣称生成了新 DNG。普通降噪滑块不是 AI Denoise。
- Lens Blur 支持运行时提供的滑块和散景类型；`focalRangeFromSubject=true` 因 SDK 15 文档无对应 API 而明确报错。
- 文件导出支持 JPEG、TIFF、原格式，自动创建目标目录，主动跳过的已有文件以 `skipped` 单独计数。PNG 导出未列入核对的 Lightroom SDK 导出格式，已移除。JPEG 质量的 0–100 输入会转换为 SDK 的 0–1。
- 导入指定 `copy_to` 时先复制、再导入副本，源文件保留。目标采用平铺文件名；同名冲突在复制前拒绝。部分失败会列出已完成项，**批量操作不是原子事务**，已复制文件不会自动回滚删除。
- 集合可使用完整路径，例如 `旅行 / 日本`；有歧义的叶名称会报错。创建集合支持已有父集合组。
- `get_selected_photos` 保留上游“未选择时返回胶片带”的语义；新批量调色工具会另行要求明确选择。`lr_reset` 会重置当前照片的全部开发调整。

完整逐项核查见 [功能审计](docs/FEATURE_AUDIT.md)，真实 Lightroom 验收步骤见 [测试说明](docs/TESTING.md)。

## SDK、来源与许可

截至 **2026-09-18**，从 npm registry 核对并固定到最新稳定 MCP TypeScript **v2**：`@modelcontextprotocol/server@2.0.0`，测试客户端 `@modelcontextprotocol/client@2.0.0`。已迁移导入路径与请求注册接口，不只是改版本号。

Adobe SDK 分开处理：插件首选版本声明为 **15.0**，对应 API 已核对 Adobe 编写的 SDK 15 参考文档。Adobe 当前下载入口要求登录，**无法独立确认其可下载 SDK 是否仍以 15.0 为最新**；本项目不把该声明当成最新版证明。

基于 [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp) 的 MIT 代码保留目录管理与桥接功能；[varunkumar/lightroom-mcp](https://github.com/varunkumar/lightroom-mcp) 在核查提交中没有许可证，因此没有复制其代码或文档，相关 12 个工具按 Adobe API 独立实现，并增加 `lr_capabilities`。参见 [NOTICE](NOTICE.md) 与 [MIT LICENSE](LICENSE)。

## 连接与凭据

默认端口为 **58773 / 58774**，与上游项目隔离。Lua 插件生成本地随机 token，桥接每条请求携带认证。默认 token：`~/.config/lightroom-mcp-unified/token`；POSIX 下桥接将默认目录设为 700、token 设为 600，并拒绝 token 符号链接。Windows 使用用户目录 ACL。

桥接仅连接 `127.0.0.1`；这段本机连接不使用 TLS，不能据此视为远程安全传输或开放到公网。GitHub 和依赖下载保留 HTTPS 证书验证，没有使用 `--insecure` 或关闭 TLS 验证。GitHub 凭据、私钥与证书私钥不会进入仓库或安装包。

| 环境变量 | 默认值 / 含义 |
| --- | --- |
| `LIGHTROOM_MCP_REQUEST_PORT` | `58773`，需要与 Lightroom 插件设置一致 |
| `LIGHTROOM_MCP_RESPONSE_PORT` | `58774`，需要与 Lightroom 插件设置一致 |
| `LIGHTROOM_MCP_TOKEN_PATH` | 覆盖桥接读取的 token 路径；插件仍写默认位置 |
| `LIGHTROOM_MCP_STATE_DIR` | 覆盖桥接实例锁目录；通常不用设置 |
| `LIGHTROOM_MCP_SKIP_PLUGIN_INSTALL=1` | 禁用启动时自动复制插件 |

## 开发与打包

```sh
npm ci --prefix server
npm run check --prefix server
npm run lint --prefix server
npm test --prefix server -- --runInBand
# Lua 5.1 + LuaRocks；先安装 Busted 2.3.0
busted
node scripts/build-mcpb.mjs
python3 scripts/package-release.py
```

构建产物位于 `build/`。CI 在 Linux、macOS、Windows 检查 Node 桥接，在 Lua 5.1 下测试插件逻辑。SDK mock 测试不会被当作 Lightroom 实机验证。
