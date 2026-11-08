# rikuesto 设计文档（架构与技术选型）

> 本文档只描述设计，不含实现代码。目标：在「非必要不引入外部模块」的约束下，用 Neovim 原生能力 + 系统已有工具，实现一个严格遵循 `.http` 文件规范（<https://http-files.org/>）的 HTTP Client 插件。

---

## 1. 目标与范围

### 1.1 必须实现（来自 README）

| # | 能力 | 说明 |
|---|------|------|
| F1 | 语法解析与高亮 | 依赖 treesitter 的 `http` parser（用户已通过 `romus204/tree-sitter-manager.nvim` 安装） |
| F2 | 真实请求 | 解析 `.http` 文件 → 转换为合法 `curl` 调用 → 执行 |
| F3 | 格式化 | 以清晰结构查看/重排请求 |
| F4 | 严格遵循规范 | 参考 `https://http-files.org/guides/introduction` 及其 spec 页面 |
| F5 | 环境变量 | 默认 `%LOCALAPPDATA%\nvim\rikuesto\env.json`，JSON，路径可覆写；`global.env` 为默认 profile，`global.var` 为可被同名 profile 覆盖的全局变量 |
| F6 | JS 脚本解析与执行 | `.http` 中的 `javascript`（pre-request / response handler），要求轻量、尽量复用已有运行时 |
| F7 | 复制为 curl | 命令 + 快捷键，把当前请求转成 curl 命令字符串 |

### 1.2 明确不做（v1 边界）

- 不做 GUI/Postman 集合导入导出（可后续增量）。
- 不做 GraphQL/WebSocket/gRPC 的 **协议级** 特化（GraphQL 仅作为 body 高亮与普通 HTTP 发送）。
- 不实现 Node.js 生态的 `require('assert')` 之类带依赖的脚本能力；只提供规范里定义的 `client/response/request` 沙箱 API 子集。
- 不做 LSP；补全只做可选的 `omnifunc`（变量名/头部名/命名请求）。
- 不引入 luarocks / plenary / 任何第三方 Lua 库。

### 1.3 合规原则（「非必要不引入外部模块」的落地方式）

1. **运行时依赖全部是「系统已有的可执行文件」**，且分层可选：
   - `curl`（必需，执行请求）
   - `jq`（可选，JSON body 格式化；缺失时用内置保序 printer）
   - `oxfmt`（可选，JS 脚本块格式化；缺失时原样保留）
   - `node` 或 `deno`（可选，仅 JS 脚本执行需要）
   无一个是 Lua/npm 包，不随插件分发，不进 `package.path`。
2. Lua 侧 0 第三方依赖：JSON 用 `vim.json`，子进程用 `vim.system`，文件系统用 `vim.fs`/`vim.uv`，高亮用 treesitter。
3. **所有第三方插件集成（conform / fzf-lua / blink.cmp）都是「可选适配层」**：`pcall(require, ...)` 探测，缺失即降级，不影响主流程。
4. JS 运行时侧不 npm install，只分发一个自写的单文件 harness（`js/harness.mjs`），属插件自身代码。

---

## 2. 环境基线（已实测）

| 组件 | 版本/位置 | 影响 |
|------|-----------|------|
| Neovim | 0.12.6 | 可用 `vim.system`、`vim.json`、`vim.treesitter`、`vim.uv`、`vim.fs`、`nvim --headless -l` 跑测试 |
| curl | 8.21.0（`%SystemRoot%\system32\curl.exe`，Schannel 后端） | 支持 `--data-binary`、`--url-query`、`--write-out '%{json}'`、`--compressed` |
| node | 26.13.0 | `--permission` 已是 **Stability 2（非实验）**；内置 `crypto`/`node:` 前缀。实测：entry 脚本可跑、**兄弟模块 `import` 需 `--allow-fs-read`**、`child_process` 与 fs 写被拦、**`process.env` 不被拦** |
| deno | 2.9.8 | 默认全禁（fs/net/env/run），实测 `fetch` 抛 `NotCapable`；⚠️ **无 `--no-net` 这种写法**（会 ``error: unexpected argument``），只能用 `--deny-*` 或啥都不加 |
| treesitter `http` parser | `%LOCALAPPDATA%\nvim-data\site\parser\http.dll` + `site\queries\http\{highlights,folds,injections}.scm` | 语法高亮/折叠/注入（`json_body`→json、`script`→javascript）**已可开箱使用** |
| jq | 1.8.2（`WinGet\Links\jq.exe`） | **JSON body 格式化直接复用**：保序、保留大整数/`1.0`/`-0` 字面量（实测 `1234567890123456789` 不被转成 double）、拒收尾逗号与注释（fail-soft 依据）。字面量保持靠 decnum 后端，**有个 `have_decnum` 内建可探测**（见 §9.3-1 的 runtime probe） |
| oxfmt | 0.75.0（pnpm shim `oxfmt.CMD`） | **JS 脚本块格式化直接复用**：支持 `--stdin-filepath` + stdin/stdout，实测 78ms/次。官方声称支持 JSON/JSONC/JSON5，但实测会把单行输入的小对象**压缩成单行**（`"nested": { "deep": { "k": "v" } }`）→ **不用于 body**（见 §9.1） |
| conform.nvim | 已安装，且 `formatters_by_ft` 已配 `http = { "kulala-fmt" }` | 格式化需考虑与 conform 共存：rikuesto 作为原生 formatter 注册进去，而不是抢 buffer 写操作 |

> Windows 注意点：不经过 PowerShell/cmd，`vim.system` 直接 exec argv，因此 `curl` 别名（PowerShell 的 `Invoke-WebRequest`）问题、引号转义问题全部消失；但 `CreateProcess` 命令行上限 32767 字符 → 见 §7.6。

---

## 3. 架构总览

```text
                    ┌──────────────────────────────────────────┐
   .http buffer ───▶│  L1  语法层（只读，提示性质）              │
                    │  treesitter: highlights/folds/injections  │
                    │  → 高亮、折叠、body 内嵌 json/js 高亮      │
                    └──────────────────────────────────────────┘
                                     │ 只用于 UI，不用于语义判定
                    ┌────────────────▼─────────────────────────┐
                    │  L2  解析层（自写行式 parser，唯一真源）    │
                    │  block → request → headers/body/scripts   │
                    │  → variables/metadata                     │
                    └────────────────┬─────────────────────────┘
                                     │ Request (Lua table)
                    ┌────────────────▼─────────────────────────┐
                    │  L3  解析上下文层                          │
                    │  variables 求值（优先级/递归/动态变量）      │
                    │  env profile 合并、JS pre-request 变量      │
                    └────────────────┬─────────────────────────┘
                                     │ 已替换 {{}} 的请求快照
                    ┌────────────────▼─────────────────────────┐
                    │  L4  传输层                                │
                    │  curl argv builder → vim.system → 响应解析  │
                    │  （可选）JS response handler               │
                    └────────────────┬─────────────────────────┘
                                     │ Response (Lua table)
                    ┌────────────────▼─────────────────────────┐
                    │  L5  呈现层                                │
                    │  响应 buffer / extmark 状态行 / 测试结果    │
                    └──────────────────────────────────────────┘

   旁路：format（Lua formatter，可被 conform 调用）、curl export（L4 的 argv → 字符串）
```

**关键决策：行式 parser 是语义真源，treesitter 只做展示 + 交叉校验。**

这不是「TS 不能用」，而是**错误恢复语义不匹配**：TS 的错误恢复是为「继续上色」优化的，遇到不支持的语法时它倾向于**编出一个能连上的树**，而不是报错。实测（完整数据见附录 B，脚本见 `docs/experiments/ts-http/`）：

| 用例 | treesitter 结果 | 能否用于执行 |
|---|---|---|
| 常规文件（变量/元数据/多头/JSON body/`> {% %}`/external body） | 全部正确：4 个 request、每头 `name`/`value` 字段、`json_body`、`script` 父节点 `res_handler_script` | ✅ 完全可用 |
| 头值多行续行（JetBrains/httpyac 规范特性） | `X-Long-Header` 值只到 `part1`，续行变 `ERROR` 并**级联破坏后文**：body 的 `"a": 1` 与 `}` 被解析成两个幽灵 request 的 `target_url`。根因在 grammar：`header` 规则是 `name optional(WS) ":" optional(WS) value NL`，**结构上不存在续行分支** | ❌ 会发出 `GET "a": 1` |
| `> {% %}` 紧跟在请求行后（**规范文档里的标准写法**，中间无空行） | 被拆成 **3 个幽灵 request**，`> {%` 与 `%}` 各自成为 `target_url` | ❌ 静默错解析 |
| `> {% %}` / `> ./file.js` **前面有空行** | 正确：`res_handler_script` 含 `path("./handler.js")` | ✅ |
| 隐式 GET（只写 URL 无 method） | `request` 节点 `method=nil` | ✅ 可自行补默认值 |
| body 写成 `{"a":1}`（胖括号后无空白） | 变 `raw_body`，因为 `json_body` 规则是 `/[{\[]\s+/`（**要求首字符后跟空白**） | ⚠️ 高亮/注入会漏；自写 parser 改用 `Content-Type` 判定 |
| `raw_body` / `json_body` 范围 | 尾部把空行一起吞进去 | ⚠️ 需 trim |

