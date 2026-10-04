# LuaLS 3.19.1 实现笔记与 CodeOutline 借鉴方案

记录日期：2026-10-04。研究对象是本机安装的 `sumneko.lua-3.19.1-win32-x64` 扩展，扩展清单版本为 `3.19.1`，服务端 changelog 同样包含 `3.19.1`。本文依据安装包内实际源码编写，未用网络最新版替代该版本。

目的：卸载扩展后，仍能理解其主要工程机制、找到对应模块，并据此规划 CodeOutline。正文保存机制、流程、限制与迁移建议；附录保存协议入口、配置清单、关键源码摘录和文件校验清单。源码定位统一相对于扩展根目录，不依赖已经删除的本机绝对路径。

范围：覆盖客户端、协议、调度、文件与工作区、解析和语义、编辑功能、配置、库与插件、诊断、可观测性、CLI、调试与发布布局。本文不是逐行解释所有类型推导和诊断规则，也不是整个扩展的可运行源码备份。安装包未提供的原生运行时实现、上游测试和构建流程没有被验证。功能入口存在不等于所有分支都已运行验证。

CodeOutline 对照基线：本次工作区，HEAD `60ca82f`，含已有未提交改动；不应把该提交号当成完整工作区快照。本次仅新增研究文档，不调整实现。

## 阅读路线

- 优先考虑落地：第 4、5、7、9、12、21、23 节。
- 理解 LuaLS 的语义能力：第 10～16 节。
- 查询某个功能：附录 A 协议入口、附录 B 配置快照。
- 卸载后查看关键实现：附录 C 摘录；确认版本和文件身份：附录 D。

## 1. 总体结构与职责

```text
VS Code 扩展客户端（vscode-languageclient）
    │ stdio / 配置为 socket 时使用 socket
    ▼
JSON-RPC 收发 → proto 请求登记与协程执行 → provider 协议适配
                                              │
                     ┌────────────────────────┼──────────────────┐
                     ▼                        ▼                  ▼
                 core 功能层             files / workspace     config
                     │                        │                  │
                     ▼                        ▼                  │
               vm 语义分析 ←──────── parser AST + LuaDoc ←───────┘

service 事件循环：网络、timer、pub 线程结果、await 协程
pub / brave：后台任务队列、独立线程与 channel、文件读取和解析等任务
```

| 层 | 主要模块 | 职责 |
| --- | --- | --- |
| 编辑器桥接 | `client/out/src/languageserver.js` | 启动进程、LSP 客户端、命令、状态栏、自定义通知 |
| 启动与循环 | `server/main.lua`、`script/service/` | 参数、日志、运行时初始化、事件循环 |
| 通信 | `script/jsonrpc.lua`、`script/proto/` | 消息编解码、请求与响应、协议坐标转换 |
| 请求适配 | `script/provider/` | 能力声明、参数转换、调用功能层、编码结果 |
| 调度 | `script/await.lua`、`script/pub/`、`script/brave/` | 协程让出、任务生命周期、后台线程 |
| 文档与工程 | `script/files.lua`、`script/workspace/` | 文本、缓存、作用域、加载与监听 |
| 语言理解 | `script/parser/`、`script/vm/` | AST、注释类型、变量绑定、字段、泛型与推断 |
| 编辑功能 | `script/core/` | 跳转、引用、补全、重命名、诊断等 |
| 扩展生态 | `script/library.lua`、`script/plugin.lua`、`meta/template/` | 标准库声明、第三方库、转换插件 |

这里的 `vm` 是静态语义分析层，不能理解成执行用户程序的虚拟机。它提供的类型和关系事实被多个编辑功能共享。

**借鉴**：CodeOutline 已有 Lua 服务、协议适配与功能模块，不需要照目录结构重写；更值得保持“协议层不含语言推断、语言事实由多个功能共享”的边界。

## 2. 启动、运行时与事件循环

定位：`server/main.lua`；`server/script/service/service.lua:m.start/eventLoop`。

启动脚本解析命令行，将参数转换成布尔值、数字或字符串，设置根路径、日志路径、meta 路径；初始化日志与 Tracy，尝试开发调试入口，处理 CLI，再启动服务。部分 GC 设置依赖其打包运行时，不能假定标准 Lua 或 xnet 支持同样 API。

服务启动创建 4 个公共后台线程；只有 `COMPILECORES > 0` 时才另建 `compile` 专用线程组。传输按配置选择 stdio 或 socket。主循环推进网络、timer、线程结果和协程；空闲时使用等待机制，避免持续忙轮询。

**借鉴**：启动逻辑与业务解耦；空闲等待与工作状态可观测。不要直接抄线程数或 GC 参数。CodeOutline 应沿用 xnet 的事件循环和线程 API。

## 3. LSP 注册、能力协商与客户端

定位：`provider/provider.lua:m.register`、`provider/capability.lua:m.getProvider`；客户端 `languageserver.js:LuaClient.start`。

每个方法以注册表描述 handler、capability 和其他属性；能力集中合并。标记 `preview` 的方法在未开启 `PREVIEW` 时不会注册。补全按客户端动态注册能力选择注册方式；不能仅凭 handler 源码判断默认启用状态。

客户端使用 `vscode-languageclient/node`。可指定服务端可执行文件和额外参数；默认选择打包平台二进制。初始化选项声明状态栏、文档展示、语言配置、范围语义着色等客户端扩展能力。还注册启动/停止服务、导出文档、FFI meta 刷新和引用展示等命令。

该客户端有自定义 hover 展示路径：通用 middleware 禁用默认 hover 后再注册自己的处理，不能只看 middleware 就判断 hover 被取消。

**借鉴**：CodeOutline 编辑器客户端保持轻量，只负责发现/连接服务和平台 UI。能力声明必须和实际可用 handler 对齐，自定义通知应有能力开关和标准协议回退。

## 4. 协议请求生命周期与取消

定位：`proto/proto.lua:applyMethod/applyMethodQueue/close`；`provider/provider.lua:$/cancelRequest`。

请求进入 `holdon` 表，handler 在协程中运行，并用 `proto:<id>` 标识。作用域退出时统一发送成功或错误响应，记录慢请求并释放协程关联。客户端取消通过 `proto.close` 记录取消原因，再关闭关联协程。

同一批待分派消息会先扫描取消通知，避免执行本批已经取消的请求。但“跳过执行”不应直接作为 CodeOutline 的协议实现模板：仍必须保证被取消请求恰好收到一次正确响应。

**重要现状**：文件变化回调会查看 `abortByFileUpdate`，但真正的 `proto.close(...ContentModified...)` 调用被注释。该版本不能被描述为已经全面自动取消过期请求。

**CodeOutline 建议**：保留当前 `-32800` 取消响应与晚到结果丢弃；新增按文档版本判定结果是否仍有效。区分客户端主动取消、内容已变、超时和内部错误，避免全部降为 InternalError。取消任务和同步草稿是不同生命周期，不能一并丢弃。

## 5. 协程调度、后台线程与任务合并

定位：`await.lua`；`pub/pub.lua:recruitBraves/pushTask/popTask`；`brave/work.lua`；`provider/diagnostic.lua:refresh`。

LuaLS 同时采用两种机制：

1. 主 Lua 状态内的协作式协程。`await.delay()` 入恢复队列并 yield；长遍历显式让出。`newThrottledDelayer` 每若干次调用才让出，降低调度开销。
2. 后台线程。每个 worker 使用独立任务/回复 channel；公共组与按任务名匹配的专用组分别排队。空闲线程接受任务，回复后继续取队列中的任务。stdio 读取、文件读取、解析等有各自任务入口。

按 ID 的 `close/setID/unique` 用于生命周期管理。诊断刷新先关闭 `diag:<uri>`，新任务等待约 0.1 秒再执行；工作区重载也使用唯一任务和延迟，合并重复触发。

**不要误读**：补全中的 `await.setPriority(1000)` 是注释；`await.setPriority` 的实现将当前协程标为不在 `delay` 中让出，并不是成熟的多级公平优先队列。后台取消也不能被推断为强制终止原生线程计算。

**CodeOutline 建议**：先测队列等待。待执行队列可以优先交互请求；后台索引拆为可恢复批次后，才能在安全点穿插查询。已有单文件原子提交有帮助，但跨文件查询一致性、任务游标与缓存失效仍需设计。按 `(session, uri, method)` 合并过期交互任务；后台刷新合并路径集合，同时保证公平性。

## 6. 文件状态、文本来源和生命周期

定位：`files.lua:reset/open/close/setText/removeState/remove/addRef/delRef`。

核心状态包含 `fileMap`、`openMap`、弱值 `stateMap`、`globalVersion`。文件保存原始文本与转换后文本、版本、行缓存、词缓存、解析次数和派生缓存。编辑器传来的可信文本优先于后台磁盘读取，避免未保存修改被覆盖。这里的 trusted 首先表示文本来源优先级，不应与插件执行信任混为一谈。

文本相同时避免重复更新；文本变化移除旧解析状态，清空行/词/派生缓存，增加全局版本并广播事件。打开状态和工程/库引用有不同生命周期；引用计数支持多个 scope 使用同一文件。

**CodeOutline 建议**：继续保留各 LSP 会话自己的草稿，而非照搬单客户端 `fileMap` 为全局唯一文本。磁盘索引、会话草稿、请求快照三者必须明确。MCP 默认不应意外读取某个编辑器会话的未保存内容。

## 7. 增量同步和坐标转换

定位：`provider/provider.lua:didChange`、`text-merger.lua`、`proto/converter.lua`、`encoder/`。

服务声明 `textDocumentSync.change = 2`。对增量修改，文本合并器按顺序更新行数组：保留首行左半和末行右半，替换中间行，调整行数；也接受全文替换。行缓存可留给下一次修改。字符到字节转换走协商后的编码工具。

协议位置转换集中处理内部坐标与 LSP 行/字符坐标。插件改变分析文本时，转换器借助差异映射回到用户原始文本。不能把 LuaLS 内部 parser 的位置编码直接当成 CodeOutline 的字节偏移。

**CodeOutline 现状**：全文同步 `change = 1`；`didChange` 拒绝 `range`；`documents.lua` 已提供 UTF-16 位置转换。

**最小方案**：增加 `Doc:apply_changes`，顺序应用范围修改和全文修改，递增版本并使缓存失效。先保持 worker 接收最新全文，不同时引入线程间 delta。验收覆盖 emoji、中文、组合字符、CRLF、跨行删除、多段修改、空文件和陈旧版本。增量同步不代表增量 AST 解析。

## 8. 工作区、文件发现、忽略与预加载

定位：`workspace/workspace.lua`、`workspace/scope.lua`、`workspace/loading.lua`、`filewatch.lua`。

工作区以 scope 管理文件夹、fallback、override 和关联库；路径规范化与真实 URI 用于文件身份。文件扫描综合编辑器排除项、`.gitignore`、子模块策略、库路径和显式忽略目录。库路径与普通项目路径分别构造 matcher。

预加载有文件数量和大小限制；打开文件与库文件在部分大小规则中享有例外。后台加载、解析、进度和取消状态由 loader 管理；重载使用任务唯一性。文件监听与配置变化可以触发重新加载。scope 的移除释放资源和文件引用。

**CodeOutline 建议**：区分“发现文件”“加载文本”“解析”“可提供全局查询”阶段；索引未就绪时仍可为已打开文件提供局部结果。明确第三方目录、生成文件和大文件策略，避免补全要求变成无界预加载。不要把 LuaLS 的预加载规模默认值直接套到多语言项目。

## 9. 解析缓存、惰性存储与失效

定位：`files.lua:compileStateThen/compileStateAsync/compileState/getState`；`vm/vm.lua:getCache/flushCache`。

解析状态先查 `stateMap`，缺失时解析文本，附加 LuaDoc 并发布。异步路径在接收结果时比较 `file.text` 与提交文本，不同则丢弃结果，避免旧结果覆盖新内容。

