# 模块接口契约（INTERFACES）

> 并行开发的唯一契约。任何模块**只依赖本文件 + `docs/DESIGN.md`**，不假设其他模块的内部实现。
> 数据结构只用 Lua table（无 class/元表魔法），字段名严格按本文。

## 0. 全局约定

- 所有模块返回单例 table：`local M = require('rikuesto.xxx'); M.fn(...)`。
- 行列号统一 **0-based**（与 nvim API 一致）；对外展示时 +1。
- 不抛异常（除 `util/str` 等纯函数）：失败返回 `nil, err`，或在结果里带 `diagnostics`。
- 不直接 `print`；用 `require('rikuesto.util.log')` / `util/notify`。
- 外部命令一律 `vim.system(argv, { text = true })`，不经 shell。
- 已存在的地基（**不要修改**，只用）：
  - `rikuesto.config` — `get()` / `setup(opts)` / `defaults`
  - `rikuesto.util.str` — `trim,ltrim,rtrim,is_blank,starts_with,ends_with,has_leading_ws,indent_width,percent_encode,lines,join,split,rep,mask,short`
  - `rikuesto.util.log` — `debug/info/warn/error(fmt,...)`, `entries()`, `clear()`, `dump()`
  - `rikuesto.util.platform` — `is_windows`,`exepath`,`resolve_tool(kind)`,`tempdir`,`joinpath`,`read_file`,`tool_version(argv)`
  - `rikuesto.util.notify` — `info/warn/error(msg, opts)`
  - `tests.helper` — `module(name)`,`ok`,`eq`,`ne`,`same`,`contains`,`matches`,`fails`,`fixture`,`fixture_text`,`finish`

## 1. 数据结构

### 1.1 Diagnostic

```lua
{ row = 0, col = 0, severity = 'error'|'warning'|'info', message = 'string', code = 'parse.xxx' }
```

### 1.2 Script

```lua
{
  lang = 'javascript',
  source = '...',        -- 围栏内原始文本（不含 {% %}）
  file = nil,            -- 外部脚本路径（> ./handler.js 时为 './handler.js'）
  post = true,           -- true = response handler；false = pre-request
  offset = { row = 0, col = 0 },  -- source 第一行在 buffer 中的位置（用于报错定位）
}
```

### 1.3 Body

```lua
{
  kind = 'none'|'raw'|'json'|'xml'|'graphql'|'urlencoded'|'multipart'|'external',
  text = '...',          -- kind ~= 'external' 时的原始文本（不做 trim）
  file = nil,            -- kind == 'external' 时的路径
  range = { start_row = 0, end_row = 0 },  -- 0-based，含首行不含末行（end_row 为独占）
}
```

### 1.4 Request（parse 模块的输出，也是 curl/format/js 的输入）

```lua
{
  index = 1,                 -- 文件内序号（1-based，按出现顺序）
  name = nil,                -- # @name xxx
  ref = nil,                 -- # @ref xxx
  title = nil,               -- ### 之后的标题文本
  method = 'GET',            -- 缺省 GET，始终大写
  url = 'https://...',       -- 原样（可能含 {{}}），多行 URL 已拼接
  http_version = nil,        -- 'HTTP/2' / 'HTTP/1.1' / nil
  headers = { { name = 'Content-Type', value = 'application/json', row = 5 }, ... },
  body = Body|nil,
  scripts = { pre = Script[], post = Script[] },
  assertions = { { row = 9, raw = '?? status == 200' }, ... },
  variables = { ['base'] = 'https://x' },      -- 块内 @var = value
  lazy_variables = { ['ts'] = true },          -- 块内 @var := value（仅标记哪些是 lazy）
  meta = {
    no_redirect = false, insecure = false, timeout_ms = nil, proxy = nil,
    lang = nil,              -- # @lang json 覆盖 body 类型判定
    raw = {},                -- 其它未识别 @xxx：name -> value
  },
  range = { start_row = 0, end_row = 0 },  -- 整块（从块内容首行到末行，独占）
  url_line = 0,              -- 请求行所在 row
}
```