**这张表最有价值的一行是第 3 行**：`res_handler_script: seq(">", WS, choice($.script, $.path))` 在 grammar 里**确实存在**，但规范文档示范的写法（`GET url` 下一行直接 `> {%`，见 <https://http-files.org/spec/response-handlers/>）实测会被解析成幽灵 request——**「语法规则存在」≠「实际能解析出来」**。这直接把「读 grammar 推断能力」的路线毙了，也是「先实测再定方案」的理由。

注意第 2、3 行的关键点：**没有可用的 `ERROR` 边界来兜底**——第 3 行连 ERROR 都没有，纯静默错解析。用 TS 做执行，就必须在树上再叠一层启发式补丁（预处理合并续行会让行列映射失真、无法回写格式化；丢弃 `method=nil` 的 request 又会误杀隐式 GET），补丁量不比行式 parser 少，且随 grammar 升级而碎。

因此采用**双解析器**：

1. **行式 parser（主）**：约 400 行，行列精确、可写回、可单测，覆盖 §5 的全部边界，是执行/格式化/导出的唯一输入。
2. **treesitter（辅）**：① 高亮/折叠/注入（免费且好用）；② **交叉校验器**——当我们的 parser 报「结构正常」而 TS 树里出现 `ERROR`/`ERROR` 级联时，在 buffer 上打一条 `information` 诊断「grammar 与本文件不兼容，已按行式解析执行」，既提示用户也不阻塞执行。这样未来 grammar 修好了，我们能立刻受益，而不会被它卡住。
3. **断言式防回归**：`tests/` 里把附录 B 的 3 个失败用例固化为 fixture，任何一个 grammar 版本若修好了它们，交叉校验器会自动不再报警（不写死「TS 一定错」）。

---

## 4. 目录结构

```text
rikuesto/
  plugin/rikuesto.lua            -- 只做 filetype 检测 + 懒加载入口（<10 行）
  lua/rikuesto/
    init.lua                     -- setup(opts) / 公共 API（run/copy_curl/format/...）
    config.lua                   -- 默认配置、校验、合并（vim.tbl_deep_extend）
    health.lua                   -- :checkhealth rikuesto
    commands.lua                 -- :Rikuesto 子命令分发
    keymaps.lua                  -- 默认键位 + 用户覆写
    state.lua                    -- 命名请求响应缓存、全局变量存储、最近一次请求

    util/
      log.lua                    -- ring buffer + :Rikuesto log（异步 subprocess 日志必须可查）
      json.lua                   -- 保序 pretty printer（不 decode/encode 往返）
      str.lua                    -- trim/宽度/百分号编码/循环检测辅助
      platform.lua               -- exepath 探测、tempdir、shell 类型（pwsh/sh/cmd）
      notify.lua                 -- 统一通知（去重、级别、可静默）

    parse/
      block.lua                  -- 全文 → block 列表（按 ### 切分）
      request.lua                -- block → Request（请求行/头/体）
      variables.lua              -- @var = value / @var := value
      scripts.lua                -- < {% %} / > {% %} / > ./file.js / {{ }} 块
      metadata.lua               -- # @name / # @ref / # @no-redirect / # @lang ...
      cursor.lua                 -- 光标 → 所属 request 的定位（含边界歧义处理）

    resolve/
      vars.lua                   -- {{}} 替换引擎（优先级、递归、循环检测）
      dynamic.lua                -- {{$uuid}} {{$timestamp}} {{$randomInt}} ...
      pyencode.lua               -- {{%var}} 百分号编码
      chain.lua                  -- 命名请求响应引用（rest.nvim / vscode 风格）

    env/
      file.lua                   -- env.json 读取/缓存/mtime 失效
      profile.lua                -- active profile 解析 + 合并顺序
      api.lua                    -- 对外：get/set/switch/list

    js/
      runtime.lua                -- 探测 node/deno、构造 payload、超时、错误映射
      sandbox.lua                -- 权限参数拼装（permission/no-net 等）
      bridge.lua                 -- Lua ⇄ JS 数据编解码（含 base64 二进制兜底）
    harness/
      harness.mjs                -- 单文件 harness（自写，非第三方模块）
      shims/client.mjs           -- client.test/assert/log/global.*
      shims/response.mjs         -- response.body/status/headers/contentType
      shims/request.mjs          -- request.variables/headers/method/url/body

    http/
      curl.lua                   -- Request → argv（唯一映射表，见 §7.2）
      runner.lua                 -- vim.system 执行、超时、取消、临时文件生命周期
      response.lua               -- 头/体/JSON 解析 → Response
      exporter.lua               -- argv → 可复制字符串（pwsh/sh/cmd 三种引号策略）
      auth.lua                   -- basic/bearer/digest（规范 auth 章节）

    format/
      formatter.lua              -- 总调度（结构层 + body 片段采集 + 并行外部工具 + 缓存）
      request.lua                -- HTTP 结构层规范化
      tools.lua                  -- jq / oxfmt 适配器（探测、调用、超时、回退）
      json_internal.lua          -- 保序 JSON printer（jq 缺失时的兜底，附录 C）
      js_block.lua               -- 脚本围栏包裹/还原 + oxfmt 调用

    ui/
      response_win.lua           -- 响应窗口（左侧/底部/浮动可配）
      statusline.lua             -- 命名请求/最近状态（lualine 组件 + vim.o.statusline 回退）
      extmark.lua                -- 每个请求块首行虚拟文本（状态码/耗时/测试结果）
      picker.lua                 -- 请求列表（fzf-lua 适配 + 原生 vim.ui.select 回退）
      omnifunc.lua               -- 可选补全

  queries/http/                  -- 以 ; extends 方式补充/覆盖（不覆盖用户已有查询）
    highlights.scm
  js/                            -- 见上 harness/
  doc/rikuesto.txt               -- :help 文档（vimdoc）
  tests/
    run.lua                      -- nvim --headless -l tests/run.lua
    fixtures/*.http
    golden/*.curl
```

---

## 5. 解析层设计（L2）

### 5.0 与 treesitter 的分工

见 §3 的关键决策与附录 B 的实测数据。一句话：**TS 树只喂 UI 和交叉校验，永不做执行输入**；行式 parser 的产物 `ParseResult` 是唯一权威结构。

### 5.1 词法单位

逐行扫描，维护 `state ∈ {idle, request_line, headers, body, script_pre, script_post}`。所有行列号以 **0-based row + 0-based byte col** 保存（与 nvim API 一致），对外显示时 +1。

### 5.2 块切分规则

1. 出现 `/^###+/` 的行 → 块分隔符；`###` 之后的同行为块的「标题/注释」（`title`）。
2. `###` 之前、文件开头的一段叫 `preamble`（可含 `@var` 声明与 `# @xxx` 元数据；httpyac 的「全局区域」语义）。
3. 块内 `#` 或 `//` 开头为行注释；`/* ... */` 为块注释（httpyac 扩展，**支持但不推荐**，解析时直接跳过，不参与结构判定）。
4. 空行不切块，只参与「头 vs 体」分界判定。

### 5.3 请求行

```text
[Method] URL [HTTP-Version]
```

- `Method` 缺省为 `GET`；支持规范里的标准方法集合 + WebDAV/扩展方法（`PROPFIND`、`LOCK`、`SEARCH`、`REPORT`…），实现为白名单 union。
- **URL 续行**：后续以空白开头的行，或以 `?` / `&` 开头的行 → 拼接到 URL（去除首尾空白，`?`/`&` 保留）。这是规范中「所有实现除 VS2022 都支持」的特性，必须实现。
- `HTTP/1.1` / `HTTP/2` 作为可选尾缀，传给 curl 的方式见 §7.2。

### 5.4 请求头

- 首个「非注释、非空、`Name: Value` 形状」行开始进入 `headers`。
- **多行头值（续行）**：下一行以空白开头 → 拼进上一个头的值（JetBrains/httpyac 行为）。用「与 URL 续行互斥的判定顺序」避免歧义：**若上一行是请求行则是 URL 续行；若上一行是头则是头值续行**。
- 空行 → 进入 `body`。
- 头名大小写保留原样，匹配时大小写不敏感；输出去重策略：同名保留最后一处（可配）。

### 5.5 body

- body 起点 = 头区后的第一个空行之后；终点 = 下一个 `###` 或 response handler 行（`>`）。
- 类型判定（决定格式化与 curl 参数）：
  | 判定 | 条件 | 处理 |
  |------|------|------|
  | `json` | `Content-Type` 含 `json` 或首字符 `{`/`[` | 内嵌 json 高亮（已由 injections 提供），格式化时缩进 |
  | `xml` | `Content-Type` 含 `xml` 或首字符 `<`（且非 `< {%`） | 内嵌 xml 高亮 |
  | `graphql` | `Content-Type` 含 `graphql` 或 `query `/`mutation ` 开头 | 内嵌 graphql 高亮 |
  | `urlencoded` | `Content-Type` 为 `x-www-form-urlencoded` 且存在 `&` 前缀续行 | 续行拼接 |
  | `multipart` | `Content-Type` 为 `multipart/form-data` | 用 curl `-F`（§7.2） |
  | `external` | body 只有一行 `< ./payload.bin` | 用 curl `--data-binary @file` |
  | `raw` | 其它 | 原样 |
- **必须保留原始字节**：解析只记录 `body.range` + 原文切片，不做 trim，保证发送与文件内容一致（末尾换行除外，可配 `trim_body_trailing_newline`）。

### 5.6 脚本块