`stateMap` 使用弱值；同一文件累计解析达到 3 次后将状态强引用保存，减少热点反复回收。开启 `LAZY` 且文件不是可信编辑文本时，状态可转换为惰性结构，配合磁盘 cache。该条件分支不是默认对所有 AST 进行持久化。

VM 缓存跟随 `files.globalVersion`：版本不同整体换缓存，并标记旧缓存 dead。该策略简单，但不是按语义依赖精确失效；其作用范围也不是多项目隔离设计。

**CodeOutline 现状**：`Doc:parse` 缓存记录；`Doc:tokens` 重新解析；补全另有草稿与磁盘 `rec/tokens` 缓存；导航覆盖视图每次重建。

**建议**：先统一同一文档版本的解析产物，让导航和补全共享。缓存键考虑项目、会话、文档版本、磁盘记录身份、解析配置和索引 generation；按实际依赖选取，不是机械地给每个缓存塞入全部字段。设置字节/文件数量上限和统计，测重复请求解析次数后再考虑 AST 落盘。不要仅因 LuaLS 有 lazy table 就引入相同复杂度。

## 10. AST、LuaDoc 与语义分析分层

定位：`parser/init.lua`、`parser/compile.lua`、`parser/guide.lua`、`parser/luadoc.lua`；`vm/compiler.lua`、`vm/node.lua`、`vm/variable.lua`、`vm/global.lua`、`vm/infer.lua`、`vm/generic.lua`。

parser 产生具有父子关系、源码范围和语言结构的 AST；guide 提供查找、遍历与坐标工具。LuaDoc 作为可绑定到语法节点的类型信息进入分析。VM 根据节点种类统一处理变量、字段、函数、调用、返回值、全局名称和文档类型，支持泛型替换等更深的分析。

编辑功能消费这些语义接口，而不是分别扫描文本推断相同关系。这里存在大量语言专属规则，不能从几个接口概括成“完整可靠的类型证明器”。

**CodeOutline 路线**：先让 Lua parser 记录局部作用域/遮蔽、模块导出、有限注释类型，建立可复用事实；保留多语言轻量索引。暂缓整体引入 LuaLS 的 AST/VM、泛型和所有诊断。

## 11. 定义、引用、类型定义与实现跳转

定位：`core/definition.lua`、`core/reference.lua`、`core/type-definition.lua`、`core/implementation.lua`；`vm/def.lua`、`vm/ref.lua`。

定义查询先找光标所在 AST 节点，再根据节点语义寻找绑定、赋值和对象来源；字符串参数里的模块加载调用单独处理。结果有排序、去重和范围筛选，避免重复嵌套目标。

引用查询不只是名字全局匹配。`vm/ref.lua` 的一条重要路径是：先用文本是否包含关键字筛文件，再解析候选 AST，检查候选的定义是否属于目标定义集合。其他路径对局部变量或全局节点使用不同规则。跨文件搜索主动让出并提供可取消进度。

**借鉴**：轻量索引筛候选，精确解析验证绑定，是适合 CodeOutline 的渐进方案。不能把词命中当最终引用；也不能把 LuaLS 的按需跨文件扫描推导成 CodeOutline 应立即删除全部持久关系。需要对比稀有名/常见名、冷/热请求、编辑失效和内存成本。

## 12. 补全：上下文、排序、编辑范围与延迟详情

定位：`core/completion/completion.lua`、`keyword.lua`、`postfix.lua`、`auto-require.lua`；`provider/provider.lua:completion/resolve`。

核心处理不同上下文的候选，协议层组合 `label/kind/detail/sortText/filterText/insertText/textEdit/additionalTextEdits`、文档和片段格式。候选可以附带 ID，先返回列表，待 `completionItem/resolve` 请求再生成详细文档或附加修改。

延迟栈保存 URI、位置和节点类型，resolve 时重新找当前节点，而不是永久持有旧 AST。仍应注意位置在文本编辑后漂移的问题，不能据此推断所有版本问题已解决。

**CodeOutline 建议**：先补精确 `textEdit` 和相关性排序，再引入昂贵详情的 resolve。当前 `label/kind/detail` 很轻，单纯增加 resolve 不会自动加速。未来 resolve 数据应携带会话、版本和稳定符号身份。触发字符只承诺能处理的上下文；成员查询、普通局部补全与导入补全分别设预算。

## 13. Hover、签名与文档展示

定位：`core/hover/`、`core/signature.lua`、`provider/markdown.lua`。

hover 结合类型/函数标签和说明，去重多个定义的展示；签名帮助分析当前调用及参数位置。Markdown 构造与协议封装在适配层统一处理，客户端可选择自定义文档展示。

**借鉴**：索引记录中分离签名、声明范围和说明文本；hover、补全详情、签名帮助共享描述生成器。按需解析文档，限制输出长度。不要把 VS Code 专属可点击命令或受信任 HTML 设为跨编辑器通用输出。

## 14. 重命名与文件重命名

定位：`core/rename.lua`；`provider/provider.lua:prepareRename/rename/didRenameFiles`。

重命名先验证光标对象与新名称，再对局部、全局、字段、标签及文档类型走不同规则，收集精确文本修改。字段名变化可能涉及点访问与字符串索引等不同语法，不能用纯文本替换代替。文件重命名也有独立协议处理路径。

**CodeOutline 建议**：引用准确性满足要求前不开放全项目 rename。未来先支持有明确绑定的局部符号，返回可预览的 WorkspaceEdit；验证版本、修改范围不重叠、字符串/注释不被误改，以及不合法名称被拒绝。

## 15. 诊断：规则模块化、节流与发布

定位：`core/diagnostics/`、`proto/diagnostic.lua`、`provider/diagnostic.lua`。

单项诊断规则分文件组织，由统一配置决定严重级别、分组级别及检查文件状态。provider 负责结果缓存、范围转换、发布和工程范围调度。编辑时合并同文件任务；工作区检查可以延迟，并通过 `workspaceRate` 按计算耗时插入休息，降低后台 CPU 占用。

主要已读路径使用 `textDocument/publishDiagnostics`。`textDocument/diagnostic` 被标为 preview，当前实现执行诊断后返回 unchanged，旁边完整 pull 逻辑被注释；工作区 pull handler 存在但能力声明也有注释。不能将本版本描述成已经完整迁移 pull diagnostics。

**CodeOutline 建议**：诊断是独立产品范围。若需要，先支持 parser 可明确判断的问题，沿用取消、版本和限额，再考虑类型诊断。不要为了导航补全顺带引入所有检查。

## 16. 其他编辑功能

| 功能 | LuaLS 实现入口和做法 | CodeOutline 适用性 |
| --- | --- | --- |
| 文档符号 | `core/document-symbol.lua` 从语言节点构造符号层次，provider 转换范围 | 已有，可借鉴层次和声明选择范围区分 |
| 工作区符号 | `core/workspace-symbol.lua` 结合 AST 与全局/类型记录、名称匹配 | 优先使用现有常驻符号索引，避免全工程 AST 扫描 |
| 高亮 | `core/highlight.lua` 提供文档内相关位置 | 可基于准确绑定渐进增加 |
| 语义着色 | `core/semantic-tokens.lua` 排序、处理重叠并编码 token；支持 full/range 入口 | 可从词法和声明类型开始；token 的相对编码不是 full/delta 协议 |
| 折叠 | `core/folding.lua`、`textDocument/foldingRange` | 可复用解析器结构范围 |
| 参数/类型提示 | `core/hint.lua`、`inlayHint` 和 resolve | 等类型事实稳定后再做 |
| CodeLens | `core/code-lens.lua`、`codeLens/resolve` | 昂贵引用统计延迟求值，不要打开文件就全项目扫描 |
| CodeAction | `core/code-action.lua` | 诊断与修改建议分离，修改交给客户端预览 |
| 颜色 | `core/color.lua`、documentColor/colorPresentation | 较低优先级，语言/项目相关 |
| 格式化 | `core/formatting.lua` 等调用可选 `code_format` 原生模块 | 不属于索引必需能力；缺少模块应明确降级 |

格式化配置向上查找 `.editorconfig` 并监听失效，同时有默认配置和非标准语法选项。不能把它归为纯 Lua 格式化器。附录中的协议注册表给出更完整入口。

## 17. 配置分层、验证和热更新

定位：`config/template.lua`、`config/config.lua`、`config/loader.lua`；`provider/provider.lua:updateConfig`。

配置包含 schema/default、原始值和标准化值。按键选择 override、所属/关联 scope 或 fallback。指定 `CONFIGPATH` 写 override；工作区先加载客户端配置，再加载 `.luarc.json` 或 `.luarc.jsonc`；同次 `config.update` 后面的来源覆盖前面已设置的键。全局客户端配置提供 fallback。

配置更新后比较值并发事件，功能模块订阅自己关心的键。JSONC 配置解析失败会尝试保留前一份配置；本地配置还支持执行 Lua，错误分支的行为与 JSONC 不完全相同，不能一概宣称“所有格式错误均安全回退”。

**借鉴**：配置集中描述、明确优先级、只使相关缓存失效。CodeOutline 的项目配置优先保持数据式；若支持可执行插件或 Lua 配置，需单独定义信任边界。多会话配置冲突必须明确，不应悄悄修改共享项目语义。

## 18. 模块解析、标准库、第三方库和 FFI

定位：`workspace/require-path.lua`、`library.lua`、`vm/library.lua`、`meta/template/`、`files.lua:saveDll`。

require manager 按 scope 维护路径可见性与 require 搜索缓存，依据 `Lua.runtime.path` 模板把模块名映射到候选 URI；dofile/loadfile 另有根路径策略。配置和文件变化必须与这些缓存的失效配合。

标准库不是只写死在补全代码里：meta 模板结合运行时版本、编码、语言和 builtin 选择生成声明文件，并作为库参与分析。第三方库识别按代码词或文件名匹配配置，提供采用库配置的交互。客户端还有 addon manager 与 FFI meta 刷新入口。

**CodeOutline 建议**：对 xnet 原生 API，可以维护可索引的 Lua 声明文件，让跳转、补全、hover 共用。优先显式 library roots 和 require 模板，避免每个功能各猜一次包路径。DLL/FFI 深度识别属于后续范围，本文未验证其原生实现。

## 19. 插件与源码变换

定位：`plugin.lua:dispatch/checkTrustLoad/initPlugin`、`files.lua:pluginOnSetText/pluginOnTransformAst`、`string-merger.lua`、`proto/converter.lua`。

插件按工作区初始化与分派，可改变用于分析的文本或 AST。文本变换需要保留 originText 和差异信息，使最终位置仍指向原文件。插件加载有信任记录和提示，也提供显式绕过开关。

**借鉴**：特殊 DSL/嵌入语言如需转成 Lua 分析，坐标映射必须与转换一起设计。近期 CodeOutline 的声明式 definitionRules 更容易控制；不要仅为几个特殊跳转就开放任意脚本插件。

## 20. 调试入口与 LSP/DAP 边界

定位：`server/debugger.lua`；`server/main.lua`；`script/pub/pub.lua` 线程模板。

`debugger.lua` 首先检查 DEVELOP；搜索用户安装的 `actboy168.lua-debug`，选择版本，加载其 debugger 模块，在 `127.0.0.1:DBGPORT` 启动连接入口，按 DBGWAIT 等待。后台线程模板也尝试加载该入口。

这是开发者调试 LuaLS 自身的集成，调试器来自外部扩展。本扩展清单没有 `contributes.debuggers`；不能据此认为它自带面向用户 Lua 程序的 DAP 服务。

**CodeOutline 建议**：如要调试服务自身，可设计显式开发开关，但必须实测 xnet Lua 运行时和多线程兼容性。用户程序的断点/单步/变量查看则需要独立 DAP 与目标运行时支持，属于另一项工程。

## 21. 日志、进度、性能与内存观测

定位：`service/service.lua:reportMemory/reportTask/reportCache/reportProto`、`progress.lua`、`tracy.lua`、`log.lua`。

服务可报告内存、活动协程、VM 缓存和未完成协议请求；慢方法、慢编译、慢补全有耗时日志。Tracy 标记便于细分阶段。进度对象支持延迟显示、脏标记、取消回调和作用域结束清理，快速操作不会反复闪烁进度条。