### 1.5 ParseResult（`parse.block.parse(lines)` 的返回）

```lua
{
  requests = Request[],
  preamble = {                    -- 文件级前言（第一个 ### 之前）
    variables = { ['base'] = 'https://x' },
    lazy_variables = { ['ts'] = true },   -- @var := value
    scripts = { pre = Script[] },  -- 文件级 < {% %}
    meta = {},
  },
  file_variables = { [name] = 'string' },   -- 所有文件级 @var
  file_lazy_variables = { [name] = true },  -- 文件级 @var := value
  diagnostics = Diagnostic[],
}
```

### 1.6 Response（`http.response.parse(...)` 的返回）

```lua
{
  ok = true,
  status = 200, reason = 'OK', http_version = '1.1',
  headers = { { name = 'Content-Type', value = 'application/json' }, ... },
  body = '...',                  -- 原始文本（可能被截断）
  truncated = false,
  json = <decoded table>|nil,
  content_type = { mime = 'application/json', charset = 'utf-8' },
  duration_ms = 123.4, size = 292, url_effective = 'https://...', redirects = 0,
  raw_headers = '...',
  error = nil,                   -- 失败时 { kind = 'timeout'|'curl'|'network', message = '...' }
}
```

## 2. parse 模块（`rikuesto.parse.*`）

```lua
local block = require('rikuesto.parse.block')
local result = block.parse(lines)      -- lines: string[] (0-based buffer lines) -> ParseResult
local req = block.request_at(result, row)   -- 光标所在 row -> Request|nil

local cursor = require('rikuesto.parse.cursor')
local req = cursor.request_at(result, row)  -- 同上（薄封装，便于 UI 用）

-- 子模块（内部可自由拆分，但必须导出）
-- scope 是可选 out-table：收集文件级结构（@var / < {% %} / meta），供 block 合并进 preamble
require('rikuesto.parse.request').parse_chunk(chunk, scope) -- -> Request|nil, diagnostics
require('rikuesto.parse.variables').parse_line(line)  -- -> { name=..., value=..., lazy=bool }|nil
require('rikuesto.parse.metadata').parse_line(line)   -- -> { key=..., value=... }|nil
require('rikuesto.parse.scripts').parse_fence(lines, row) -- -> Script|nil, next_row
```

必须覆盖：`###` 分隔+标题、`#`/`//` 注释、`/* */` 块注释、请求行缺省 GET、
URL 续行（空白开头或以 `?`/`&` 开头）、头部与头部续行、空行分界、
body 类型判定（按 `Content-Type` + 首字符，**不依赖 treesitter**）、
`< {% %}` / `> {% %}` / `> ./file.js` / `< ./file`、`@var = v` / `@var := v`、
`# @name` / `# @ref` / `# @no-redirect` / `# @insecure` / `# @timeout` / `# @proxy` / `# @lang`、
`?? ...` 断言行。

## 3. env 模块（`rikuesto.env.*`）

```lua
local env_file = require('rikuesto.env.file')
env_file.load(path_opt)   -- -> { path=..., profiles={...}, active='dev', global_var={...},
                          --      defaults={...}, diagnostics={...}, ok=bool }

local api = require('rikuesto.env.api')
api.reload()                  -- 强制重新读取
api.path()                    -- 生效路径
api.active()                  -- 当前 profile 名
api.switch(name)              -- -> ok, err
api.list()                    -- -> string[] profile 名
api.variables()               -- -> { [name] = string }  （global.var 被 profile 同名覆盖）
api.get(name)                 -- -> string|nil
api.defaults()                -- -> table（global.defaults）
```