| 语法 | 位置 | 语义 |
|------|------|------|
| `< {% ... %}` | 请求行之前 | pre-request script（JetBrains） |
| `> {% ... %}` | body 之后 | response handler（JetBrains） |
| `> ./handler.js` | body 之后 | 外部响应脚本（读文件执行） |
| `{{ ... }}`（httpyac） | 请求行前 | 作为 pre-request，`exports.x` 或 `module.exports` 的键成为变量 |
| `?? key op value` | body 之后 | 声明式断言（可选实现，见 §9.4） |

解析时脚本内容按 `{%` 与 `%}` 的**围栏偏移**切出，保留原始缩进（JS 语法敏感），并把绝对起始行列记录进 `script.meta`（用于错误定位与 extmark）。

### 5.7 元数据

`# @name login`、`# @ref login`、`# @no-redirect`、`# @no-cookie-jar`、`# @lang json`、`# @timeout 5000` 等，解析为 `request.meta`（table），未知 `@xxx` 保留在 `meta.raw` 里不报错。

### 5.8 错误模型

parser **永不抛异常**：遇到不合法结构生成 `diagnostic{row, col, severity, message}` 列表放在 `ParseResult.diagnostics`。UI 用 `vim.diagnostic.set(namespace, bufnr, ...)` 以 namespace `rikuesto` 呈现（不与 LSP 的诊断空间冲突），同时 `:Rikuesto run` 在有 error 级诊断时拒绝执行并提示。

### 5.9 缓存

`ParseResult` 按 `{bufnr, changedtick}` 缓存；同 tick 内命令/格式化/复制的重复解析为 0 成本。

---

## 6. 变量解析（L3）

### 6.1 优先级（高 → 低）

1. 请求作用域变量（JS pre-request `request.variables.set` / `client.global.set` 本次请求内）
2. 命名请求响应引用（`{{login.response.body.$.token}}`，§6.4）
3. 块内 `@var = value`（含块内 `# @var`？——不支持，规范只认 `@`）
4. 文件 preamble `@var = value`
5. 环境 profile 变量（`env.json` 中的 `<profile>` 段）
6. `global.var`（被 5 同名覆盖）
7. 动态变量 `{{$...}}`
8. 未命中 → **保留原文并告警**（不擅自变成空串，避免「静默发错请求」）

> 说明：这套顺序合并了 JetBrains 与 VS Code REST Client 的共同部分，并让 README 里 `global.var` 可覆盖的语义成立。

### 6.2 替换引擎

- 单遍扫描 `{{ ... }}`，递归展开（新值里可能还有 `{{}}`），**深度上限 10 + 访问集合做环检测**，命中即报错。
- `{{%name}}` → 先求值再做 RFC3986 百分号编码（只对未编码字符编码，不双重编码）。
- 替换目标：URL、头名？(**否**，只替换头值) 、头值、body。脚本体内的 `{{}}` **不替换**（JS 自己处理），但 `resolve` 会向 JS 暴露同样的变量表。
- 求值发生在「请求快照」阶段，快照 `{method,url,headers,body}` 与 `vars_used` 一起进日志，便于排查。

### 6.3 动态变量（内置，纯 Lua）

`{{$uuid}}`/`{{$guid}}`、`{{$timestamp [offset unit]}}`、`{{$isoTimestamp}}`、`{{$datetime rfc1123|iso8601|fmt}}`、`{{$randomInt [min max]}}`、`{{$random.integer(a,b)}}`/`float`/`alphabetic(n)`/`alphanumeric(n)`/`hexadecimal(n)`/`email`、`{{$processEnv NAME}}`、`{{$env.NAME}}`、`{{$dotenv NAME}}`、`{{$projectRoot}}`。
实现要点：随机数用 `vim.uv.hrtime()` + `math.random` 播种（`math.randomseed(os.time())` 不重复播种）；时间用 `os.date`/`vim.uv.gettimeofday`；`format` 自定义时只支持 strftime 子集，避免引入 Day.js。

### 6.4 命名请求响应引用（VS Code 风格，实现子集）

- `{{name.response.body.$.a.b[0].c}}`：JSONPath 子集（`$.`、`.key`、`[n]`、`[*]` 不做）。
- `{{name.response.body.*}}`、`{{name.response.headers.X-Total}}`、`{{name.response.status}}`
- 依赖 `state.named_responses[name]`（§4），只在**同一次会话**内有效；未运行过的命名请求 → 报错并提示先跑它。

---

## 7. 传输层设计（L4）

### 7.1 执行模型

```lua
vim.system(argv, { cwd = ..., stdin = false, timeout = cfg.timeout, text = false }, on_exit)
```
- **完全异步**：不阻塞 UI；`runner` 返回 job 句柄，`:Rikuesto cancel` / `job:kill()` 可中断。
- 不使用 shell（`shell = false` 默认），彻底规避 PowerShell/cmd 引号问题。
- `cwd` = http 文件所在目录（相对外部 body `< ./x.json` 与项目相对路径由此自然成立）。
- 并发：同一 buffer 默认串行（JetBrains 行为）；不同 buffer 可并发；`cfg.max_concurrent` 默认 1。

### 7.2 `.http` → curl 映射表

| `.http` 元素 | curl 参数 |
|---|---|
| method | `-X METHOD`（`GET` 且无 body 时省略；**`HEAD` 一律用 `--head`**，见下） |
| URL（已替换变量） | 最后一个位置参数（不做 shell 引号包裹） |
| `HTTP/2` | `--http2`；`HTTP/1.1` → `--http1.1`（按请求行尾缀二选一） |
| 每个 header | `-H "Name: Value"`（同名多值 → 多个 `-H`） |
| body（raw/json/xml/graphql）且长度 ≤ 阈值 | `--data-raw` + 原文（换行原样） |
| body 且长度 > 阈值 | 写临时文件 + `--data-binary @<tmp>`（保字节、不解释 `@`） |
| `external` body | `--data-binary @<abs path>` |
| `urlencoded` 多行 | 拼接为单行后 `--data-raw` |
| `multipart/form-data` | 每个 part → `-F "name=value"` / `-F "name=@file"` |
| `# @no-redirect` | 不加 `-L`（默认 `-L`，可配） |
| auth（`Authorization` 缺失而 URL 含 `user:pass@`） | `-u user:pass` |
| `cfg.insecure` / `# @insecure` | `-k` |
| `cfg.proxy` / `# @proxy` | `--proxy` |
| `# @timeout ms` | `--max-time`（秒，向上取整） |
| 恒定参数 | `-sS --no-progress-meter -D <headers.tmp> -o <body.tmp> -w '%{json}'` |

> 两条已核实的 curl 事实（官方 manpage）：
> - **`%{json}`「Added in 7.70.0」**（本机 8.21 满足）。**降级路径**：若解析失败，从 `headers.tmp` 的最后一个状态行 + `-w '%{http_code}\n%{time_total}'` 重建元数据。
> - **绝不能写成 `-d @file`**：manpage 明言 `--data` 从文件读时「carriage returns, newlines and null bytes are stripped out」；只有 `--data-binary` 才「newlines and carriage returns are preserved」。所以多行 JSON body 走文件时必须 `--data-binary @file`。
> - Windows `CreateProcessW` 的 `lpCommandLine` 上限 "**32,767 characters**"（Microsoft Learn 原文）→ §7.3 的临时文件阈值有硬依据。
>
> **HEAD 的实现修正（本轮集成测试实测）**：`-X HEAD` 会让 curl 等一个永远不会到达的 body，直到 `--max-time` 超时（实测 exit 28 / 20s / 0 字节）；省略 `-X` 则**直接变成 GET**（实测 HEAD 拿到了 292 字节 body）。唯一正确写法是 **`--head`**。副作用：`--head` 会把响应头写进 `-o` 指定的文件，所以 `response.parse` 在 `meta.method == 'HEAD'` 时必须把 body 置空（header 仍从 `-D` 文件解析，不受影响）。

### 7.3 临时文件策略（Windows 关键点）

- `vim.fn.tempname()` 得到唯一路径，**每个请求一个目录**：`headers.txt`、`body.bin`、`payload.tmp`；结束后延迟清理（`cfg.keep_temp_on_error` 时保留并在日志里打路径）。
- 为什么用临时文件而不是全走 stdout：避免 Windows 控制台/管道编码问题（GBK 干扰、二进制 body 被破坏）、避免大体量 body 撑爆 `CreateProcess` 32767 字符上限、避免 stdout 里混入进度/错误输出。
- 写 body 临时文件用 `vim.uv.fs_open/write` 以 **`wb` + 原 buffer 字节**写入（不经 `vim.json` 重编码），保证 UTF-8 原样。

### 7.4 超时与取消

`cfg.timeout` 默认 30000ms（`--max-time` 与 `vim.system.timeout` 双保险）；超时映射为 `Response.error = {kind="timeout"}`，UI 提示 `--max-time` 值并给出「提高 timeout」的命令建议。

### 7.5 安全

- `env.json` 中变量值只进 argv，不进日志明文：日志里对 `Authorization`、`Cookie`、`*token*`、`*secret*` 做 `***` 掩码（`cfg.mask_patterns`）。
- 响应 buffer 默认 `nomodifiable` + `nobuflisted`，避免误存敏感内容到文件。
- JS 脚本默认沙箱（§8.3），`cfg.js.allow_net/allow_fs` 默认 `false`。

### 7.6 curl exporter（复制为 curl）

同一份 `curl.lua` 产出 argv，exporter 再做「引号化」：