**CodeOutline 建议**：记录 queue_ms、parse_ms、resolve_ms、serialize_ms、总 wall time；记录取消/过期丢弃次数、缓存命中和解析次数、草稿字节与索引内存。不要只测 `os.clock` CPU 时间就宣称交互延迟改善。日志避免记录完整用户源文件；stdio 的 stdout 只承载协议。

## 22. CLI、打包与研究范围限制

定位：`cli/help.lua`、`cli/check*.lua`、`cli/doc/`；扩展 `package.json`。

CLI 提供离线诊断报告和文档生成，复用服务端解析/语义模块；可指定输出位置、级别、格式和配置。命令行能力不依赖编辑器打开文档，适合自动化使用。

安装包将客户端产物、服务端 Lua、平台二进制、meta 模板、locale、设置声明打包在一起。附录记录清单版本与文件指纹，不假定它与某个未经核验的 Git tag 字节一致。未运行二进制、安装依赖或验证上游构建；也未采集现有日志中的用户项目内容。

**借鉴**：CodeOutline 已有 CLI/MCP/LSP 共用 Lua 逻辑，应继续复用 service，而不是另写编辑器专用分析后端。测试代码和生产运行时依赖保持分离。

## 23. 落地路线与验收

以下是建议，不是已实现或已证明的性能收益。

| 阶段 | 工作 | 必须验证 | 暂缓项 |
| --- | --- | --- | --- |
| P0 | 请求分阶段计时、取消/缓存统计 | 可区分排队与执行，日志不破坏协议 | 大规模监控系统 |
| P1 | 增量文本同步 | UTF-16、CRLF、多段修改、版本顺序、双会话 | 增量 AST |
| P1 | 文档解析产物共享 | 同版本导航/补全复用；变更和配置修改失效；内存受限 | 全 AST 磁盘数据库 |
| P1 | 补全 textEdit 与排序 | 光标中间补全、成员链、相同 label、编辑器实际表现 | 无条件增加 resolve |
| P2 | 队列合并和后台可恢复批次 | 长 MCP 查询/索引并存时补全 p95；公平性；取消后草稿仍正确 | 第二套独立 LSP 调度器 |
| P2 | Lua 作用域、模块导出、有限 LuaDoc | 同名遮蔽、require 别名、返回表、注释字段和参数 | 完整 LuaLS VM |
| P3 | 按需引用语义验证、有限 rename | 同名不同对象排除；修改范围与版本正确 | 不可靠全项目重命名 |
| 可选 | 原生库声明、signatureHelp、inlayHint | 声明来源明确，多个功能使用相同语义事实 | 全诊断/格式化/DAP 一并开发 |

基准矩阵：冷启动/热缓存；小/大项目；单会话/双会话；稀有名/高频名；连续编辑；后台刷新；MCP 长请求；取消和关闭工程。报告 p50/p95/p99、峰值内存、解析次数、队列深度与结果完整性。语言解析器变更还需运行 native 与 `XSCAN_PURE_LUA=1` 两条路径。

## 24. 防止误用的结论清单

- LuaLS 同时使用协程和后台线程；不要简称“单线程协程服务器”。
- 文本增量同步不等于语法树增量更新。
- full/range semantic tokens 不等于实现 full/delta。
- 代码中的 preview 属性、注释掉的逻辑和未声明的能力必须分别看待。
- `abortByFileUpdate` 属性存在，但关闭请求的调用在此版本被注释。
- 补全优先级调用被注释，不能作为低延迟已实现的证据。
- VM 缓存是全局版本失效，不是精确依赖增量计算的证据。
- 线程任务入口存在，不代表所有常规请求都经该线程路径。
- 原生格式化模块、运行时和外部 debugger 不能靠复制 Lua 文件替代。
- 分析范围覆盖主要设计与入口；不宣称穷尽每条诊断、类型规则或二进制实现。
- 本文没有卸载扩展、运行其调试端口或修改 CodeOutline 服务代码。

## 附录说明

以下清单与摘录在扩展仍安装时直接生成。`server/script/...` 等均为扩展内相对路径，行号是这份安装副本的位置。源码摘录用于离线理解；文件指纹用于将来核对重新取得的源码，不替代完整源码备份。

## 附录 A：协议注册入口完整清单

从 server/script/provider/provider.lua 注册语句提取，包括条件注册和预览入口；本表表示源码入口存在，不表示默认对所有客户端宣告。

| 方法 | 行号 |
| --- | --- |
| initialize | 111 |
| initialized | 140 |
| exit | 167 |
| shutdown | 174 |
| workspace/didChangeConfiguration | 181 |
| workspace/didRenameFiles | 190 |
| workspace/didChangeWorkspaceFolders | 246 |
| textDocument/didOpen | 271 |
| textDocument/didClose | 287 |
| textDocument/didChange | 299 |
| textDocument/didSave | 324 |
| textDocument/hover | 340 |
| textDocument/definition | 420 |
| textDocument/typeDefinition | 445 |
| textDocument/implementation | 470 |
| textDocument/references | 495 |
| textDocument/documentHighlight | 530 |
| textDocument/rename | 559 |
| textDocument/prepareRename | 600 |
| textDocument/completion | 621 |
| completionItem/resolve | 732 |
| textDocument/signatureHelp | 773 |
| textDocument/documentSymbol | 825 |
| textDocument/codeAction | 877 |
| textDocument/codeLens | 930 |
| codeLens/resolve | 967 |
| workspace/executeCommand | 977 |
| workspace/symbol | 1023 |
| textDocument/semanticTokens/full | 1082 |
| textDocument/semanticTokens/range | 1111 |
| textDocument/foldingRange | 1142 |
| textDocument/documentColor | 1183 |
| textDocument/colorPresentation | 1211 |
| window/workDoneProgress/cancel | 1218 |
| $/status/click | 1225 |
| textDocument/formatting | 1259 |
| textDocument/rangeFormatting | 1297 |
| textDocument/onTypeFormatting | 1335 |
| $/cancelRequest | 1374 |
| $/requestHint | 1380 |
| textDocument/inlayHint | 1407 |
| inlayHint/resolve | 1456 |
| textDocument/diagnostic | 1468 |
| workspace/diagnostic | 1509 |
| $/api/report | 1556 |
| $/psi/view | 1585 |
| $/psi/select | 1600 |
| $/status/refresh | 1654 |

## 附录 B：扩展配置默认值快照

直接提取安装包 package.json，说明优先取简体中文本地化。默认值为扩展清单默认值；服务端 schema、工作区配置和客户端协商仍可能改变实际行为。此表不包含任何用户设置。

