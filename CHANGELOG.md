# 变更日志

本文件记录 CodeOutline 的主要变更。尚未发布安装包，当前版本为 `0.1.0-dev.0`。

## 未发布

### 新增

- 按需识别源码编码：查询涉及的文件依次确认 UTF-8、带 BOM 的 UTF-8 和 GBK，GBK 文件经 `xutils.to_utf8` 严格转码后重新解析并重建调用图，编码结果随索引缓存保存。首次索引不额外检查编码。
- `doctor` 检查运行时是否提供 `xutils.to_utf8`。

### 修复

- 从缓存加载且源码未变化时，不再重写整个缓存文件。只有文件被解析、删除或编码结果更新时才保存；保存失败会在下次调用时重试。大型项目带缓存重启约快 0.3 秒，多进程共享缓存时也不再用未改动的快照覆盖他人的更新。

### 依赖

- xnet2lua 更新至 `8aac7a2`，新增 `xutils.to_utf8`：Windows 使用代码页 936，Linux/macOS 使用 iconv，iOS 使用 CoreFoundation，Android 使用 JNI CharsetDecoder（宿主需调用一次 `xutils_android_init`）。

## 2026-09-27

### 新增

- 统一 CLI：`serve`、`explore`、`status`、`rebuild`、`doctor`、`--help`、`--version`。
- 跨平台分发预览：npm 平台启动薄层（`launcher/`）、`tools/package.lua` 打包、`tools/build-runtime.ps1` 静态 CRT 构建、CI 工作流与第三方许可证。
- Lua 实现的 MCP 服务（协议基线 2025-06-18），支持 stdio 与 Streamable HTTP，提供 `codeoutline_explore`、`codeoutline_status`、`codeoutline_rebuild`；常驻索引线程、取消与进度报告、会话与任务上限、远程访问令牌与 Host/Origin 校验。
- 索引稳定性：路径规范化、原子替换缓存与完整性校验、损坏缓存自动重建、枚举失败时保留已缓存记录。
- 官方 MCP SDK 互操作测试与 Codua 客户端互操作测试。

## 2026-09-26

### 新增

- 从 Codua `scripts/xagent/codeindex/` 提取独立索引核心：符号查询、带行号源码、跨文件调用关系、增量刷新和磁盘缓存。
- 支持 Lua、C、C++、C#、Go、Java、JavaScript/TypeScript、Python、Rust 解析；原生 xscan 扫描器与纯 Lua 回退。
- xagent `CodeExplore` 工具适配器。