优先级：`profile 段` 覆盖 `global.var`；`setup().env.profile` > `global.env`。
路径顺序：`setup().env.path` > `$RIKUESTO_ENV` > 默认 `%LOCALAPPDATA%/nvim/rikuesto/env.json`（非 Windows：`$XDG_CONFIG_HOME/nvim/rikuesto/env.json`）。

## 4. resolve 模块（`rikuesto.resolve.*`）

```lua
local vars = require('rikuesto.resolve.vars')

--- 单遍+递归替换，带环检测；返回替换后的文本与被用到的变量名。
vars.substitute(text, scope)  -- -> string, used_vars[]

--- scope（全部可选）：
--- {
---   env = { [name]=value },        -- env profile + global.var（低优先级）
---   file = { [name]=value },       -- 文件级 @var
---   block = { [name]=value },      -- 请求块内 @var
---   request = { [name]=value },    -- pre-request script 产出（最高）
---   chain = { [name] = Response }, -- 命名请求引用 ({{login.response.body.$.token}})
---   dynamic = true,                 -- 允许 {{$uuid}} 等
---   report = function(kind, info) end,  -- 未解析/循环等回调用
--- }

local dynamic = require('rikuesto.resolve.dynamic')
dynamic.expand(name, args)      -- '$uuid' 等 -> string|nil（nil 表示不认识）
dynamic.names()                 -- -> string[] 支持的动态变量名

local chain = require('rikuesto.resolve.chain')
chain.lookup(expr, named_responses)  -- 'login.response.body.$.token' -> value|nil

local pencode = require('rikuesto.resolve.pyencode')
pencode.encode(value)               -- 百分号编码
```

`{{$uuid}}`、`{{$guid}}`、`{{$timestamp [offset unit]}}`、`{{$isoTimestamp}}`、
`{{$datetime rfc1123|iso8601}}`、`{{$randomInt [min max]}}`、`{{$random.integer(a,b)}}`、
`{{$random.float(a,b)}}`、`{{$random.alphabetic(n)}}`、`{{$random.alphanumeric(n)}}`、
`{{$random.hexadecimal(n)}}`、`{{$random.email}}`、`{{$processEnv NAME}}`、`{{$env.NAME}}`、
`{{$projectRoot}}`。

## 5. http 模块（`rikuesto.http.*`）

```lua
local curl = require('rikuesto.http.curl')

--- req 必须是「已 resolve」的快照（url/headers/body.text 已无 {{}}）
--- ctx: { curl_bin, follow_redirects, max_time_ms, insecure, proxy, extra_args,
---        inline_body_max, tmpdir, body_tempdir }
--- 返回：{ argv = string[], temp_files = { { path=..., kind='body'|'headers'|'output' } },
---          meta = { inline_body=bool, method=..., has_body=bool } }
--- 生成的文件写入由 runner 负责（curl.build 只声明需要哪些临时文件并填好路径）
curl.build(req, ctx)   -- -> spec

local exporter = require('rikuesto.http.exporter')
exporter.to_string(argv, 'native'|'pwsh'|'sh'|'cmd')   -- -> string
exporter.command_line(argv)                            -- -> string（native 空间分隔，用于日志）

local runner = require('rikuesto.http.runner')
--- async 执行；返回 { cancel = function(), done = boolean }
local job = runner.run(spec, ctx, function(response) ... end)
job:cancel()

local response = require('rikuesto.http.response')
response.parse(paths, meta)   -- -> Response（paths: { headers=..., body=..., writeout=... }）

local auth = require('rikuesto.http.auth')
auth.from_url(url)            -- -> { user, pass, clean_url }|nil
```

**argv 规则（必须与 DESIGN §7.2 一致）**：
`-sS --no-progress-meter -D <headers> -o <body> -w '%{json}'`；
method 用 `-X`（GET/HEAD 且无 body 时省略）；header 用 `-H`；
body ≤ `inline_body_max` 用 `--data-raw`，否则 `--data-binary @<tmp>`；
`external` body 用 `--data-binary @<file>`；`multipart` 用 `-F`；
`http_version == 'HTTP/2'` → `--http2`；`HTTP/1.1` → `--http1.1`；
`follow_redirects` → `-L`；`insecure` → `-k`；`proxy` → `--proxy <url>`；
`--max-time` 用秒（ceil）。