| 配置键 | 类型 | 清单默认值（JSON） | 说明 |
| --- | --- | --- | --- |
| Lua.addonManager.enable | boolean | true | 是否启用扩展的附加插件管理器(Addon Manager) |
| Lua.addonManager.repositoryBranch | string | "" | 指定插件管理器(Addon Manager)使用的git仓库分支 |
| Lua.addonManager.repositoryPath | string | "" | 指定插件管理器(Addon Manager)使用的git仓库路径 |
| Lua.addonRepositoryPath | string | "" | 指定插件仓库的路径（与 Addon Manager 无关） |
| Lua.codeLens.enable | boolean | false | 启用代码度量。 |
| Lua.completion.autoRequire | boolean | true | 输入内容看起来是个文件名时，自动 `require` 此文件。 |
| Lua.completion.callSnippet | string | "Disable" | 显示函数调用片段。 |
| Lua.completion.displayContext | integer | 0 | 预览建议的相关代码片段，可能可以帮助你了解这项建议的用法。设置的数字表示代码片段的截取行数，设置为`0`可以禁用此功能。 |
| Lua.completion.enable | boolean | true | 启用自动完成。 |
| Lua.completion.keywordSnippet | string | "Replace" | 显示关键字语法片段 |
| Lua.completion.maxSuggestCount | integer | 100 | 自动完成时最多分析的字段数量。当对象字段超过此上限时，需要更精确的输入才会显示补全。 |
| Lua.completion.postfix | string | "@" | 用于触发后缀建议的符号。 |
| Lua.completion.requireSeparator | string | "." | `require` 时使用的分隔符。 |
| Lua.completion.showParams | boolean | true | 在建议列表中显示函数的参数信息，函数拥有多个定义时会分开显示。 |
| Lua.completion.showWord | string | "Fallback" | 在建议中显示上下文单词。 |
| Lua.completion.workspaceWord | boolean | true | 显示的上下文单词是否包含工作区中其他文件的内容。 |
| Lua.diagnostics.disable | array | [] | 禁用的诊断（使用浮框括号内的代码）。 |
| Lua.diagnostics.enable | boolean | true | 启用诊断。 |
| Lua.diagnostics.enableScheme | array | ["file"] | TODO: Needs documentation |
| Lua.diagnostics.globals | array | [] | 已定义的全局变量。 |
| Lua.diagnostics.globalsRegex | array | [] | 已定义的全局变量符合的正则表达式。 |
| Lua.diagnostics.groupFileStatus | object | （未声明） | 批量修改一个组中的文件状态。<br><br>* Opened:  只诊断打开的文件<br>* Any:     诊断任何文件<br>* None:    禁用此诊断<br><br>设置为 `Fallback` 意味着组中的诊断由 `diagnostics.neededFileStatus` 单独设置。<br>其他设置将覆盖单独设置，但是不会覆盖以 `!` 结尾的设置。<br> |
| Lua.diagnostics.groupSeverity | object | （未声明） | 批量修改一个组中的诊断等级。<br>设置为 `Fallback` 意味着组中的诊断由 `diagnostics.severity` 单独设置。<br>其他设置将覆盖单独设置，但是不会覆盖以 `!` 结尾的设置。<br> |
| Lua.diagnostics.ignoredFiles | string | "Opened" | 如何诊断被忽略的文件。 |
| Lua.diagnostics.libraryFiles | string | "Opened" | 如何诊断通过 `Lua.workspace.library` 加载的文件。 |
| Lua.diagnostics.neededFileStatus | object | （未声明） | * Opened:  只诊断打开的文件<br>* Any:     诊断任何文件<br>* None:    禁用此诊断<br><br>以 `!` 结尾的设置优先级高于组设置 `diagnostics.groupFileStatus`。<br> |
| Lua.diagnostics.severity | object | （未声明） | 修改诊断等级。<br>以 `!` 结尾的设置优先级高于组设置 `diagnostics.groupSeverity`。<br> |
| Lua.diagnostics.unusedLocalExclude | array | [] | 如果变量名匹配以下规则，则不对其进行 `unused-local` 诊断。 |
| Lua.diagnostics.workspaceDelay | integer | 3000 | 进行工作区诊断的延迟（毫秒）。 |
| Lua.diagnostics.workspaceEvent | string | "OnSave" | 设置触发工作区诊断的时机。 |
| Lua.diagnostics.workspaceRate | integer | 100 | 工作区诊断的运行速率（百分比）。降低该值会减少CPU占用，但是也会降低工作区诊断的速度。你当前正在编辑的文件的诊断总是全速完成，不受该选项影响。 |
| Lua.doc.packageName | array | [] | 将特定名称的字段视为package，例如 `m_*` 意味着 `XXX.m_id` 与 `XXX.m_type` 只能在定义所在的文件中访问。 |
| Lua.doc.privateName | array | [] | 将特定名称的字段视为私有，例如 `m_*` 意味着 `XXX.m_id` 与 `XXX.m_type` 是私有字段，只能在定义所在的类中访问。 |
| Lua.doc.protectedName | array | [] | 将特定名称的字段视为受保护，例如 `m_*` 意味着 `XXX.m_id` 与 `XXX.m_type` 是受保护的字段，只能在定义所在的类极其子类中访问。 |
| Lua.doc.regengine | string | "glob" | 用于匹配文档作用域名称的正则表达式引擎。 |
| Lua.docScriptPath | string | "" | 自定义 Lua 脚本路径，覆盖默认文档生成行为。 |
| Lua.format.defaultConfig | object | {} | 默认的格式化配置，优先级低于工作区内的 `.editorconfig` 文件。<br>请查阅[格式化文档](https://github.com/CppCXY/EmmyLuaCodeStyle/tree/master/docs)了解用法。<br> |
| Lua.format.enable | boolean | true | 启用代码格式化程序。 |
| Lua.hint.arrayIndex | string | "Auto" | 在构造表时提示数组索引。 |
| Lua.hint.await | boolean | true | 如果调用的函数被标记为了 `---@async` ，则在调用处提示 `await` 。 |
| Lua.hint.awaitPropagate | boolean | false | 启用 `await` 的传播, 当一个函数调用了一个`---@async`标记的函数时，会自动标记为`---@async`。 |
| Lua.hint.enable | boolean | false | 启用内联提示。 |
| Lua.hint.paramName | string | "All" | 在函数调用处提示参数名。 |
| Lua.hint.paramType | boolean | true | 在函数的参数位置提示类型。 |
| Lua.hint.semicolon | string | "SameLine" | 若语句尾部没有分号，则显示虚拟分号。 |
| Lua.hint.setType | boolean | false | 在赋值操作位置提示类型。 |
| Lua.hover.enable | boolean | true | 启用悬停提示。 |
| Lua.hover.enumsLimit | integer | 5 | 当值对应多个类型时，限制类型的显示数量。 |
| Lua.hover.expandAlias | boolean | true | 是否展开别名。例如 `---@alias myType boolean\|number` 展开后显示为 `boolean\|number`，否则显示为 `myType`。<br> |
| Lua.hover.previewFields | integer | 10 | 悬停提示查看表时，限制表内字段的最大预览数量。 |
| Lua.hover.viewNumber | boolean | true | 悬停提示查看数字内容（仅当字面量不是十进制时）。 |
| Lua.hover.viewString | boolean | true | 悬停提示查看字符串内容（仅当字面量包含转义符时）。 |
| Lua.hover.viewStringMax | integer | 1000 | 悬停提示查看字符串内容时的最大长度。 |
| Lua.language.completeAnnotation | boolean | true | (仅VSCode) 在注解后换行时自动插入 "---@ "。 |
| Lua.language.fixIndent | boolean | true | (仅VSCode) 修复错误的自动缩进，例如在包含单词 "function" 的字符串中换行时出现的错误缩进。 |
| Lua.misc.executablePath | string | "" | VSCode中指定可执行文件路径。 |
| Lua.misc.parameters | array | [] | VSCode中启动语言服务时的[命令行参数](https://luals.github.io/wiki/usage#arguments)。 |
| Lua.nameStyle.config | object | {} | 设定命名风格检查的配置。<br>请查阅[格式化文档](https://github.com/CppCXY/EmmyLuaCodeStyle/tree/master/docs)了解用法。<br> |
| Lua.runtime.builtin | object | （未声明） | 调整内置库的启用状态，你可以根据实际运行环境禁用掉不存在的库（或重新定义）。<br><br>* `default`: 表示库会根据运行版本启用或禁用<br>* `enable`: 总是启用<br>* `disable`: 总是禁用<br> |
| Lua.runtime.enableLuaJITExtensions | boolean | false | 启用 LuaJIT 扩展语法（需要将 `Lua.runtime.version` 设置为 `LuaJIT`）。<br>各项扩展语法也可以单独通过 `Lua.runtime.nonstandardSymbol` 启用。<br> |
| Lua.runtime.fileEncoding | string | "utf8" | 文件编码，`ansi` 选项只在 `Windows` 平台下有效。 |
| Lua.runtime.meta | string | "${version} ${language} ${encoding}" | meta文件的目录名称格式。 |
| Lua.runtime.nonstandardSymbol | array | [] | 支持非标准的符号。请务必确认你的运行环境支持这些符号。 |
| Lua.runtime.path | array | ["?.lua","?/init.lua"] | 当使用 `require` 时，如何根据输入的名字来查找文件。<br>此选项设置为 `?/init.lua` 意味着当你输入 `require 'myfile'` 时，会从已加载的文件中搜索 `{workspace}/myfile/init.lua`。<br>当 `runtime.pathStrict` 设置为 `false` 时，还会尝试搜索 `${workspace}/**/myfile/init.lua`。<br>如果你想要加载工作区以外的文件，你需要先设置 `Lua.workspace.library`。<br> |
| Lua.runtime.pathStrict | boolean | false | 启用后 `runtime.path` 将只搜索第一层目录，见 `runtime.path` 的说明。 |
| Lua.runtime.plugin | string/array | （未声明） | 插件路径，请查阅[文档](https://luals.github.io/wiki/plugins)了解用法。 |
| Lua.runtime.pluginArgs | array/object | （未声明） | 插件的额外参数。 |
| Lua.runtime.special | object | {} | 将自定义全局变量视为一些特殊的内置变量，语言服务将提供特殊的支持。<br>下面这个例子表示将 `include` 视为 `require` 。<br>```json<br>"Lua.runtime.special" : {<br>    "include" : "require"<br>}<br>```<br> |
| Lua.runtime.unicodeName | boolean | false | 允许在名字中使用 Unicode 字符。 |
| Lua.runtime.version | string | "Lua 5.4" | Lua运行版本。 |
| Lua.semantic.annotation | boolean | true | 对类型注解进行语义着色。 |
| Lua.semantic.enable | boolean | true | 启用语义着色。你可能需要同时将 `editor.semanticHighlighting.enabled` 设置为 `true` 才能生效。 |
| Lua.semantic.keyword | boolean | false | 对关键字/字面量/运算符进行语义着色。只有当你的编辑器无法进行语法着色时才需要启用此功能。 |
| Lua.semantic.variable | boolean | true | 对变量/字段/参数进行语义着色。 |
| Lua.signatureHelp.enable | boolean | true | 启用参数提示。 |
| Lua.spell.dict | array | [] | 拼写检查的自定义单词。 |
| Lua.type.castNumberToInteger | boolean | true | 允许将 `number` 类型赋给 `integer` 类型。 |
| Lua.type.checkTableShape | boolean | false | 对表的形状进行严格检查。<br> |
| Lua.type.inferParamType | boolean | false | 未注释参数类型时，参数类型由函数传入参数推断。<br><br>如果设置为 "false"，则在未注释时，参数类型为 "any"。<br> |
| Lua.type.inferTableSize | integer | 10 | 类型推断期间分析的表字段的最大数量。 |
| Lua.type.maxUnionVariants | integer | 0 | TODO: Needs documentation |
| Lua.type.weakNilCheck | boolean | false | 对联合类型进行类型检查时，忽略其中的 `nil`。<br><br>此设置为 `false` 时，`numer\|nil` 类型无法赋给 `number` 类型；为 `true` 是则可以。<br> |
| Lua.type.weakUnionCheck | boolean | false | 联合类型中只要有一个子类型满足条件，则联合类型也满足条件。<br><br>此设置为 `false` 时，`number\|boolean` 类型无法赋给 `number` 类型；为 `true` 时则可以。<br> |
| Lua.typeFormat.config | object | （未声明） | 配置输入Lua代码时的格式化行为 |
| Lua.window.progressBar | boolean | true | 在状态栏显示进度条。 |
| Lua.window.statusBar | boolean | true | 在状态栏显示插件状态。 |
| Lua.workspace.checkThirdParty | string/boolean | （未声明） | 自动检测与适配第三方库，目前支持的库为：<br><br>* OpenResty<br>* Cocos4.0<br>* LÖVE<br>* LÖVR<br>* skynet<br>* Jass<br> |
| Lua.workspace.dofileRoots | array | [] | 除了当前工作区以外，`dofile` 会把这些目录视为可能的根目录。这些目录中的文件会被立即加载。 |
| Lua.workspace.ignoreDir | array | [".vscode"] | 忽略的文件与目录（使用 `.gitignore` 语法）。 |
| Lua.workspace.ignoreSubmodules | boolean | true | 忽略子模块。 |
| Lua.workspace.library | array | [] | 除了当前工作区以外，还会从哪些目录中加载文件。这些目录中的文件将被视作外部提供的代码库，部分操作（如重命名字段）不会修改这些文件。 |
| Lua.workspace.maxPreload | integer | 5000 | 最大预加载文件数。 |
| Lua.workspace.preloadFileSize | integer | 500 | 预加载时跳过大小大于该值（KB）的文件。 |
| Lua.workspace.useGitIgnore | boolean | true | 忽略 `.gitignore` 中列举的文件。 |
| Lua.workspace.userThirdParty | array | [] | 在这里添加私有的第三方库适配文件路径，请参考内置的[配置文件路径](https://github.com/LuaLS/lua-language-server/tree/master/meta/3rd) |

## 附录 C：关键源码摘录

以下是原文件连续行的原样摘录（仅统一换行为 LF），每段标注原路径和范围；它们是局部片段，依赖所在模块上下文，不能直接作为独立可运行代码。

### 增量文本合并入口

来源：server/script/provider/provider.lua:299-321。

```lua
m.register 'textDocument/didChange' {
    ---@async
    function (params)
        local fixIndent = require 'core.fix-indent'
        local doc     = params.textDocument
        local changes = params.contentChanges
        local uri     = files.getRealUri(doc.uri)
        local text    = files.getOriginText(uri)
        if not text then
            text = util.loadFile(furi.decode(uri))
            files.setText(uri, text, false)
            fixIndent(uri, changes)
            return
        end
        local rows = files.getCachedRows(uri)
        text, rows = tm(text, rows, changes)
        files.setText(uri, text, true, function (file)
            file.version = doc.version
        end)
        files.setCachedRows(uri, rows)

        fixIndent(uri, changes)
    end
```

### 范围修改的行数组合并

来源：server/script/text-merger.lua:61-125。

```lua
    local startChar = change.range['start'].character
    local endLine   = change.range['end'].line + 1
    local endChar   = change.range['end'].character

    local insertRows = splitRows(change.text)
    local newEndLine = startLine + #insertRows - 1
    local left       = getLeft(rows[startLine], startChar)
    local right      = getRight(rows[endLine],  endChar)
    -- 先把双方的行数调整成一致
    if endLine > #rows then
        log.error('NMD, WSM `endLine > #rows` ?')
        for i = #rows + 1, endLine do
            rows[i] = ''
        end
    end
    local delta = #insertRows - (endLine - startLine + 1)
    if delta ~= 0 then
        table.move(rows, endLine, #rows, endLine + delta)
        -- 如果行数变少了，要清除多余的行
        if delta < 0 then
            for i = #rows, #rows + delta + 1, -1 do
                rows[i] = nil
            end
        end
    end
    -- 先处理第一行和最后一行
    if startLine == newEndLine then
        rows[startLine]  = left .. insertRows[1] .. right
    else
        rows[startLine]  = left .. insertRows[1]
        rows[newEndLine] = insertRows[#insertRows] .. right
    end
    -- 修改中间的每一行
    for i = 2, #insertRows - 1 do
        local currentLine = startLine + i - 1
        local insertText  = insertRows[i] or ''
        rows[currentLine] = insertText
    end
end

return function (text, rows, changes)
    for _, change in ipairs(changes) do
        if change.range then
            rows = rows or splitRows(text)
            mergeRows(rows, change)
        else
            rows = nil
            text = change.text
        end
    end
    if rows then
        text = table.concat(rows)
    end
    return text, rows
end
```

### 异步解析过期结果校验

来源：server/script/files.lua:607-626。

```lua
    ---@type brave.param.compile
    local params = {
        uri     = uri,
        text    = file.text,
        mode    = 'Lua',
        version = config.get(uri, 'Lua.runtime.version'),
        options = options
    }
    pub.task('compile', params, function (result)
        if file.text ~= params.text then
            return
        end
        if not result.state then
            log.error('Compile failed:', uri, result.err)
            callback(nil)
            return
        end
        m.compileStateThen(result.state, file)
        callback(result.state)
    end)
```

### 惰性状态与热点保留

来源：server/script/files.lua:531-548。

```lua
    if LAZY and not file.trusted then
        local cache = m.getLazyCache()
        local id = ('%d'):format(file.id)
        clock = os.clock()
        state = lazy.build(state, cache:writterAndReader(id)):entry()
        passed = os.clock() - clock
        if passed > 0.1 then
            log.warn(('Convert lazy-table for [%s] takes [%.3f] sec, size [%.3f] kb.'):format(file.uri, passed, #file.text / 1000))
        end
    end

    file.compileCount = file.compileCount + 1
    if file.compileCount >= 3 then
        file.state = state
        log.debug('State persistence:', file.uri)
    end

    m.onWatch('compile', file.uri)
```

### VM 缓存的全局版本失效

来源：server/script/vm/vm.lua:80-102。

```lua
m.cacheTracker = setmetatable({}, weakMT)

function m.flushCache()
    if m.cache then
        m.cache.dead = true
    end
    m.cacheVersion = files.globalVersion
    m.cache = {}
    m.cacheActiveTime = mathHuge
    m.locked = setmetatable({}, weakMT)
    m.cacheTracker[m.cache] = true
end

function m.getCache(name, weak)
    if m.cacheVersion ~= files.globalVersion then
        m.flushCache()
    end
    m.cacheActiveTime = timer.clock()
    if not m.cache[name] then
        m.cache[name] = weak and setmetatable({}, weakMT) or {}
    end
    return m.cache[name]
end
```

### 协程主动让出

来源：server/script/await.lua:155-177。

```lua
--- 延迟
---@async
function m.delay()
    if not m._enable then
        return
    end
    if not coroutine.isyieldable() then
        return
    end
    local co = coroutine.running()
    local current = m.coMap[co]
    -- TODO
    if current.priority then
        return
    end
    m.delayQueue[#m.delayQueue+1] = function ()
        if coroutine.status(co) ~= 'suspended' then
            return
        end
        return m.checkResult(co, coroutine.resume(co))
    end
    return coroutine.yield()
end
```

### 同文件诊断合并

来源：server/script/provider/diagnostic.lua:450-464。

```lua
function m.refresh(uri)
    if not ws.isReady(uri) then
        return
    end

    await.close('diag:' .. uri)
    ---@async
    await.call(function ()
        await.setID('diag:' .. uri)
        repeat
            await.sleep(0.1)
        until not m.isPaused()
        xpcall(m.doDiagnostic, log.error, uri)
    end)
end
```

### 协议请求退出时响应

来源：server/script/proto/proto.lua:177-204。

```lua
    await.call(function () ---@async
        --log.debug('Start method:', method)
        if proto.id then
            await.setID('proto:' .. proto.id)
        end
        local clock = os.clock()
        local ok = false
        local res
        -- 任务可能在执行过程中被中断，通过close来捕获
        local response <close> = function ()
            local passed = os.clock() - clock
            if passed > 0.5 then
                log.warn(('Method [%s] takes [%.3f]sec. %s'):format(method, passed, inspect(proto, secretOption)))
            end
            --log.debug('Finish method:', method)
            if not proto.id then
                return
            end
            await.close('proto:' .. proto.id)
            if ok then
                m.response(proto.id, res)
            else
                m.responseErr(proto.id, proto._closeReason or define.ErrorCodes.InternalError, proto._closeMessage or res)
            end
        end
        ok, res = xpcall(abil, log.error, proto.params, proto.id)
        await.delay()
    end)
```

### 同批请求取消预扫描

来源：server/script/proto/proto.lua:207-229。

```lua
function m.applyMethodQueue()
    local queue = m.methodQueue
    m.methodQueue = {}
    local canceled = {}
    for _, proto in ipairs(queue) do
        if proto.method == '$/cancelRequest' then
            canceled[proto.params.id] = true
        end
    end
    for _, proto in ipairs(queue) do
        if not canceled[proto.id] then
            m.applyMethod(proto)
        end
    end
end

function m.doMethod(proto)
    m.methodQueue[#m.methodQueue+1] = proto
    if #m.methodQueue > 1 then
        return
    end
    timer.wait(0, m.applyMethodQueue)
end
```

### 未启用的内容变化自动取消

来源：server/script/provider/provider.lua:1656-1671。

```lua
files.watch(function (ev, uri)
    if not workspace.isReady(uri) then
        return
    end
    if ev == 'update'
    or ev == 'remove' then
        for id, p in pairs(proto.holdon) do
            if m.attributes[p.method].abortByFileUpdate then
                log.debug('close proto(ContentModified):', id, p.method)
                --proto.close(id, define.ErrorCodes.ContentModified, 'Content modified.')
            end
        end
    end
end)

return m
```

### 补全延迟详情的数据标识

来源：server/script/provider/provider.lua:702-728。

```lua
            if res.id then
                if easy and os.clock() - clock < 0.05 then
                    local resolved = core.resolve(res.id)
                    if resolved then
                        item.detail = resolved.detail
                        item.documentation = resolved.description and {
                            value = tostring(resolved.description),
                            kind  = 'markdown',
                        }
                    end
                else
                    easy = false
                    item.data = {
                        uri     = uri,
                        id      = res.id,
                    }
                end
            end
            items[i] = item
        end
        if result.incomplete == nil then
            result.incomplete = false
        end
        return {
            isIncomplete = result.incomplete,
            items        = items,
        }
```

### 后台线程组的启动条件

来源：server/script/service/service.lua:267-287。

```lua
function m.start()
    util.enableCloseFunction()
    await.setErrorHandle(log.error)
    pub.recruitBraves(4)
    if COMPILECORES and COMPILECORES > 0 then
        pub.recruitBraves(COMPILECORES, 'compile')
    end
    if SOCKET then
        assert(math.tointeger(SOCKET), '`socket` must be integer')
        proto.listen('socket', SOCKET)
    else
        proto.listen('stdio')
    end
    m.report()
    m.lockCache()

    require 'provider'

    m.sayHello()

    m.eventLoop()
```

### 文本来源与缓存失效

来源：server/script/files.lua:221-252。

```lua
    local file = m.fileMap[uri]
    if file.trusted and not isTrust then
        return
    end
    if not isTrust then
        local encoding = config.get(uri, 'Lua.runtime.fileEncoding')
        text = encoder.decode(encoding, text)
    end
    if callback then
        callback(file)
    end
    if file.originText == text then
        return
    end
    local clock = os.clock()
    local newText = pluginOnSetText(file, text)
    m.removeState(file)
    file.text            = newText
    file.trusted         = isTrust
    file.originText      = text
    file.rows            = nil
    file.words           = nil
    file.compileCount    = 0
    file.cache           = {}
    m.globalVersion = m.globalVersion + 1
    m.onWatch('version', uri)
    if create then
        m.onWatch('create', uri)
        m.onWatch('update', uri)
    else
        m.onWatch('update', uri)
    end
```

### require 候选缓存

来源：server/script/workspace/require-path.lua:224-245。

```lua
function mt:findUrisByRequireName(suri, name)
    if type(name) ~= 'string' then
        return {}
    end
    local cache = self.requireCache[name]
    if not cache then
        local results, searcherMap = self:searchUrisByRequireName(name, suri)
        cache = {
            results = results,
            searcherMap = searcherMap,
        }
        self.requireCache[name] = cache
    end
    local results = {}
    local searcherMap = {}
    for _, uri in ipairs(cache.results) do
        if uri ~= suri then
            results[#results+1] = uri
            searcherMap[uri] = cache.searcherMap and cache.searcherMap[uri]
        end
    end
    return results, searcherMap
```

### 调试器开发模式门槛

来源：server/debugger.lua:1-6。

```lua
if not DEVELOP then
    return
end

local fs = require 'bee.filesystem'
local luaDebugs = {}
```

### 外部调试器启动

来源：server/debugger.lua:46-66。

```lua
local debugPath = luaDebugs[1]
local cpath     = "/runtime/win64/lua54/?.dll;/runtime/win64/lua54/?.so"
local path      = "/script/?.lua"

local function tryDebugger()
    local entry = assert(package.searchpath('debugger', debugPath .. path))
    local root = debugPath
    local addr = ("127.0.0.1:%d"):format(DBGPORT)
    local dbg = loadfile(entry)(entry)
    dbg:start {
        address = addr,
    }
    log.debug('Debugger startup, listen port:', DBGPORT)
    log.debug('Debugger args:', addr, root, path, cpath)
    if DBGWAIT then
        dbg:event('wait')
    end
    return dbg
end

xpcall(tryDebugger, log.debug)
```

## 附录 D：源码模块与 SHA-256 指纹

覆盖安装包 server/script 全部文件，以及启动、调试、清单、许可证和两个主要客户端文件。用于离线保留模块清单、与将来重新获取的副本核对。未收集运行日志、用户设置、生成 meta、图片、依赖包和二进制。哈希为原始文件字节 SHA-256，不是摘录统一换行后的哈希。

| 文件 | SHA-256 |
| --- | --- |
| client/out/src/extension.js | 3eb8b05146b916fa2f1c49a572c2e5ae6528085a15dcdd0c53f15e6f2f13e7a3 |
| client/out/src/languageserver.js | bed4693a1c91a9fca7f6eba06d03a57ad9290cb36c21d9b55f700139b1548348 |
| LICENSE.txt | 2d176ca92e0598cf5a1d1a56fe42a5a135dc06395415b59cc38f59c91391ec48 |
| package.json | 5fc4d9fcaafe09c95563e7aea8dc3fc0d471c4e58727de0890bfeb97b6a28268 |
| server/bin/main.lua | cf5585de1751ccfe44fa26e08a65693d2a230ffbf6badc6c22812459f55dbdb3 |
| server/changelog.md | bff0468acb0ca31dfd96aa54bdac17f213a7d7226db8f245de5ad88f54cb1a32 |
| server/debugger.lua | 3d42b0163ca6771af5ff76b4cd9a5e22bf07f1fae0e6c08f58a77ba50449026d |
| server/LICENSE | a06fd2108f6e42db7b6914daf147fdd07285d7b7db2d6e02538483399f9ec0b1 |
| server/main.lua | 02f6ca000c89317b9866622521c2af4e0fbc0017e7f015eb9c9d9d60f27b580d |
| server/script/await.lua | 61bea73f3e244a7345b3c1c704f6fa304434f725dfa63f22dbf32627f5eb4a4e |
| server/script/brave/brave.lua | 10c2346334c1eaf9387245a5b88bddc2b91f1cbe7b16dc3893250cb540de363a |
| server/script/brave/init.lua | 85d62cbd8192d957174b2fb8f592a569a57193c360e42cf29fa462cf6a99be57 |
| server/script/brave/log.lua | b3fdb001997fee60c7e408be1928b5183eeccd13496469463dfd0f391bffbe59 |
| server/script/brave/work.lua | 8f75052bf03a7a2508a402a86c53681390c5269e14f113c95f9f30ab13a8b071 |
| server/script/cli/check_worker.lua | 38d8477e64d05b6168193e49ec07f53d418e311072de39d25fa93e3b412b4d57 |
| server/script/cli/check.lua | dd24d195f912c2baa330aa360abfd74999b8f7f4447de61356e6db8d35d99364 |
| server/script/cli/doc/export.lua | 6dd2d1609936316aa43b2300e8bc5e4a20e1fd8027c81827ec47d629e342222c |
| server/script/cli/doc/init.lua | ec375d4e99f5289d6941930ae9b32f75c5d4a28385d553acf4ad6b7cd3fd5fab |
| server/script/cli/help.lua | c013bc504bc625e1d0c43c50199bf36ad84aa0b114355404a5207f7329862b9b |
| server/script/cli/init.lua | 1a002df6684d4765078c283652fa93cc9e572d021a8241d6916f28065edd50c4 |
| server/script/cli/version.lua | 7cbcfe963d10a7b34b2e7a75b0a2246124a767f0b00c4f98c334df5c90308079 |
| server/script/cli/visualize.lua | 3b95db52641620b7413ac7a767bb69feea981d38ace67288b353469e4835495a |
| server/script/client.lua | 5c07bb17d797ab37c468a67ea74998698103e4cbeed289b1dc554b11749b155b |
| server/script/config/config.lua | 99eb5fbe8b44723c8413d2076513b39079078c31d6101b2d951cc02113cc7b3b |
| server/script/config/env.lua | 81eb570702011306dcbc82a50fcf6459f266b21885ad3568676c3b7bccf85a99 |
| server/script/config/init.lua | 5e6344938c21457f26abb55e5f98655bc7c9ab72782b12541ec5540816736cec |
| server/script/config/loader.lua | d2c787753a3e30afb833db77d5f3c5e237e301134d60e0e9053d09912ebddc51 |
| server/script/config/template.lua | 83bef91e6f8500ce3bae3475a3310f6d96ecb37a8d0cb63b1fe08060c2d91882 |
| server/script/core/code-action.lua | e93a6ce9920c29897c400c3151664b5c8aa2251aa21b105f02da8651db05a38d |
| server/script/core/code-lens.lua | 0d1cb5f7429966dab078ec54e2216de75b724cd51015024868aa9aa689e8e659 |
| server/script/core/color.lua | ba73453897c53ac76c4310be9979bc0449849ed53ed9fcaa5ddb6462945bc57f |
| server/script/core/command/autoRequire.lua | 4c27c07421210980d180fa2e96134d1dac0fec06e03edb80f0dd52ad8a8b76bc |
| server/script/core/command/exportDocument.lua | 6e7bc7617772543f9a22985024dbaf6bfdcffdc2e7dd92984c9da8c9fab9d69d |
| server/script/core/command/getConfig.lua | 05e57030d733daa4e46779bf5ad6ca23ad62b3f346b086cbac75eaed9a58e5eb |
| server/script/core/command/jsonToLua.lua | 360c325e5398657b87c7c0368bce661acf6addab1bae2ad57533cacccdf56f7c |
| server/script/core/command/reloadFFIMeta.lua | 1a5390f79308400c67e51ec066a10edf2059c6f285230ff6c9e4c84139157f4e |
| server/script/core/command/removeSpace.lua | e560db3d4b6bb93c3229816f72a00a47faf5919120e21d5d9220dea7880c36fe |
| server/script/core/command/setConfig.lua | f03bbeedc853bdfb9706aabb5ac963362d0d8e6a53a88d8239cbb302f6e94520 |
| server/script/core/command/solve.lua | 510ed3be7c919d848eb948f995e1134c7d4d28ad6ac154e2dda0c01c856b0af0 |
| server/script/core/completion/auto-require.lua | 1e70c86fefa06448ee0e2cd6914f51f65246550c153b58e2400f791c4ecd372e |
| server/script/core/completion/completion.lua | ffc24132cf26302bcd60e39b32ea94db13d1d5e96b0dc65226516f0b3346ba0c |
| server/script/core/completion/init.lua | 9af841de871337bdc9ea54c2a1f70ca4cce7f9f56b596112b105c5ef7babdba1 |
| server/script/core/completion/keyword.lua | a296178121f472c32b1fb5c292fb0e24adb74ccefd5a127004998bfc099c5430 |
| server/script/core/completion/postfix.lua | 0dfb0693764eee0508189beb45423bbd40d430c74b7391ef00ebdf06c8380f06 |
| server/script/core/definition.lua | 9396b6516060e52082b1f2a4c0b90417513e277a8aada132b3b7036b55651a78 |
| server/script/core/diagnostics/ambiguity-1.lua | e77ed5b5d144ce2b3bdd0c1b9348c35a532d4cc06159c577dff7acff87b42bf2 |
| server/script/core/diagnostics/assign-type-mismatch.lua | 3ad7b0400102e9196185d1ba1eeee0a11f8d30bf2d5452cc40536104f96ea634 |
| server/script/core/diagnostics/await-in-sync.lua | 5cfcf8218de600ab38bfa70b3341e74242a1f6da8c74b5854267226fe9c7e06d |
| server/script/core/diagnostics/cast-local-type.lua | 8e8b5ac2d5c9d594c39c144239c752b75708259bb4c3c1828eb052bb2dea4591 |
| server/script/core/diagnostics/cast-type-mismatch.lua | c7fab45ce7583dd50426624b404ee12e620e5fc43c2c81b0ec51ea39dc81ebcf |
| server/script/core/diagnostics/circle-doc-class.lua | e6754db31790d46ecc40e785b3ef198318e19ea01ba1ad6d5ac650c2363fb635 |
| server/script/core/diagnostics/close-non-object.lua | 19326ab2f761285336dab253181027c55398637525604a39c9c911cff28c2d0b |
| server/script/core/diagnostics/code-after-break.lua | b95399832f0abfff115ed1260f49f481775d70e691b541a303d33c446e32a5d7 |
| server/script/core/diagnostics/codestyle-check.lua | 9dc473217884b5c1719cc022c34acaac6b3dced58bc0ee4b16b44727d2ed2d9d |
| server/script/core/diagnostics/count-down-loop.lua | f8fc2280f3b2c61d090cc21e659d2b39d4f2f4cab7a9eb5dc86dbbeca9b77202 |
| server/script/core/diagnostics/deprecated.lua | 500651ac3bfea7bb011ef2f6027cda80ccced563fd22d50ab8e97b7227d4d585 |
| server/script/core/diagnostics/different-requires.lua | d768389c738b833d8b5605e553e3f6c569a279406c2fbb4a0e5203703844f1fb |
| server/script/core/diagnostics/discard-returns.lua | 36fa7f9a7f1ff52b5a4ea7973ad330da15544109e5d244df285f67b750e25cba |
| server/script/core/diagnostics/doc-field-no-class.lua | 0918cc59064520c2579b988959f049c4e62ab6bc25859ed8293baf67ddad45d8 |
| server/script/core/diagnostics/duplicate-doc-alias.lua | 634a81459f37cbc1ec41fff2ec51628e39148aa9dbaa59a6417140800dc2a9c9 |
| server/script/core/diagnostics/duplicate-doc-field.lua | 42f9672e3f2f680a3645a38a1e0ed06b7a12a47a26676a37bd27bcea9a7db802 |
| server/script/core/diagnostics/duplicate-doc-param.lua | f373700b29447d07e007304f36525efc3b389198d319e67100c651c6b6fc0c22 |
| server/script/core/diagnostics/duplicate-index.lua | ad164cd11473112261a38e0148001ebf5e1d85b70a27bf90849d8cc08395fe3b |
| server/script/core/diagnostics/duplicate-set-field.lua | 9dfee2002f7fe70a219929f0f91a03d35b18b468f5e1c8494f4ee306c794d41b |
| server/script/core/diagnostics/empty-block.lua | fa5343845c7829d3089fb401a7e99f1c753b080285ad407f211f98e063f3b175 |
| server/script/core/diagnostics/global-element.lua | ac5715e18f24773d53c32b2df0d06f266a550c99c6dcc49f60d8a3bbc13be8cb |
| server/script/core/diagnostics/global-in-nil-env.lua | ee3b98c7d1b0be3d2e3351a2ce5c89d0ec3737f3ae1450b142385b3f4e36fcdf |
| server/script/core/diagnostics/helper/missing-doc-helper.lua | f0c8e8c802b4e0e5d8f8362f3e23b9d13d066a6779f030315c224d72aa9eb2b2 |
| server/script/core/diagnostics/incomplete-signature-doc.lua | 1987f31b04bccd7d5eab031638b9583a5a3ef8f0f7ba03311cf8a1d9b1f179c6 |
| server/script/core/diagnostics/init.lua | a4b6bbc059fe791455f668e37a0a82e167505f61e32f02d3514daa1275490af6 |
| server/script/core/diagnostics/inject-field.lua | 2b5a101c331b6b1d1cf0a4828c005d53c859140b2ff9920cf468c6d379540226 |
| server/script/core/diagnostics/invisible.lua | 63f2ab1cdb6cf58d7ae1d3806854c1f4af8fb876690a3752c7a555694820c22a |
| server/script/core/diagnostics/lowercase-global.lua | 497f14efae8157f3d6815b3da092968f28810673aaa743e6461e08a1e7c0cec7 |
| server/script/core/diagnostics/missing-fields.lua | 8a0a38b2dcca811df3d279630e6b17932eaedccb3588a285c80ce4e6caa75cad |
| server/script/core/diagnostics/missing-global-doc.lua | 04f3a96850f31c80c2625bc6529c4c1a4c1029802c96296e0b309266df3a3833 |
| server/script/core/diagnostics/missing-local-export-doc.lua | 0bee1be3212df4a5e847276560bca121d5675c63b1cccdb7da0cc94d936f0554 |
| server/script/core/diagnostics/missing-parameter.lua | 2f2c2bbafe79e7d970a4a5484f8cddf0a37844c27acfeb81636b211cbd8a982d |
| server/script/core/diagnostics/missing-return-value.lua | 8a9e0c7c43f165dc407f8e1c692a4b419984f412d28616abd0d14f3db1bf45b7 |
| server/script/core/diagnostics/missing-return.lua | 67032394466449d2c36050644ca72a461ca329123b530cd07a03c00ec56b8428 |
| server/script/core/diagnostics/name-style-check.lua | a176850285bbf1a9fce40687940a8e886ee4653785d8a603701ac708a9dfb2fe |
| server/script/core/diagnostics/need-check-nil.lua | 2c68f6568396c6b09c75c814fc54d95959f61c6c9cb1f51e273e8cc3bf01ece6 |
| server/script/core/diagnostics/newfield-call.lua | 59b4052ec20bb6aed93fa85942c794c042a77e3cb6b33b61784450aa8b633696 |
| server/script/core/diagnostics/newline-call.lua | e8877001f35300e98daffeae0276b00d56837c1795f706e4d81867c4fc79a6c5 |
| server/script/core/diagnostics/no-unknown.lua | 1cc7de00647defdecf3fd1a9e68d66f17ca63f26b5f4452cc3cd0a0c874f851e |
| server/script/core/diagnostics/not-yieldable.lua | 44eef8bec9ebb78f6b8cbc6be4b3fe60a178d75e33ac36b5f33c8a95d22d6923 |
| server/script/core/diagnostics/param-type-mismatch.lua | e444a229a78e98decf32eec89da9dfa81de74356193a1886be2e03395c43e0ac |
| server/script/core/diagnostics/redefined-local.lua | 19f9ed8978cc670403220e9e44955883a6693d0a74e844e0db794dc2e8dbf63c |
| server/script/core/diagnostics/redundant-parameter.lua | 7351f4453e848555a31b37546f3e38a2681f795938e028d63a58d0ff29aeb9b2 |
| server/script/core/diagnostics/redundant-return-value.lua | f225632f1341437ac4dcbc90b077c2e6e49bb05f1f4e4c0303511ab73e5bd4b0 |
| server/script/core/diagnostics/redundant-return.lua | fc126bc6529dce2d8423a21b0e948e1ee494a0e70e426bb79cbe039067fbe1c4 |
| server/script/core/diagnostics/redundant-value.lua | 020cec80f64e6b968b238230e00986da255623ef6b6b8ae23d2fba6ac7260a97 |
| server/script/core/diagnostics/return-type-mismatch.lua | cab8689a7c428a8dd565a7c93f158b884e4a048bb37a7e715010e7724fdd95dc |
| server/script/core/diagnostics/spell-check.lua | 103a6dca3f8839c5ba85913a66490e88ff1ef30b8a7be41d4696bca71b1db243 |
| server/script/core/diagnostics/trailing-space.lua | 792f7964dbcc9f6888f99ed9a169cebd14a317dc74b5bc3f46863ed207fca644 |
| server/script/core/diagnostics/unbalanced-assignments.lua | e2475dbea387bd9fdd7560af901262b4ebe7957633a31008136f6d3541bf96be |
| server/script/core/diagnostics/undefined-doc-class.lua | 29ecb08ac71065e13c8b2ddb2298970aebc93daf46fa8c86001c85b418f0530f |
| server/script/core/diagnostics/undefined-doc-name.lua | 379dae4def4b3f551b387b4f3ee94be9538c4df3db5434b037f49216b1fa7143 |
| server/script/core/diagnostics/undefined-doc-param.lua | 50f9a78fb4d7fd86a989dbf80f9410c7dedbeea89eb7470fff4067ea1c868ad3 |
| server/script/core/diagnostics/undefined-env-child.lua | b3ebe97e64e5bfa8c032a10b77b1320d2bc2679b5354c85430c14d13ceb8e4d3 |
| server/script/core/diagnostics/undefined-field.lua | 37f3b0903e2d60fb470193d847ad19425ac95c230617ff9e5499bf31bf012598 |
| server/script/core/diagnostics/undefined-global.lua | 138b21baa30dbb511361f4bfdb8a2c519e0d9df366eb6c8ea40c1c1fa47e3c34 |
| server/script/core/diagnostics/unknown-cast-variable.lua | bf94f7bb51efd21129830e8a42ee3619a99fc0038478f0ba867e1fc3416094ae |
| server/script/core/diagnostics/unknown-diag-code.lua | bf887d72f73605edeb9f8b408f69e81e821265d3d78a3c04f05dc5d2633ece1f |
| server/script/core/diagnostics/unknown-operator.lua | 84071eb36dfb532b8982c6f5b914709fb0652674890048886f3dfb75d56f5ef9 |
| server/script/core/diagnostics/unnecessary-assert.lua | bc699c23b130abd14aa99247de7a01965b4c85955a3826a48715051c2481eabe |
| server/script/core/diagnostics/unreachable-code.lua | 2a1561406eb9cb57d290ac3f5fc370cba995f5fb2d96cd1f7e574cda73423b04 |
| server/script/core/diagnostics/unused-function.lua | 0b81370ad6ff2ccad9dd34436f0ef9804bc93419144a70ff055e20ba7b4df675 |
| server/script/core/diagnostics/unused-label.lua | 129f10c80fd56b08554a9bd1f564e8e6ac09076143f113a9d794d11d810f4ec3 |
| server/script/core/diagnostics/unused-local.lua | 98ea0e6b805e77ca9b4861f27118c4ab43e57b655bfb32df272304d3cdedb0f2 |
| server/script/core/diagnostics/unused-vararg.lua | b0502d5470353c0e547ee3ba54db9530d82246bac28bccc876acd05d3ee7f53b |
| server/script/core/document-symbol.lua | 36c82acd8410fcaf53fcc1ce88cb568715a105bb85f2b162008be3ab1f143ecf |
| server/script/core/find-source.lua | 11d556fdee356469da5e17558630663b01fa0be81861576ec2756c604604a022 |
| server/script/core/fix-indent.lua | 91d67ee52c2db96c92ef1140812d1c4233f4623d2270d3ee2c54f1dee62ceb2e |
| server/script/core/folding.lua | 32c59a8b9558fe72a7416cb75e234d8d19d778891eddbde74d46379f184ead3c |
| server/script/core/formatting.lua | 0eb6fdf380242ee2d75c72d000723a03097de4bc45c95ee278c87dbb94c817d3 |
| server/script/core/highlight.lua | 0eb6bef4a6cc011cd51e28c9199a19255c4641ec071bc7d116cecc213b487ee4 |
| server/script/core/hint.lua | 76ddb6b17afd1052ce2d5e47f6bea485457b9dd73607ea80f52a7d828ce766c7 |
| server/script/core/hover/args.lua | 721697855f2fb42a5e712ae928e9f99a89bd6fdee8f1e8040b014a9b2cd1d810 |
| server/script/core/hover/description.lua | 3bdd3c0fc8065937ee9ea9089f064714db91280e84900a46b56826256ce1b0d4 |
| server/script/core/hover/init.lua | fd83ee237a65f9902e23519f38d4546d9b1e1a14a95653010263968a9cbb34e7 |
| server/script/core/hover/label.lua | d8563b53eac80d5b7c98e4a1f157869f10c07e3076521db5def72311d19b8de1 |
| server/script/core/hover/name.lua | 8b98736cc86f88c707c4679d79bcc067690ab130749503a83146282826a24144 |
| server/script/core/hover/return.lua | 0317ac5954cd1e7f1fd04e8fd008ab01a02f77becc6d58801f7aa78c4fee7885 |
| server/script/core/hover/table.lua | a85485fd03f02c12270977200aab163cb3d8cf87fa4406c7deaaad22178da288 |
| server/script/core/implementation.lua | c51b7ad8d77e7f96c8f3d2d1d3aeefa78caee53b0e12cf202669bcfb3eb38287 |
| server/script/core/jump-source.lua | 368789b82a13e174f36597cc31af3f621603ba59a5a5b209910c43526ccb37c1 |
| server/script/core/look-backward.lua | 738f6f24548369b9a0e7725e6c643b1d1944ae3869ab5b172a5617b885bb19bf |
| server/script/core/matchkey.lua | f5df841499a7877a3e563fbed062512926f93b1dccc108cfacedd67acd741cc9 |
| server/script/core/modifyRequirePath.lua | 0c816b42b16df40e7d09325c9c5414631623506200e0c33a922335be85c1f770 |
| server/script/core/rangeformatting.lua | f3cacba1f3b7d063a81c7938537a3504d1bcfc20937046bbbff60876fbcaf325 |
| server/script/core/reference.lua | c62d2d1043cd6efe7017bc75109afd4b2b5d4f21ce60584913a754752beac2b1 |
| server/script/core/rename.lua | 91e1fde6a64fb9f199d0932db5ac1c0fc768e484b2a0d87a235227e03facd3e2 |
| server/script/core/semantic-tokens.lua | ce66a2d06e32394336838f938fbd48cd25b35ca6a6802cd9e8ec2ab6fd77fbbd |
| server/script/core/signature.lua | e82a9c27b2bfe8e514f7dcd25a927e825458979feff5c2f4a7fa5d6773d47be1 |
| server/script/core/substring.lua | e4c1316e4aef56a0b54f7c6c6868c7841ce03c73510bb157b7f93eed5f9698c7 |
| server/script/core/type-definition.lua | d8de1a1697abce3479151fe7887caf80443f91855c47fe02387240aa002b1bce |
| server/script/core/type-formatting.lua | 1d77db7aa1b594146be23fadeec24c14ddb2ba489356e332c8488685129eafdd |
| server/script/core/view/psi-select.lua | 43cf9db4d9fd3a13ec4a6ce325dde9f3b09352e13fa319be7c6460052c313686 |
| server/script/core/view/psi-view.lua | 34b70c19ea109ad4308cc9ef4aeb8b91a8c14265e12dbf58b1c63d04c186a9d3 |
| server/script/core/workspace-symbol.lua | 1956a893c86812aa7c025538227b0f7b6be59374fdc9457f6ee1ace746e858f7 |
| server/script/doctor.lua | 755fe22dfc59d8fc66d56c0c51868a85ecdbbc2f5cf3a5fa9a11a6143a6db2b9 |
| server/script/encoder/ansi.lua | 3c2504badda25ed45187758f941a927b9d57950dec4f89c0156b935b15cf4d48 |
| server/script/encoder/init.lua | 5e1bc6e01e7bb8e07ff5da5c8c19eca277100623f5cbb2826f245901d19ce147 |
| server/script/encoder/utf16.lua | ec20d0de53229733060c99780e536379d4db18c7c6af46cd25de8655a4b879fc |
| server/script/file-uri.lua | 83b40427f6d13935d6476e12829c7b84e0b0be6a74827c0205aa15f83114a41c |
| server/script/files.lua | 7e0eed1facb4bf6b6fba2a62797e404d69b2de0a0b74669e8bff17072a9f4a74 |
| server/script/filewatch.lua | b431b145d96b6ebf080e0f3989886d1dc50353a212bd5189d7e00c07ca128903 |
| server/script/fs-utility.lua | 9494d7cc981ef832b29c71e827733eceffef6447c1cea99c291dcccbbc2b5c61 |
| server/script/gc.lua | 47c753345f2f40b30c459737127d0d8c7d03f170359125d549bfb3d684dece7a |
| server/script/glob/gitignore.lua | 0cbee6173ecf4376e849d781181f30899556d741fd34c5077e7c02570f706931 |
| server/script/glob/glob.lua | 22d926ac66e6fb9870371d4d701832a8c1d0d4937e713b394580ea2779760112 |
| server/script/glob/init.lua | 151b0445ff82d71b101ecdb3e0e809407df8a2161a736c904be8f0378c293bea |
| server/script/glob/matcher.lua | 152cfcd402398e7914ed783fa0d046a1b916fc5cc8b48de0f26dd783fed75842 |
| server/script/global.d.lua | ef32b8d835594b707eb51cf95392bc6b905eb4b7dc9f7c106abe53c44109942a |
| server/script/inspect.lua | 22c736c1f74572ff9e3f676508043654e056cef5c7243656243a5fb1a23ddfd7 |
| server/script/json-beautify.lua | acd5f7931a37a6b80ee5f784699e371a6d2e088b8bc166f2e0c073a7a1ee8524 |
| server/script/json-edit.lua | 4bc1ffe7e6f4cd2be6a9cbbc55a3d080ef22f8c49775f0cd78b8f6d095478f89 |
| server/script/json.lua | 96a650e442179bb0cf049ae75ecb5db6ff1667b54f0a5360f9f0fb1c5b94fed9 |
| server/script/jsonc.lua | a99334325c6ac9619e3f9f0bf7645c76d59812754689dd8936472fb119dcdc53 |
| server/script/jsonrpc.lua | b55169819225a719b900b69f6fff9e19a9d5f4b68eae1f0ae0e9f166b905f89d |
| server/script/language.lua | 48c80cead25ecad44122c9aa2a3647d4448759645c3a59311b8cf0ceaa00f62c |
| server/script/lazy-cacher.lua | aa316d79bec0f2003d75c634fdbc6c7c284273fe420a0fb6197dd0b6ae25dcb5 |
| server/script/lazytable.lua | 5f7208b205a62aa759e4fd151429ba0b4b7f8d020228a517fbdcdce6f7c09429 |
| server/script/lclient.lua | 164dfcb7b0dcb3296bcc100cf687ddae2093a25fac02e8fb9ae1a9f885fcbdb4 |
| server/script/library.lua | d2faadd27590dd27e22d64e7007f4a5835fbe0df2b99f1768e2ff48e14bd2816 |
| server/script/linked-table.lua | c8d8ebbe665b7c75d7a01821d1e4bc048c461226a3c3da6ee8623f51ae6a8ab7 |
| server/script/locale-loader.lua | 05db4cb67ecd87ae136461e672a6395d5af6c7050e68505b8167025c6573a04f |
| server/script/log.lua | 2f5aaba497fe090119edfb50b0de4e8d424ba974b8f055eeac6959706e6d60af |
| server/script/meta/bee/channel.lua | 856d22eab095861f6b653732bc5daabe2acb12b13ae5d79687c14cbcf1ee2f71 |
| server/script/meta/bee/filesystem.lua | 2b7ce6728533cb0a151f5377e807bf5cad9e52942929eea458df952938a12a38 |
| server/script/meta/bee/filewatch.lua | ac9cf7a7ee82a9f20c894994683f9b91607c911458ee2b38c51c3e8668df2c87 |
| server/script/meta/bee/select.lua | 5e598974ec65160db1a0faac9e2ee01e82b6b212c8d6c1f2deab8cbbd8e422b4 |
| server/script/meta/bee/socket.lua | efcc069a38cb92f771fef6e23781e5954b04cbc87a380bc74889d40df33a2ebb |
| server/script/meta/bee/sys.lua | e49bbfbf11b114c6f9e6b8d190a6dd897e3b638e022996ade773f781ef718faf |
| server/script/meta/bee/thread.lua | ceb750ba3f6bdd5d0498a71b304e06e32702939a52346e4fb060425fa0a2ef07 |
| server/script/parser/compile.lua | 1180f1e20ef3e3c3135e8098cc4307d6ab41701b81a358c3212d30a3d0b62c99 |
| server/script/parser/guide.lua | 76f7d85fcb422f3c9434441594238ffd0016ffb8d7204a6576f46deec8e44322 |
| server/script/parser/init.lua | 59807650a93313d46afe0c91dbdb667312f3a809f6be9cd07a2ffbd0a9705e71 |
| server/script/parser/lines.lua | 7079ecfb15ba6cef4f1d0185160a6067731d27e46dad99116bddd8b6ce2fe3c9 |
| server/script/parser/luadoc.lua | 586241ee9c5d7cc4c3fa0c754fd9f01086bc5fc9c38d07ce8625f136abbf510e |
| server/script/parser/relabel.lua | 4852217d59224d054f898e45bcd356f14636c73929dbed4e40ceee3f208b4741 |
| server/script/parser/tokens.lua | 1426c1c9a3a43da35349658f988aecbba9bd6431e44f263795b9ebf890535e79 |
| server/script/plugin.lua | 96ffb9522cac3413cc6d0d861545ec41d4b925c44673b46077e2feaa6372cd4f |
| server/script/plugins/astHelper.lua | de4dda147ff5fc1a50fb4a7d24d8ce8f4cfa3730ce6d4c961a17879f2d53bbbc |
| server/script/plugins/ffi/c-parser/c99.lua | 2c49fc8e71cc5ec42d0982d7906cb2019207cd1f65ac9e90726f23ca8127ff7f |
| server/script/plugins/ffi/c-parser/cdefines.lua | a6bd9e066ba19dc23e9e7e9393852a1013dfb32461511b0c63c144e97939530a |
| server/script/plugins/ffi/c-parser/cdriver.lua | de32f0c28062c644b442590d161d016516ad617e68e9abba5e2c3391b185f881 |
| server/script/plugins/ffi/c-parser/cpp.lua | 7d334a89b457b393c605e26e5455082f989b2edf69f2ffd7ab186b4e458f953a |
| server/script/plugins/ffi/c-parser/ctypes.lua | 6a93dd16348985eee852c858e9198441dbd907abfd75a618770bafb0c1692471 |
| server/script/plugins/ffi/c-parser/typed.lua | ea9a42421088bea25c8b5b29b66eb40ba6674cf89e8b3846121fe0c543b67a6b |
| server/script/plugins/ffi/c-parser/util.lua | 251fd10fcb0eff0b1b4ef276ec054799b6951bd3ad4a0a47d48bba01fffba584 |
| server/script/plugins/ffi/cdefRerence.lua | d35d0f7dccaee51442815dafebc2c4ed4975aeaf3da8c57fd5128c88850f8c89 |
| server/script/plugins/ffi/init.lua | 841a4b9e8e1b662520123af31f04be56ad1f5b75db1a41daeb369f3df0e0e725 |
| server/script/plugins/ffi/searchCode.lua | f41dd4171e60dc7341c80f8b1fe71a70c011bdd9bc89d75211d2b8ea8b47316e |
| server/script/plugins/init.lua | ca8aec27290d4da168005c6a965faade14d51b8ab8e2ef8473b922e3d9f8e5d8 |
| server/script/plugins/nodeHelper.lua | ea21e3c74d487ec87a5b7ac60959d367ef198ccad44a04b4b15f8c1909a1f8f7 |
| server/script/progress.lua | 9406c66f6baa4bced22197dbafc5b7d45f3948c5180b62844e18e4d4685c3022 |
| server/script/proto/converter.lua | 542110d8185d8e471352375326959587839922f3f32c0e0c465b389c237fe987 |
| server/script/proto/define.lua | 6039dce49c3349eca43612ea55a567f06eae19f38c6b8c1088fe642e35d63246 |
| server/script/proto/diagnostic.lua | 7aad51be02a394d31239350ed795955ae5a3d946d49811a43f2145db97e6f020 |
| server/script/proto/init.lua | 0affd3c34305941c526d3393599014c01030f07bd812e5e8fb5304430709c5d3 |
| server/script/proto/proto.lua | e894c00b883ca2264f9d4b39f364e466f2d7616cf40cf93b72b6102055f4d369 |
| server/script/provider/build-meta.lua | dc62c5921a014b0c8bcb9d58b4ce57404f783fdafe1f642b9263473d1ee0f305 |
| server/script/provider/capability.lua | 3c484d2dd345ead8a6624c254c5037111d18f1727893d6857ccd025e34cf6e56 |
| server/script/provider/code-lens.lua | 665928e84474c456088d45461a34dd9ec7f0b54cc5818ec1c83b7427f13602fc |
| server/script/provider/completion.lua | dcf473f0fb721f6c3c1c244a164b2dddb14041bf550ac2103248d666c9d39a62 |
| server/script/provider/diagnostic.lua | da79e6a6709bdf4db1a3f657d94396728a7aabb28e83cc3eb5dd724f9a134848 |
| server/script/provider/formatting.lua | cd7e787944bd17be4733c976df2cd18cd73e8ee04e1605c271dbf44ab2a86b8d |
| server/script/provider/init.lua | ba0a0d8ba16a54ba9a62ba322fa63b5ac3d3367240d68bb5369699d4a684719e |
| server/script/provider/inlay-hint.lua | da4387d629b50a8b76df11e4ee4309918a2ae0d5d5b0469a6189a285e96437af |
| server/script/provider/language-configuration.lua | 48929fccd87f575c907e325ad77d194b27e22694ff7f7a6caa2cbfdd1bdf4943 |
| server/script/provider/markdown.lua | 2c64872e31b95d4d4607739f431f842daa0cb85ccb61109974ab570f4a756127 |
| server/script/provider/name-style.lua | c7d482b4a7c21e4378d048516dc23bca5dbd1059290787a0189247818f5ae7bd |
| server/script/provider/provider.lua | 533646f2f8ebac1405bb2f582007fa79fd80cd77758031711f4c5f1aedd8f277 |
| server/script/provider/semantic-tokens.lua | fc8a3f8fdec54d594b8659f1857cbd200bc2d880a69e75d19f6ab9fba9e71e7e |
| server/script/provider/spell.lua | b1f2fd0dba6d5e8678332739a8b04b704c8aff4370975fcd6790ab594c700c88 |
| server/script/pub/init.lua | 127df6b87ba21168c5c949c0558c08846fe789c8c3853686b9f1cbd5699200af |
| server/script/pub/pub.lua | bfa9663abe9f352e541b69a1a369eb34aba76cccede471613dc68e6f80034092 |
| server/script/pub/report.lua | 84e81305200bb453ea5d5c1264e681c6d7f169235f66a33aade9932a06a15f90 |
| server/script/SDBMHash.lua | f519d13047af6aedbcf3e729911b8264224c8e345c1d469d1b6933026b660cbc |
| server/script/service/init.lua | b16c516208622dffe717cc7c39ab662054fb4918cda9e2b6ab55f4012155944c |
| server/script/service/net.lua | c0ee6f50ad69bd2ad138dc2d553af5fdccbab3fb3e41a652e5ab52a649d5415d |
| server/script/service/service.lua | b5a4e590a5e1dfc0b95628d4556f646c6fb69576c92a944620831f750baa5f23 |
| server/script/string-merger.lua | 1a0766fb03461cbd4c847728eef746207046195836a273e0cc03f6dcbd5b7107 |
| server/script/text-merger.lua | 6c56f18b961e1f9ca22b823b2f2fa531c5dc28278f3882d6e7da3affc5657114 |
| server/script/timer.lua | b530f39f597445ad406a6e6f4fac5168a841ed616514a2d2aba0a6638a70fa0f |
| server/script/tracy.lua | 0a0c49e065473405db188e1d0daa8cef3965607bfed2fc7bdfa1662e6425e662 |
| server/script/utility.lua | 14cedda04421b7c1da11e56cca5348dd211286ae6161f43319a019d30072ffe3 |
| server/script/version.lua | cfbc26455a193f04b517fa95bdc7a4a1524c70e984141d3dba65af0e8dbe882c |
| server/script/vm/compiler.lua | 9b47c4fb7c3407a25c34d7da571e4abd708be63426a2f24af86bedee75f574ba |
| server/script/vm/def.lua | c779f452ca432e054aa9703ccceb3f75047cf65fe6df286291dbf7c543da2880 |
| server/script/vm/doc.lua | bad13535349b3846950871b2f953cba8ac9bb6b153afce5c2be95cdb5e284500 |
| server/script/vm/field.lua | 353a3fc119818494e9686b9d3c4513903b0b512fbbb34a3a5870c183953db6f9 |
| server/script/vm/function.lua | 0ac9dcf65217bfa3546462e9c0b766364227f572809474db2ca67db73ac1a42c |
| server/script/vm/generic.lua | 6b367ec9a3fe5d9da91818e50b48bbc01c4dc9809af88120782c3a34f6c201e8 |
| server/script/vm/global.lua | b12f11b7a4e87a9a93e975bc6be18457a486bd06b8aab42c513c005b85b7d388 |
| server/script/vm/infer.lua | 402ab856924959cba5cf061ca2652fb305f7ebe1ebf702d3b757b8e4e6dcc833 |
| server/script/vm/init.lua | 55086166cc20b312b83b66ccdfc84c9166250e5c08a5dc626196f31df4257773 |
| server/script/vm/library.lua | 8aa6064d8c644c909aa0ca07fef73f3ca0b041cc1f8a5141a335e40987ee8424 |
| server/script/vm/node.lua | 80706d2d8e57b9d2f9d10f2b82f0b2d5f3682813c52104f73ab20d4816da7410 |
| server/script/vm/operator.lua | d7368108627476335e14d0f12e5c49e17c47455df16f84768710be64a38e7d70 |
| server/script/vm/precompile.lua | 41b40ca8c83a0f1ff5524ce318d078bff4c88a251aa1cdd0613afc706209b7aa |
| server/script/vm/ref.lua | a97e3f85d7b49e9f615816335daafaca652c98133be6cfdebc68a3b07678b73b |
| server/script/vm/sign.lua | de5430b8046b34a8c6e43b929d18d33537082ade012f7e82749d9df08fe3dd12 |
| server/script/vm/tracer.lua | 5e6e81a6a6ac13529ef804865092c299918205c59631722f2b2c8af1e0ca03a2 |
| server/script/vm/type.lua | fe4ddd1602971d84c18d0ac3e6bb93638a6b813a1b991820ea6189efc6cf20fd |
| server/script/vm/value.lua | 2d9a15667302583a61b3459bb8ed7924df356cafc679da3383ac0f07964d1c4d |
| server/script/vm/variable.lua | ce21a97122d79e9567d86454009864e9a95a593477e38fe4b27c35a6f814ff73 |
| server/script/vm/visible.lua | f9a6acdf3fe6788ef2f0c1d709127c3e14da99821d6abb236d212fc0b1dabc9d |
| server/script/vm/vm.lua | 509fbaade9d345b50d413b0f4cc14cca84085578a656b0fddf52f15002c398e3 |
| server/script/without-check-nil.lua | 458e44b1c77f9b9ec8c73d70d11ad02f61621f29490213554e7e78166a886db4 |
| server/script/workspace/init.lua | f5113de49c61aa38c39234cd879a2d23e5dcb42eb06b1db1b43d05a76f7e1d73 |
| server/script/workspace/loading.lua | a897d4f5a3003a5105b9cc0d786db39bc6c0ebe983133082d37a97a4779f8b12 |
| server/script/workspace/require-path.lua | deb91a9a5cc516464d9673ed9afa8a8ecf6a358eb719567e9498886e9bc4e537 |
| server/script/workspace/scope.lua | a3da9f34255c5751126782b050a86133c94fadbc9fd207339ff838b3f356d3b2 |
| server/script/workspace/workspace.lua | 1fcda274150b2bce3ceaf9af8edc74789a62f8de0a3a86a3324a83e7ace8382f |

## 附录 E：源码摘录许可证

下文保留所摘录服务端源码随附的 MIT 许可。正文中的 CodeOutline 迁移方案是研究建议，不是 LuaLS 官方承诺。

```text
MIT License

Copyright (c) 2018 最萌小汐

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
