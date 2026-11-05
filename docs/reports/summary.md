# rikuesto 实现总结（交付报告）

状态：**完成**。设计文档中的 M0–M3 全部落地，M4 的 JS 沙箱、断言、picker、statusline、vimdoc 之外的项也已实现并验证。

```text
语法检查   nvim --headless -l tests/tools/syntax_check.lua   →  44 文件，0 语法错误
单元测试   nvim --headless -l tests/run.lua                  → 654 assertions, 0 failures
UI 冒烟    nvim --headless -l tests/smoke/run_ui.lua         →  23 checks, 0 failures
集成测试   nvim --headless -l tests/integration/run_http.lua →  18 请求，0 failures（真实网络）
```

实现量：插件侧 6346 行（Lua + 1 个自写 ESM harness），测试侧 3065 行。

---

## 1. 代码结构

| 层 | 文件 | 说明 |
|---|---|---|
| 入口 | `plugin/rikuesto.lua`、`ftplugin/http.lua`、`lua/rikuesto/init.lua` | 文件类型检测、`:Rikuesto` 懒注册、`setup()` |
| 地基 | `config.lua`、`util/{str,log,platform,notify}.lua`、`state.lua` | 配置、日志环、平台探测、去重通知、命名响应/全局变量 |
| 解析 | `parse/{block,request,variables,metadata,scripts,cursor}.lua` | 行式 parser（唯一语义真源，不用 treesitter） |
| 变量 | `resolve/{vars,dynamic,pyencode,chain}.lua` | `{{}}` 递归替换、动态变量、百分号编码、命名请求引用 |
| 环境 | `env/{file,profile,api}.lua` | `env.json` 路径解析 / mtime 缓存 / profile 合并 / 切换 |
| 传输 | `http/{curl,runner,response,exporter,auth}.lua` | argv 构造、异步执行 + 取消、`%{json}` 解析、curl 导出、URL 凭据 |
| JS | `js/{runtime,sandbox,bridge}.lua` + `js/harness/*.mjs` | node/deno 沙箱、单文件 harness + 4 个 shim |
| 格式化 | `format/{formatter,request,tools,json_internal,js_block}.lua` | HTTP 结构自写、JSON→jq、JS 围栏→oxfmt、失败即原样 |
| 编排 | `exec.lua` | parse → resolve → pre-JS → curl → 响应 → post-JS → 断言 → 落状态 |
| UI/命令 | `commands.lua`、`keymaps.lua`、`health.lua`、`ui/*.lua` | 命令面、`<Plug>` 键位、`:checkhealth`、响应窗口、extmark、picker、statusline、omnifunc |

## 2. 用法

```lua
require('rikuesto').setup({
  env = { path = nil },              -- nil → %LOCALAPPDATA%\nvim\rikuesto\env.json
  curl = { follow_redirects = true, max_time_ms = 30000, inline_body_max = 8000 },
  js = { runtime = 'auto' },         -- auto → node，其次 deno；none 关闭
  format = { json = 'auto', js = 'auto' },
  keymaps = true,
})
```

| 命令 | 说明 |
|---|---|
| `:Rikuesto run` / `run all` / `run <name>` | 光标处 / 全文 / 按 `# @name` 执行 |
| `:Rikuesto cancel` / `repeat` | 取消在途请求 / 重跑上一次 |
| `:Rikuesto curl [native\|pwsh\|sh\|cmd]`、`curl!`、`copy` | 打印 / 复制为 curl（默认脱敏） |
| `:Rikuesto format` / `list` / `env [set\|list\|reload\|check\|edit]` / `vars` / `log` / `js` / `response` | 其余子命令 |

默认缓冲区内键位：`<localleader>rr` 运行、`ra` 全部、`rc` 复制 curl、`rf` 格式化、`re` 环境、`rl` 列表、`rx` 取消、`rv` 变量。

## 3. 测试矩阵

| 类别 | 内容 |
|---|---|
| 单元（654 assertions） | parse（含 `test.http` 全量 18 请求）、env、resolve、http argv + golden 文件、response 解析（重定向链/obs-fold/截断/错误分类）、format + json_internal（幂等、保序、大整数）、js（node/deno 沙箱、harness 往返、沙箱拦截） |
| UI 冒烟（23 checks） | 插件入口、文件类型/ftplugin、18 请求解析、键位映射、omnifunc、copy-curl、真实请求→响应窗口→extmark→状态、format 幂等、env/vars/log、health |
| 集成（18 请求） | `test.http` 全量真实请求：GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS、查询参数、多行 JSON body、201/204/404 边界；报告见 `docs/reports/integration.md` |

集成报告里每个请求都记录了状态码、耗时、字节数与判定。

## 4. 集成阶段发现并修复的缺陷

| # | 缺陷 | 证据 | 修复 |
|---|---|---|---|
| 1 | **HEAD 请求实际发成了 GET** | 集成第 15 项返回 292 字节 body；`curl -X HEAD` 实测 exit 28 挂到 `--max-time`（20s，0 字节） | 改为 `--head`，并在 `response.parse` 里按 `meta.method == 'HEAD'` 清空 body（`--head` 会把头部写进 `-o` 文件）；`http_spec` 增加断言 |
| 2 | **格式化把 `###` 标题搬到了文件开头并重复** | `test.http` 首部有 5 行 `### ====`/`### ...` 横幅，格式化后标题错位、`### REQ` 重复出现 | 根因：`build_plans` 用 `separators[index] ↔ requests[index]` 配对，横幅分隔符导致整体错位；改为直接用分隔行自身文本；`format_spec` 增加横幅 + 连续 `###` 的回归用例 |
| 3 | `tests/helper.lua` `root()` 少退一层 | 全体 worker 无法跑测试（扫到 0 spec） | `:p:h:h`（由 parse worker 报出，我修） |
| 4 | 契约缺块级变量落点 | parse worker 报出 | 增补 `Request.variables/lazy_variables`、`ParseResult.file_lazy_variables`，写入 `docs/INTERFACES.md` §10 |
| 5 | 我自己的代码用了 `//` | `tests/tools/syntax_check.lua` 抓到（LuaJIT 无整除运算符） | 改 `math.floor(x / 1e6)` |

## 5. 已知边界（有意不做 / 后续可做）

- `??` 断言只实现 `status` / `header` / `duration` / `body` 四类与常用操作符，未做完整 DSL。
- JSON5 风格 body（尾逗号、注释）不格式化（jq 拒收即原样保留）；`oxfmt` 虽支持 JSON5 但会把小对象压成单行，故不用于 body。
- 不支持 resty 的 `{{> ./script.sh}}`、httpyac 的 `...spread` 头、VS 2022 secrets provider、`$input` 交互式变量。
- 不提供 LSP；补全只做 `omnifunc`（变量名/动态变量/命名请求引用）。
- curl 二进制按 PATH 解析（本机集成时命中 Git 自带的 curl 8.23；系统 `System32\curl.exe` 8.21 同样支持 `%{json}`）。需要固定时用 `setup({ tools = { curl = '...' } })`。
- JS 沙箱：node 的 permission model 不限制 `process.env`（实测），高敏感场景请改用 deno（`--deny-env`）。

## 6. 相关文档

- 设计：`docs/DESIGN.md`（含附录 A 规范自查、B treesitter 实测、C 保序 JSON printer、D 决策核实记录）
- 契约：`docs/INTERFACES.md`
- 并行派工单：`docs/briefs/*.md`
- 各模块交付报告：`docs/reports/{parse,env-resolve,http,format,js}.md`
- 集成测试报告：`docs/reports/integration.md`