## 6. js 模块（`rikuesto.js.*`）

```lua
local runtime = require('rikuesto.js.runtime')
runtime.available()      -- -> 'node'|'deno'|nil
runtime.describe()       -- -> { runtime='node', bin='...', version='...', sandbox=true }
runtime.run(payload, opts)   -- 同步等待，opts={timeout_ms}
                             -- -> result|nil, err  （result 字段见 DESIGN §8.3）

local bridge = require('rikuesto.js.bridge')
bridge.encode(value)     -- -> string（JSON）
bridge.decode(text)      -- -> value|nil, err
bridge.base64_decode(b64)
bridge.base64_encode(str)
```

`payload`（Lua → JS）与 `result`（JS → Lua）字段严格按 DESIGN §8.3：
`phase/script/meta/request/response/vars/globals/limits` →
`vars/globals/headerOverrides/bodyOverride/logs/tests/errors`。

harness 位于 `lua/rikuesto/js/harness/harness.mjs`（单文件入口），
`shims/` 下为同名子模块；入口通过 `--allow-fs-read` 或单文件打包读取。

## 7. format 模块（`rikuesto.format.*`）

```lua
local formatter = require('rikuesto.format.formatter')
formatter.format_lines(lines, result)     -- -> { lines = string[], changed = bool, diagnostics = {} }
formatter.format_buffer(bufnr)            -- -> ok, changed

local tools = require('rikuesto.format.tools')
tools.jq(text, opts)              -- -> string|nil, err
tools.oxfmt(text, filetype, opts) -- -> string|nil, err
tools.available()                 -- -> { jq=bool, oxfmt=bool }

local json_internal = require('rikuesto.format.json_internal')
json_internal.pretty(text, indent)  -- -> string（保序、无精度损失；失败原样返回）
```

外部工具调用必须：`vim.system(argv, { stdin = text, text = true })`，
非 0 / 空输出 / 超时 → 返回 `nil, err`（调用方保留原文）。

## 8. ui 模块（`rikuesto.ui.*`）

```lua
require('rikuesto.ui.response_win').open(response, ctx)   -- ctx={ method=, url=, duration_ms= }
require('rikuesto.ui.response_win').close()
require('rikuesto.ui.extmark').set_result(bufnr, request, response)
require('rikuesto.ui.extmark').clear(bufnr)
require('rikuesto.ui.picker').list(requests, on_select)
require('rikuesto.ui.statusline').component()             -- lualine 组件
```

## 9. 测试约定

- 每个模块自带 `tests/<module>_spec.lua`，文件内 `local t = require('tests.helper')`，
  开始 `t.module('parse.request')`，结束 `t.finish()`。
- fixture 放 `tests/fixtures/`，黄金文件放 `tests/golden/`。
- 运行全部：`nvim --headless -l tests/run.lua`；只跑一个：`... tests/run.lua parse`。
- 语法检查（不执行）：`nvim --headless -l tests/tools/syntax_check.lua`。
- 测试**不得联网**；需要网络的放在 `tests/integration/` 且由人工/显式触发。

## 10. 变更记录（契约修订）

| 日期 | 变更 | 理由 |
|---|---|---|
| 本次 | `Request` 增补 `variables` / `lazy_variables`；`ParseResult` 增补 `file_lazy_variables`，`preamble.lazy_variables`；`request.parse_chunk(chunk, scope)` 增加可选 out-table | 块级 `@var` 与 `:=` 必须有落点（DESIGN §6.1 优先级 3） |
| 本次 | `tests/helper.lua` `root()` 修正为 `:p:h:h` | 原实现指向仓库父目录，导致 `tests/run.lua` 扫到 0 个 spec |