| 目标 | 策略 |
|---|---|
| `pwsh`（本机默认） | 单引号字符串，内部 `'` → `''`；多行 body 用 here-string `@'...'@` 或 `--data-binary $'...'`（选择单引号 + 反引号安全子集） |
| `sh` / `bash` | 单引号，内部 `'` → `'\''` |
| `cmd` | 双引号 + `^` 转义 |
| `native`（默认） | 逐行输出 argv（`--data-binary` + 文件形式），最稳 |

多行 body 默认替换为 `--data-raw @<file>` 或 `-d @payload.json`，并提示「body 已展开为文件引用」；`cfg.curl_export.inline_body_max` 控制阈值。输出目标：`setreg('+')` + `:echo` + 可选 `vim.ui.input` 预览。

---

## 8. JS 脚本子系统（F6）

### 8.1 问题与结论

「轻量级 JS 执行」有三条路：
1. 纯 Lua 写 JS 解释器（如自研 2000+ 行）：**否决** —— 与「轻量」和可维护性冲突，`crypto` 之类永远补不齐。
2. 依赖 Node 生态（httpyac 式 `require`）：**否决** —— 需要 npm 依赖，且 README 明确不建议。
3. **复用系统已有运行时 + 自写单文件 harness**：**采纳**。本机已同时具备 node 26 与 deno 2.9。

### 8.2 运行时探测与选择（**不强制 deno**）

结论：**不需要 deno**。harness 只用三样东西——stdin 读 JSON、stdout 写 JSON、`node:crypto`——这三样 **Node 与 Deno 都是内建**，没有一处需要 npm。

```lua
-- cfg.js.runtime 默认 "auto"：auto → node → deno → none
auto = exepath('node') or exepath('deno') or nil
```

| 运行时 | 调用方式 | 定位 |
|---|---|---|
| **node（首选）** | `node --permission --allow-fs-read=<harness dir> harness.mjs` | 普及率最高；`--permission` 已 Stable，恰好把 `child_process`/网络/写盘关掉；`node:crypto` 内建 |
| deno（可选） | `deno run --quiet --no-prompt --deny-net --deny-write --deny-env --deny-run harness.mjs` | 默认即全禁（以上 `--deny-*` 可省）；作为无 node 环境的第二条路径，同一份 harness 不改 |
| none | — | script 块降级为「跳过 + 一次性提示」；`??` 断言仍可用 |

**以下三个参数细节是实测/查文档纠正过的，写实现时别再推开**：

1. **`--allow-fs-read=<harness dir>` 是必需的，不是可选的**。`node --permission entry.mjs` 能跑（入口脚本读取被豁免），但一旦 harness `import './shims/client.mjs'`，立即 `ERR_ACCESS_DENIED`（实测）。若不想开这个权限，就得把 harness + shims 打成**单个 `.mjs`**（届时可去掉 `--allow-fs-read`）。
2. **deno 没有 `--no-net`**：`deno run --no-net ...` → `error: unexpected argument '--no-net' found`（实测）。Deno 默认就是全禁，所以正确写法是「啥也不加」或显式 `--deny-net --deny-write --deny-env --deny-run`（`--deny-*` 优先于 `--allow-*`，官方文档明确）。
3. **node 的 permission model 不管环境变量**：`process.env` 在 `--permission` 下仍可读（实测），而 deno 的 `--deny-env` 能拦。→ 安全上应把「脚本能读到 shell 里的 secret」当作已知前提（§17 风险表）。

为什么把 node 放第一（与上一版相反）：
1. **Node 的存在概率远高于 deno**，用户机器上“装了 Node”几乎是默认前提；把首选运行时设成小众工具会凭空增加安装门槛。
2. **沙箱强度已不是决定因素**：`--permission` 的默认是「禁一切」，与我们需要的「只跑用户自己写的脚本」正好匹配；deno 的额外优势（无 npm 幻觉）在这里用不上，因为我们本来就不允许 `require` 第三方包。
3. **启动成本**：两者均是单次短进程（~40–80ms 量级），JS 只在 pre-request/response handler 时触发，不是热路径。

两者都用 **stdin 传 payload、stdout 返回 JSON** 的单进程单次调用（无长期 daemon：避免状态泄漏与常驻内存）。`runtime.lua` 里做一个 `adapter{argv(), env(), version()}` 表，加运行时 = 加一行表项，不改 harness。

### 8.3 harness 协议

请求（Lua → JS，stdin，JSON）：
```json
{
  "phase": "pre" | "post",
  "script": "…源码…",
  "meta": { "row": 12, "col": 0, "lang": "javascript" },
  "request": { "method": "POST", "url": "…", "headers": [["A","b"]], "body": "…" },
  "response": { "status": 200, "headers": [["Content-Type","application/json"]],
                "bodyBase64": "…", "contentType": { "mimeType": "…", "charset": "utf-8" },
                "durationMs": 123 },
  "vars": { "k": "v" },
  "globals": { "k": "v" },
  "limits": { "timeoutMs": 3000 }
}
```
响应（JS → Lua，stdout，JSON）：
```json
{
  "vars": { "timestamp": "…" },
  "globals": { "auth_token": "…" },
  "headerOverrides": [["X-Sig","…"]],
  "bodyOverride": null,
  "logs": ["…"],
  "tests": [ { "name": "Status is 200", "pass": true, "message": "…" } ],
  "errors": [ { "message": "…", "stack": "…", "line": 12 } ]
}
```

### 8.4 沙箱 API（规范 §Response Handlers / §Pre-Request Scripts 子集）

- `client.test(name, fn)`、`client.assert(cond, msg)`、`client.log(x)`、`client.global.set/get/clear/clearAll()`、`client.exit()`、`client.global.headers.set/get`
- `response.status`、`response.body`（按 `Content-Type` 自动 `JSON.parse`）、`response.headers.valueOf/valuesOf`、`response.contentType.mimeType/charset`、`response.cookiesByName`
- `request.variables.set/get`、`request.environment.get`、`request.method/url`、`request.headers.all`、`request.body.getRaw()/tryGetSubstituted()`
- `crypto.hmac.sha256(...)` 等 → 映射到 `node:crypto` / deno 同名 API（两者均支持，无需第三方）
- 出错统一以 `errors[]` 返回，**不让子进程崩溃**（harness 顶层 try/catch + `process.exitCode = 0`）。

### 8.5 执行时机

```text
parse → resolve(变量/env) → [pre-request JS] → 用返回的 vars 再 resolve 一次 →
curl 执行 → [response handler JS] → globals 落 state → 断言结果进 UI
```
二次 resolve 是必需的：pre-request 产出的变量要能参与 URL/头/body 替换。脚本超时 `cfg.js.timeout_ms`（默认 3000）由 `vim.system.timeout` 强制。

---

## 9. 格式化设计（F3）

### 9.1 分工：能复用的绝不自己写

| 层次 | 谁来格式化 | 自写量 |
|---|---|---|
| **HTTP 结构层**（块分隔/请求行/头/变量声明/空白与空行） | **自写**（无任何现成工具认识 `.http` 的语义结构） | 主体工作量，~300 行 |
| **JSON body** | **`jq`**：`jq --indent 2 .`（stdin/stdout） | 0（仅做调用与回退） |
| **JS 脚本块**（`< {% %}` / `> {% %}` 内） | **`oxfmt`**：`oxfmt --stdin-filepath block.js` | 0（仅做包裹/还原） |
| **XML/GraphQL body** | v1 不动（原样保留缩进），不引入 xmllint | 0 |

实测数据（`docs/experiments/ts-http/stdin.txt`）：

| 工具 | 调用 | 实测结果 | 单次成本 |
|---|---|---|---|
| jq 1.8.2 | `jq --indent 2 .`，stdin | 键序保持；`1234567890123456789` / `1.0` / `-0` **字面量保持**（1.8 的 decnum，不会变 double）；UTF-8 正常；尾逗号与注释**报错**（正好用来判定「不是严格 JSON」） | 16 ms |
| oxfmt 0.75.0 | `oxfmt --stdin-filepath x.js`，stdin | 正常 reformat；片段含顶层 `return`/`await` 也不报错（丢进函数体包裹后还原是更稳的做法） | 78 ms |
| oxfmt 对 JSON | `oxfmt --stdin-filepath x.json` | 输出成**单行** `{ "a": 1, "b": [1, 2] }` → **不用于 JSON**，JSON 一律走 jq | — |

结论：JSON 用 jq、JS 用 oxfmt、结构用自写。**这两个工具是「探测到就用」，不是硬依赖**（见 §9.3 的三级回退）。

### 9.2 不变式（无论用哪个工具）

- **幂等**：`fmt(fmt(x)) == fmt(x)`。对 JSON/JS 靠「外部工具输出即稳定形式 + 二次格式化结果相同」保证，`tests/` 里对每类 body 跑两遍比对。
- **不破坏语义**：外部工具返回非 0、输出为空、输出含 `ERROR`/`error:`、或 JSON 输入本身不合法 → **该片段原样保留**并记 debug 日志，绝不用「差不多」的结果覆盖用户内容。
- **范围最小化**：只重写 `body.range` 内的行，头区/脚本围栏/注释不经过外部工具。
- **可被 conform 调用**：注册 `rikuesto` 为 conform formatter（`command = function(self, ctx) … end`, `stdin = false`），用户既可用 `:Rikuesto format` 也可用 `<leader>f`；未装 conform 时走自身 `nvim_buf_set_lines` 单次替换（单次 undo 块）。

### 9.3 外部工具调用协议（Windows 实测过的细节）

1. **探测**：`vim.fn.exepath('jq'|'oxfmt')`；`cfg.format.json = 'auto'|'jq'|'internal'`、`cfg.format.js = 'auto'|'oxfmt'|'none'`。
2. **调用**：`vim.system(argv, { stdin = payload, text = true })`，**不经 shell**；仅在内存里的 body 片段上跑，不写临时文件。
3. **实测通过的两点**（(见 `stdin.txt`）：① jq 的中文/`✓` 往返无损；② Neovim 0.12 在 Windows 上**能直接 exec `.CMD` shim**（`oxfmt.CMD` exit=0，能正常读 stdin），但为避开 `cmd.exe` 中间层，`platform.resolve()` 仍优先解析到原生 `.exe`，否则回退到 `node <pkg>/bin/oxfmt`。
4. **并行 + 缓存**：一个文件里可能有 N 个 JSON/K 个 JS 块。做法是**先收集所有 body 片段 → 一次性并行 spawn（`vim.system` 全部异步发起）→ 全部回来后单次 `nvim_buf_set_lines`**。缓存键 = `{tool, version, sha1(fragment)}`，同内容不重复 spawn（format-on-save 的第二次通常 0 成本）。最坏情况 10 个块 ≈ max(16ms, 78ms) 而非累加。
5. **JS 片段包裹**：`< {% return x %}` 这类片段不是完整模块。做法：`(async function(){ <fragment> })` 包裹 → oxfmt → 去掉首尾包裹行、整体减 2 空格缩进还原。失败则 try `oxfmt` 原样（不包裹），再失败就保留原文。
6. **缺工具时的回退**：
   - jq 缺失 → 用内置**保序** JSON printer（§附录 C，~60 行，只做缩进不做语义变换；这是唯一需要自写的格式化代码）。
   - oxfmt 缺失 → JS 块原样（不缩进也不错缩进）。
   - 两者均缺失 → 只做 HTTP 结构层格式化，`:checkhealth` 里标注「JSON 由内置缩进器处理，JS 未格式化」。

### 9.4 HTTP 结构层规则（自写部分）

| 元素 | 规则 |
|---|---|
| 块分隔 | `###` 后接单空格 + 标题（标题文本原样，多余空白折叠） |
| 请求行 | `METHOD URL [HTTP/2]`，method 大写，URL 内连续空白折叠（不动 `%20`、不动 `{{}}` 内部的空格？——`{{ }}` 内空白属变量名，**不动**） |
| 续行 URL | 有 `?`/`&` 逐行排列时**保持用户分行**（`cfg.format.explode_query = 'keep' / 'inline' / 'explode'`，默认 `keep`） |
| 头 | `Name: Value`（冒号后单空格），头名保持原大小写；`cfg.format.sort_headers` 默认 `false`（头顺序有语义） |
| 头续行 | 缩进 2 空格对齐 |
| body 边界 | body 前恰好一个空行，末尾不多于一个换行 |
| 脚本围栏 | `< {%` / `> {%` / `%}` 各自独立成行，**围栏内交给 oxfmt，围栏与缩进由我们管** |
| `@var` 声明 | 同一连续组内对齐 `=`（`vim.fn.strdisplaywidth`），`:=` 保留 |
| 注释 | 保留原文与位置（`#`/`//`/`/* */` 一律不动内容） |
| 行尾 | 内部统一 `\n`，写回时按 buffer 的 `fileformat` 还原 |

### 9.5 与 kulala-fmt 的关系

用户当前 conform 已配 `http = { "kulala-fmt" }`。rikuesto **不抢占**：提供 `cfg.format.register_conform`，help 里给一行配置让用户把 `"rikuesto"` 放到 `kulala-fmt` 之前或替换之；不装 conform 时 `:Rikuesto format` 独立可用。

### 9.6 可选：`??` 断言

`?? status == 200` 格式化时原样保留（只折叠多余空白）；响应后用纯 Lua 求值：`status`、`header <name> <op> <value>`、`duration`、`body <jsonpath> <op> <value>`，操作符 `== != > >= < <= includes contains startsWith endsWith exists matches`。用固定语法解析而非 `load()` eval，避免注入。**优先级低**，放 M4。

---

## 10. 环境配置（F5）

### 10.1 路径解析顺序

1. `setup({ env = { path = "…" } })`
2. `vim.env.RIKUESTO_ENV`（便于 CI/临时切换）
3. 项目级：从 http 文件所在目录向上查找 `rikuesto.json` / `.rikuesto.env.json`（可配，默认关闭，避免越权覆盖）
4. 默认：`vim.fs.joinpath(vim.env.LOCALAPPDATA or vim.fn.stdpath("config"), "nvim", "rikuesto", "env.json")`
   - 实测本机即 `C:\Users\<u>\AppData\Local\nvim\rikuesto\env.json`
   - 非 Windows：`$XDG_CONFIG_HOME/nvim/rikuesto/env.json`

### 10.2 Schema（兼容现有 `env.json`）

```lua
{
  "global": { "env": "dev", "var": { "api_key": "…", "test_host": "http://demo" }, 
              "defaults": { "timeout": 30000, "follow_redirects": true } },
  "dev":    { "api_key": "…", "dev_host": "https://dev" },
  "prod":   { "api_key": "…", "dev_host": "https://prod" }
}
```

- 顶层键：`global` 保留字，其它键 = profile 名（值必须是 object）。
- 合并：`global.var` ← 覆盖 ← `active_profile`；`active_profile = CLI切换 > global.env > nil`。
- 值为非字符串（数字/布尔/对象）时：数字/布尔转字符串；对象允许 `{{a.b}}` 点路径取值（子集）。
- `global.defaults` 是插件默认值的**最低优先级层**（低于 `setup()`，高于内置默认），用于「这个环境默认不跟随重定向」这类场景。
- 校验失败不崩溃：返回 diagnostics，`:Rikuesto env check` 输出结果；写坏的 JSON 保留原文并给出行列。

### 10.3 缓存与失效

`env/file.lua` 用 `vim.uv.fs_stat().mtime` 做失效判定（每次执行前检查，stat 极廉价），并提供 `:Rikuesto env reload` 强制刷新 + `vim.uv.fs_event`（可选）监听变更。

### 10.4 命令

- `:Rikuesto env` → 列出 profile 与当前激活项（`vim.ui.select` 切换）
- `:Rikuesto env set <profile>` / `:Rikuesto env edit` / `:Rikuesto env check`
- 变量查看：`:Rikuesto vars` → 当前光标请求的「解析后变量表」（掩码后）显示在 scratch buffer

---

## 11. UI 与交互

### 11.1 命令表

| 命令 | 说明 |
|---|---|
| `:Rikuesto run` | 运行光标所在请求（有选区则运行选区内请求） |
| `:Rikuesto run all` | 顺序运行全文请求（遇错可停，可配） |
| `:Rikuesto run {name}` | 运行 `# @name {name}` 的请求 |
| `:Rikuesto repeat` | 重跑上一次请求 |
| `:Rikuesto cancel` | 中断进行中的请求 |
| `:Rikuesto curl` | 打印当前请求的 curl（`bang` → 直接写 `+` 寄存器） |
| `:Rikuesto curl {native\|pwsh\|sh\|cmd}` | 指定引号策略 |
| `:Rikuesto copy curl` | 复制到系统剪贴板并通知 |
| `:Rikuesto format` | 格式化（`range` 支持只格式化选区） |
| `:Rikuesto list` | 请求列表 picker |
| `:Rikuesto env …` | 见 §10.4 |
| `:Rikuesto vars` | 变量快照 |
| `:Rikuesto log [clear]` | 日志 |
| `:Rikuesto js runtime {auto\|node\|deno\|none}` | 查看/切换 JS 运行时 |
| `:Rikuesto response {open\|close\|last}` | 响应窗口 |
| `:checkhealth rikuesto` | 依赖与解析器自检 |

### 11.2 键位：默认全关，可选开启

**插件默认不安装任何快捷键**（`keymaps = false`）。所有动作都有 `:Rikuesto …` 命令和
`<Plug>(rikuesto-*)` 映射，键位完全由用户决定。

| 配置 | 效果 |
|---|---|
| `keymaps = false`（默认） | 不安装任何缓冲区键位 |
| `keymaps = true` | 安装完整可选集合，前缀为 `maplocalleader`（回退 `leader`）：`rr` run、`ra` run all、`rc` copy curl、`rf` format、`re` env、`rl` list、`rx` cancel、`rv` vars |
| `keymaps = { rr = '<Space>r', rc = '<Space>c' }` | **只**安装列出的动作，使用给定 lhs；未列出的动作不映射 |
| `keymaps = { rr = false }` 等价于不列该项 | 不映射该动作，并清掉上一次 attach 遗留的默认 lhs |

取消在途请求：`cancel_key`（默认 `<C-c>`）在请求开始时安装为**临时**缓冲区映射，响应返回后立即移除；
若用户已有该 lhs 的映射则不覆盖。`:Rikuesto cancel` 始终可用，与 `keymaps`/`cancel_key` 无关。

示例（只绑三个键）：

```lua
require('rikuesto').setup({
  keymaps = { rr = '<Space>r', rc = '<Space>c', re = '<Space>e' },
  cancel_key = '<C-c>',
})
```

### 11.3 响应窗口

- 布局：`ui.response.layout`，取值为 `right`（**默认，右侧垂直 split**）/ `bottom` / `top` / `left` / `float`；`size` 表示占比（垂直布局是宽度、水平布局是高度）。别名：`vsplit`→`right`、`split`/`botright`→`bottom`、其他非法值回退 `right`。
  - 实现注意：`:vsbuffer` 不是合法 Ex 命令（会报 `E492`），正确做法是先 `vsplit`/`split` 再 `nvim_win_set_buf()`；位置用 `topleft`/`belowright` 修饰符控制。实测：`right→右侧`、`bottom→下方`、`top→上方`、`left→左侧`。
- 内容顺序：`状态行`（含 HTTP 版本/状态码/原因/耗时/大小/重定向）→ 空行 → `响应头`（折叠）→ 空行 → `body`。
- 语法：body 为 JSON 时 `filetype=json`（复用 treesitter），否则 `rikuesto-response`（自定义 filetype，`syntax` 关键字文件，不引入额外 parser）。
- 交互：`q` 关闭、`<CR>` 在折叠上切换、`gf`/`<CR>` 打开外部 body 文件、`y` 复制 body。
- extmark：请求首行虚拟文本右侧显示上次结果 `200 · 132ms · 1.2KB`；失败红色。使用独立 namespace，`nvim_buf_set_extmark(..., {virt_text_pos="eol"})`，随 `changedtick` 失效重算。

### 11.4 可选集成的适配层（全部 `pcall` 保护）

- **conform.nvim**：format 注册。
- **fzf-lua**：`:Rikuesto list` 用 `fzf-lua` 的 `fzf_exec`；无则 `vim.ui.select`。
- **blink.cmp**：`omnifunc` 提供 `{{}}` 变量名与头部名；blink 会自动桥接 `omnifunc`（必要时给 `source` 说明）。
- **lualine**：提供 `require('rikuesto.ui.statusline').component` 组件。

---

## 12. Treesitter 集成

- **不打包 parser，不管理 parser 安装，也不负责启动高亮**。`ftplugin/http.lua` 里不调用
  `vim.treesitter.start()`；高亮 / 折叠完全交给用户已有的 parser 管理器（本机为
  `romus204/tree-sitter-manager.nvim`）。
- **为什么不接管（实测）**：Neovim 不会自动开启 tree-sitter；解析器管理器的 `highlight` 钩子是在它
  自己 `setup()` 时注册的 `FileType *` autocmd。用户把该插件挂在 `event = "VeryLazy"`，于是在那之前
  打开的 `.http` 缓冲拿不到高亮。实测：`-c edit test.http` → `parser=true, highlights query=true,
  highlighter=false`；`doautocmd User VeryLazy` 之后再打开同一文件 → `highlighter=true`。
  结论：这是**用户配置的加载顺序**问题，正确修法是在配置侧（把 parser 管理器提前到
  `BufReadPre`/`BufNewFile` 或 eager 加载），而不是让插件去兜底。
- 设计初稿里的 `queries/http/*.scm` **未实现**（可选增强）；parser 自带的
  `highlights/folds/injections` 已够用：`json_body`/`xml_body`/`graphql_data`/`script` 都注入到对应语言。
- 折叠同样不接管（不设 `foldmethod`/`foldexpr`），需要时由用户自行设置。
- 语义解析不依赖 TS，grammar 升级只会影响显示 → **故障半径可控**（§3 决策的直接收益）。

## 13. 配置（`setup(opts)`）草案

```lua
require('rikuesto').setup({
  env = {
    path = nil,                      -- nil = 默认路径（§10.1）
    profile = nil,                   -- nil = 用 env.json 的 global.env
    project_local = false,           -- 是否允许项目级覆盖
  },
  curl = {
    bin = nil,                       -- nil = vim.fn.exepath('curl')
    extra_args = {},                 -- 追加到 argv 前部
    insecure = false,
    proxy = nil,
    follow_redirects = true,
    max_time_ms = 30000,
    inline_body_max = 8000,          -- 超过则走临时文件
  },
  tools = {
    curl  = nil,                     -- nil = vim.fn.exepath('curl')
    jq    = nil,                     -- nil = exepath('jq')
    oxfmt = nil,                     -- nil = exepath('oxfmt') → 再退到 node <pkg>/bin/oxfmt
  },
  js = {
    runtime = 'auto',                -- auto(node 优先)|node|deno|none
    timeout_ms = 3000,
    allow_net = false,
    allow_fs = false,
    response_handlers = true,
    pre_request_scripts = true,
  },
  format = {
    enabled = true,
    json = 'auto',                   -- auto(jq→internal)|jq|internal
    js = 'auto',                     -- auto(oxfmt)|oxfmt|none
    tool_timeout_ms = 5000,
    cache = true,
    explode_query = 'keep',
    sort_headers = false,
    align_variables = true,
    register_conform = true,
  },
  curl_export = {
    dialect = 'native',              -- native|pwsh|sh|cmd
    register = '+',
    mask_secrets = true,
  },
  ui = {
    response = { layout = 'right', size = 0.4, open = 'auto' },
    extmark = { enabled = true },
    statusline = { enabled = true },
  },
  keymaps = true,                    -- or table of overrides, or false
  mask_patterns = { 'token', 'secret', 'password', 'authorization', 'cookie', 'api_key' },
  log = { level = 'warn', keep = 500 },
})
```

---

## 14. 错误处理、日志与可观测性

- **分级**：`user error`（notify `ERROR` + 可操作建议）、`parser diagnostic`（缓冲区诊断）、`transport error`（响应窗口红标题）、`js error`（响应窗口追加 `--- script error ---` 段，带行列）。
- **日志**：环形缓冲（默认 500 条）+ `:Rikuesto log` 打开 scratch buffer；含 `argv`（掩码后）、耗时、退出码、stderr。异步场景没有日志几乎无法排障，因此这是 P0 特性而非附加项。
- **`:checkhealth rikuesto`**：curl 路径/版本（解析 `curl --version` 首行）、`%{json}` 能力（执行一次 `curl -sS -w '%{json}' -o /dev/null https://…`? 不做联网 → 改为检查版本号 ≥ 7.70）、node/deno 探测与版本、`http` parser 是否存在、env.json 是否可解析、treesitter 注入状态。

---

## 15. 测试策略（0 依赖）

- `nvim --headless -l tests/run.lua`（0.12 支持 `-l`）跑纯 Lua 断言，自带极简 `t.eq/t.same/t.error`。
- **解析**：`tests/fixtures/*.http`（覆盖：URL 续行、头续行、`###` 标题、块注释、form 多行 body、external body、`< {% %}`/`> {% %}`、`> ./f.js`、BOM、CRLF、空文件、只有 preamble）。
- **导出（黄金文件）**：`fixtures/x.http` → `argv` → 与 `golden/x.curl` 逐行比对（**不联网、不执行**，保证 CI 稳定）。
- **变量**：优先级矩阵 + 循环引用 + 动态变量形状（正则校验 uuid/时间戳）。
- **格式化**：`fmt(fixture) == golden` 且 `fmt(fmt) == fmt`（幂等）；对每类 body 跑「有 jq / 无 jq」「有 oxfmt / 无 oxfmt」四种组合，确保降级路径也幂等。
- **JS**：`harness` 单独用 node/deno 直接跑（不经 nvim），输入/输出 JSON 与 §8.3 协议比对；无运行时则 skip。
- **端到端（手动/可选）**：本地起 `curl` 可访问的 echo 端点不纳入自动化（按项目约定不自动起服务）。

---

## 16. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| **M0** 骨架 | 目录、config、commands、health、log、filetype 检测、`plugin/` 入口 | `:checkhealth rikuesto` 全绿；`:Rikuesto` 有补全 |
| **M1** 只读链路 | parser（block/request/variables/metadata）+ 变量替换（env.json + 动态变量）+ curl argv + runner + 响应窗口 + 复制 curl | 能跑通 3 个真实场景（GET+头、POST JSON、URL 续行+变量），`:Rikuesto curl` 与预期一致 |
| **M2** 规范完整度 | 脚本块解析、命名请求链、`{{%enc}}`、multipart、external body、`# @no-redirect`、extmark 状态 | fixtures 全绿；请求块内的边界情况都有诊断而非崩溃 |
| **M3** 格式化 | formatter（幂等 + conform 注册）+ JSON 保序缩进 + `@var` 对齐 | 幂等测试通过；与 kulala-fmt 共存文档就绪 |
| **M4** JS + 打磨 | node/deno harness + shims + 测试结果 UI + `??` 断言 + picker + statusline + vimdoc | JS 两条路径（node/deno）各跑通 pre-request 与 response handler；`doc/rikuesto.txt` 完成 |

---

## 17. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| `http` grammar 升级破坏节点名 | 高亮/折叠退化 | 语义解析不依赖 TS（§3）；自有 queries 用 `; extends` 且尽量少 |
| Windows 命令行 32767 字符上限 | 大 body 请求失败 | 阈值切 `--data-binary @tmp`（§7.3） |
| Windows 控制台编码干扰 JSON body | body 被破坏 | 一律 temp 文件 + `vim.uv` 二进制写（§7.3） |
| 响应体是二进制/大文件 | UI 卡死 | 只渲染前 N KB（`cfg.ui.response.max_bytes` 默认 2MB），提示「已截断」，支持 `gf` 用外部程序打开 |
| JS 运行时不存在 | F6 不可用 | `runtime=none` 降级 + 明确提示 + 文档给出 deno/node 安装建议；断言功能仍可由 `??` 覆盖 |
| 用户 env.json 里含密钥 | 泄漏到日志/剪贴板 | 掩码（§7.5/§14）；`curl_export.mask_secrets=true` 时 `***` 替换 |
| jq/oxfmt 未安装或版本过旧 | JSON/JS 格式化降级 | 三级回退（§9.3-6）：jq → 内置保序 printer；oxfmt → 原样；`:checkhealth` 明确标注 |
| jq 拒收 JSON5 风格 body（尾逗号/注释） | 该 body 不缩进 | 视为「不是严格 JSON」，原样保留并 debug 日志；不试图修复用户内容 |
| oxfmt 对 JS 片段（顶层 `return`）行为变化 | JS 块格式化失败 | 包裹 `(async function(){...})` 后再格式化；失败即原样，永不阻断保存 |
| 外部工具带自己的配置（`.oxfmtrc.json`）导致队友缩进不一致 | 格式化结果因仓库而异 | `--disable-nested-config` 或不传 `-c` 时显式固定关键选项；文档说明「JS 块格式化受仓库 oxfmt 配置影响」 |
| `jq` 本身构建不带 decnum | 大整数/`1.0` 字面量被转成 double | 启动时一次性的 **runtime probe**：`printf '{"n":1234567890123456789}' \| jq .` 比对回显是否同字串；不符则降级到内置 printer（jq manual 的 `have_decnum` 内建也可用） |
| node 的 permission model 不限制 `process.env` | 脚本能读到 shell 里的 secret | 文档写明已知边界；高敏感场景引导用 deno（`--deny-env`），或 `setup.js.clear_env = true` 时用白名单 env 启动子进程 |
| treesitter grammar 里声明的规则实际解析不出来（如 `> {%` 紧跟请求行） | 若拿 TS 当权威会静默发错请求 | 交叉校验器只报警不阻断；§3/附录 B 的用例作为回归 fixture |
| 与 kulala-fmt/conform 抢格式化 | 体验割裂 | 只注册不强占（§9.3） |
| 与 rest.nvim 冲突（同 filetype/命令） | 双插件抢 buffer | filetype 只接管 `http`/`rest`；命令用 `:Rikuesto` 命名空间；文档说明二选一 |

---

## 18. 需要确认的默认决定（我按推荐值先写进设计）

1. ~~JS 运行时优先级：deno 优先~~ → **已改为 node 优先**（`--permission` 沙箱够用，node 普及率远高），deno 作为可选第二路径。**不强制 deno**。
2. **默认跟随重定向**：`-L` 默认开，`# @no-redirect` 关闭（与 JetBrains 一致）。——推荐开。
3. **头排序**：默认不排序（头顺序有语义）。——推荐不排序。
4. **响应窗口位置**：默认右侧 `split`（JSON 树与请求正文并排更好对比）。——推荐右侧。
5. **`global.var` 的层级**：位于环境 profile 之下的「全局默认」，profile 同名覆盖（严格按 README 描述）。——推荐照此。
6. **是否额外支持 Lua 脚本块**（`> {% lua ... %}`，无运行时也能写逻辑）：不建议做；如需，放 M4 之后。
7. **JSON 格式化默认 jq、JS 格式化默认 oxfmt**（探测到才用）；jq 缺失时用内置保序 printer 兜底。**HTTP 结构层永远自写**。
8. **解析以行式 parser 为真源**，treesitter 只做高亮/折叠/注入 + 交叉校验（不再把「用 TS 解析」作为候选方案）。

---

## 附录 A：规范要点的落地清单（自查用）

- [x] 多请求文件，`###` 分隔，标题文本
- [x] `#` 与 `//` 行注释；`/* */` 块注释（解析忽略）
- [x] 请求行 `[Method] URL [HTTP-Version]`，method 缺省 GET，方法白名单
- [x] URL 续行（空白缩进 / `?` `&` 开头）
- [x] 头部 `Name: Value`，多行头值续行，空行分界
- [x] body 到 `###` 或 `>` 为止；external body `< file`
- [x] urlencoded 多行 `&` 拼接；multipart `-F`
- [x] `@var = value` 文件级 + 块级，支持嵌套引用
- [x] `{{var}}`、`{{%enc}}`、优先级、命名请求引用（子集）
- [x] 动态变量（UUID/时间戳/随机/环境）
- [x] `< {% %}` pre-request、`> {% %}` / `> ./file.js` response handler
- [x] `# @name`、`# @ref`、`# @no-redirect` 等元数据
- [ ] `{{> ./script.sh}}`（resty 扩展）、`...spread` 头（httpyac 扩展）——**明确不支持**，遇到时保留原文并提示
- [ ] VS 2022 secrets provider、Azure AD token、`$input` 交互式提示——**v1 不做**

---

## 附录 B：treesitter-http 实测证据

实验脚本与原始输出：`docs/experiments/ts-http/`（`nvim --headless -l probe2.lua` 可直接复现）。
环境：Neovim 0.12.6 + `nvim-data\site\parser\http.dll`（tree-sitter-http）+ 该 parser 自带 queries。

### B.1 干净文件（`fixture2.http`）→ 结果正确

```text
TOP-LEVEL CHILDREN (5)
  section  rows  0-17  @host = example.com\n\n# @name login\nPOST https://{{host}}/login…
  section  rows 17-19  ###\n\n
  section  rows 19-23  ### plain\nGET https://{{host}}/x\nAccept: application/json\n\n
  section  rows 23-30  ###\n\nPOST https://{{host}}/form…
  section  rows 30-36  ###\n\nPOST https://{{host}}/bin…

Q2  header name="Content-Type" value="application/json"
    header name="Authorization" value="Bearer {{token}}"
    header name="X-Trace" value="abc"
    header name="Accept" value="application/json"            ← 单请求多头：正确
Q3  json_body  rows  8-13  "{\n  \"user\": \"a\", … }\n\n"   ← 识别为 JSON 且可注入
    raw_body   rows 28-30  "a=1&b=2\n\n"
    external_body rows 35-35 "< ./payload.bin"
Q5  script parent=res_handler_script
Q7  comment name="name" value="login"
Q9  variable_declaration: @host = example.com / @version := v2
Q10 request nodes = 4（无幽灵节点）
```

### B.2 三个失败用例（`fixture.http` / `fixture3.http`）

```text
# 用例1：头值多行续行 → ERROR 级联，body 变成幽灵请求的 URL
ERROR           rows 14-17    part2\n\n{\n
request          rows 17-18    method=nil
  target_url =  "a": 1          ← body 内容被当成 URL
request          rows 18-24    method=nil
  target_url =  }
json_body       <none>
header          name="X-Long-Header" value="part1"   ← 只拿到 part1

# 用例2：外部响应脚本 → 幽灵请求
request nodes = 2
  request rows 2-3 method=GET
  request rows 3-4 method=nil
    target_url = > ./handler.js   ← 规范里的外部 handler 语法

# 用例3：raw_body / json_body 尾部吞空行
raw_body rows 28-30 "a=1&b=2\n\n"
```

### B.3 工具链实测（`stdin.txt` / `shim.txt`）

```text
[jq]     code=0  键序保持、1234567890123456789 保持、中文 ✓
[oxfmt]  code=0  const a={b:1} → const a = { b: 1 };
[oxfmt fragment] code=0 out="return response.status === 200;\n"   ← 顶层 return 不报错
[jq utf8] out={ "msg": "中文 test ✓" }
启动成本: jq 16.4 ms/次，oxfmt 77.9 ms/次
Windows shim: vim.system({'oxfmt','--version'}) code=0（exepath 解析到 oxfmt.CMD，能跑通）
vim.json roundtrip: {"z":1,"a":2,"m":3} -> {"m":3,"z":1,"a":2}   ← 键序丢失（附录 C 的动机）
```

### B.4 `>` 行前置空行是决定性条件（`probe_variants.lua` / `probe_variants2.lua`）

同一个 `> {% %}` / `> ./file.js`，**只差一个空行**，解析结果完全不同：

```text
A: `GET url` 紧接 `> ./handler.js`（无空行）
   section("GET https://e.com/1\n") request(...) target_url("https://e.com/1")
   section("> ./handler.js\n") request("> ./handler.js\n") target_url("> ./handler.js")   ← 幽灵请求

B: 同上但中间有空行
   request("GET https://e.com/1\n\n> ./handler.js\n") target_url("https://e.com/1")
   res_handler_script("> ./handler.js\n") path("./handler.js")                        ← 正确

C: headers + body + （空行）+ `> ./handler.js`
   header("Content-Type: application/json\n") raw_body("{\"a\":1}\n")
   res_handler_script("> ./handler.js\n") path("./handler.js")                        ← 正确

F: body + （空行）+ `> {%`
   raw_body("{\"a\":1}\n\n") res_handler_script("> {%\n  client.log(1);\n%}\n") script(...)  ← 正确

G: `GET url` 紧接 `> {%`（无空行，= 规范文档示范写法）
   request("> {%\n  client.log(1);\n") target_url("> {%\n  client.log(1);")
   request("%}\n") target_url("%}")                                                  ← 拆成 3 个幽灵 request

H: headers 后紧接 `> {%`（无空行）　→ 同 G，依旧幽灵 request
I/J: `< {% %}` 前置脚本，有无空行均正确（pre_request_script）   ← 不对称：`<` 不要求空行

D/E: json_body 的空白要求
   D: body = `{"a":1}`  → raw_body("{\"a\":1}\n")
   E: body = `{` + 换行 → json_body("{\n  \"a\": 1\n}\n")
```

> 与 `grammar.js` 对读：`res_handler_script: seq(">", WS, choice($.script, $.path))` **规则存在**，但实际解析被前面的 request 分支抢走。所以判断一个 grammar 能不能用，必须跑样例，不能只读语法。

---

## 附录 C：内置保序 JSON printer（jq 缺失时的唯一自写格式化代码）

为什么不用 `vim.json.decode` + `vim.json.encode` 往返：Lua table 会丢键顺序、把 `1.0` 变 `1`、把超长整数变 float。所以自写一个**只做排版**的 tokenizer：

1. 逐字符扫描（跳过字符串内的 `{ } [ ] , :` 与转义），维护深度与「是否需要换行」；
2. 遇到 `{`/`[` 换行 + 缩进 2；`}`/`]` 回缩；`,` 换行；`:` 后加一个空格；
3. 字符串原样透传（**不做** `\u` 解码/转义归一化）；数字原样透传（**不解析**为数值）。

即「不解析语义，只重排空白」，因此天然幂等且零精度损失。校验严格性由调用方决定：内部 printer 不做合法性校验（结构明显损坏时宁可不动，判定方式为「花括号/方括号不配对或字符串未闭合」→ 原样返回）。

---

## 附录 D：决策核实记录（2026-xx-xx）

核实方式：**一手文档 + 本机实测**双轨。直连 `raw.githubusercontent.com` 会 SSL 失败（`curl: (35)`），故所有外网抓取统一走本地代理 `http://localhost:7897`。实测脚本与原始输出在 `docs/experiments/ts-http/`。

### D.1 已确认（照原设计执行）

| 决策/断言 | 核实来源 | 核实结果 |
|---|---|---|
| Node `--permission` 是稳定能力，默认拒绝一切 | nodejs.org/api/permissions.html —「This feature is no longer experimental. **Stability: 2 - Stable**」「will restrict access to all available permissions」 | ✅ 成立 |
| Node 沙箱会拦 `child_process` / worker / 原生插件 / FFI / inspector | 同上限制清单 | ✅ 本地实测：`execSync` → `ERR_ACCESS_DENIED ... Use --allow-child-process` |
| Node 沙箱会拦 fs 写 | 同上 | ✅ 本地实测：`writeFileSync` → `ERR_ACCESS_DENIED` |
| Deno 默认零权限 | docs.deno.com/runtime/fundamentals/security —「Deno is secure by default… has no access to sensitive APIs」 | ✅ 本地实测：`fetch` → `NotCapable` |
| Deno `--deny-*` 存在且优先于 `--allow-*` | 同上 | ✅ 实测 `--deny-env --deny-run --deny-read` 均被接受 |
| curl `%{json}` 可用（≥7.70） | curl.se/docs/manpage.html —「A JSON object with all available keys… **(Added in 7.70.0)**」 | ✅ 本机 8.21 |
| curl `--no-progress-meter` 存在 | 同上 | ✅ |
| 多行 body 必须用 `--data-binary`，不能用 `-d @file` | 同上 —`--data`「carriage returns, newlines and null bytes are **stripped out**」；`--data-binary`「newlines and carriage returns are **preserved**」 | ✅ 强烈支撑 §7.2 的选择 |
| Windows 命令行 32,767 字符上限 | Microsoft Learn `CreateProcessW` —「The maximum length of this string is **32,767 characters**」 | ✅ 支撑 §7.3 临时文件阈值 |
| jq 保留数字字面量（大整数不变 double） | jq Manual —「includes support for **preservation of input number literals**」「`have_decnum`… literal number preserving numeric backend」 | ✅ 本机实测 `1234567890123456789` / `1.0` / `-0` 均原样 |
| jq 拒收尾逗号与注释 | 本机实测 | ✅ 作为 fail-soft 判定依据成立 |
| oxfmt 支持 JS/TS/JSX/TSX/**JSON, JSONC, JSON5**/YAML/TOML/… | oxc.rs/docs/guide/usage/formatter.html —「Support includes …」 | ✅（但见 D.2 第 2 条，因此**仍不用于 body**） |
| treesitter 查询可用 `; extends` 叠加 | neovim `runtime/doc/treesitter.txt` —`*treesitter-query-modeline-extends*` | ✅ §12 的方案可行 |
| `nvim --headless -l script.lua` 可跑测试 | neovim `runtime/doc/starting.txt` —`-l {script} [args]` | ✅ 0.12 支持，测试策略 0 依赖可行 |
| rest.nvim 依赖 LuaRocks（README 前提） | rest.nvim README：LuaRocks 徽章、`:Rocks install rest.nvim`、依赖 `nvim-nio`/`mimetypes`/`xml2lua`/`fidget.nvim`/`tree-sitter-http` | ✅ README 判断准确，绕开它对 |
| `.http` 规范细节（`###`、`{{}}`、`{{%enc}}`、`> {% %}`、`# @name`、`$random.*`、`$shared`） | http-files.org 各 spec 页（一手来源） | ✅ 与 §5–§6 一一对应 |
| `vim.json` 往返丢键顺序 | 本机实测 | ✅ `{"z":1,"a":2,"m":3}` → `{"m":3,"z":1,"a":2}`，附录 C 的动机成立 |

### D.2 核实中**发现并修正**的问题

| # | 原设计写法 | 实测/文档结论 | 修正 |
|---|---|---|---|
| 1 | deno：`deno run --quiet --no-net --no-write --no-env --no-prompt` | `--no-net` **不存在**：`error: unexpected argument '--no-net' found`（提示 `--no-npm`）。Deno 默认已全禁 | 改为「什么都不加」或 `--deny-net --deny-write --deny-env --deny-run`（`--no-prompt` 保留） |
| 2 | oxfmt 也可格式化 JSON（官网支持列表里有 JSON/JSON5） | 本机实测：单行输入的小对象被**压成一行**（`"nested": { "deep": { "k": "v" } }`），破坏 http body 可读性 | 坚持 JSON → jq；oxfmt 只做 JS。另注：JSON5 容错场景可考虑 oxfmt，但需接受压缩（v1 不做） |
| 3 | 「`> ./handler.js` grammar 不支持」 | **归因错误**。`grammar.js` 里确实有 `res_handler_script: seq(">", WS, choice($.script, $.path))`。真正的失败条件是**前面没有空行**：无空行时 `> ./handler.js` / `> {%` 被解析成幽灵 request（`target_url("> ./handler.js")`），有空行时正确产生 `res_handler_script` + `path("./handler.js")` | §3 改为「缺空行导致静默错解析」；并用规范页原文证明**规范示范写法恰是缺空行的形式**，所以该缺陷高频 |
| 4 | 「JSON body 与 `Content-Type` / 首字符判定」 | grammar 的判定是 `json_body: seq(token(/[{\[]\s+/), _raw_body)`——`{"a":1}`（花括号后无空白）**不会**成为 `json_body` 而是 `raw_body`（实测用例 D/E） | §5.5 明确：自写 parser 用 `Content-Type` + body 首个非空字符判定，比 grammar 更准 |
| 5 | §3 表里写 `json_body` 的高亮/注入粒度（未提限制） | 同 #4 | 补充说明「高亮/注入可能漏掉紧凑写法」，但不影响执行 |
| 6 | §5.5 提到 graphql 节点名 `graphql_data` | grammar 实为三层：`graphql_body` / `graphql_data` / `graphql_json_body`（后者 alias 成 `json_body`） | 文档已按实际节点名记录 |
| 7 | node 启动命令 `node --permission --allow-fs-read=<harness dir>`（当时只是"保险"） | **必需**：`node --permission entry.mjs` 能跑（入口读取被豁免），但 `import './shims/client.mjs'` 立刻 `ERR_ACCESS_DENIED` | §8.2 明确写「必需」；并给出替代方案（打单文件 harness 后可去掉该参数） |
| 8 | 未讨论脚本能否读环境变量 | node permission model 的受限清单不含 env，实测 `process.env` 可读；deno 的 `--deny-env` 能拦 | §17 新增风险行 |

### D.3 本机实测补充（无官方文档，只有可复现行为）

| 行为 | 结论 | 设计处理 |
|---|---|---|
| `vim.system({'oxfmt','--version'})` 在 Windows 上 | ✅ `code=0`，`exepath` 解析到 `oxfmt.CMD`（pnpm shim），能正常读 stdin | 仍优先解析原生 `.exe` 或 `node <pkg>/bin/oxfmt`，不依赖该行为（libuv 细节，版本可能变） |
| 工具启动成本 | jq 16.4 ms/次、oxfmt 77.9 ms/次 | 支撑 §9.3-4「并行 + 缓存」的必要性 |
| `nvim --headless -l` 跑 Lua 探测能正常读取本机 `http` parser 与 queries | ✅ | 实验脚本因此可长期保留在 `docs/experiments/` |

### D.4 结论

- 架构与技术选型**无需推翻**：行式 parser 为真源、curl 直 exec、jq/oxfmt 复用、node 优先的 JS 沙箱，四条主决策全部经得起核实。
- 修正的 8 处都是**参数级/归因级**细节，但其中 #1（deno 参数写错会导致子进程直接失败）和 #3（把「缺空行」误判成「不支持」，会让交叉校验器报错误的诊断文案）都是会真正踩到的坑。
- 最反直觉的一条：**读 grammar 源码推断「能解析什么」不可靠**（#3/#4 都是规则存在但与实际解析不一致）。这条经验本身支持了 §3 的双解析器设计。
