# rikuesto

A focused HTTP client for Neovim that runs `.http` / `.rest` files with `curl`, straight from your
buffer. No external Lua modules, no LuaRocks, no npm — just Neovim built-ins plus the tools you already
have.

`rikuesto` is the Japanese pronunciation of the word *request*.

Repository: <https://github.com/z3sh3/rikuesto>

## Features

- **Run requests where you write them** — a cursor-based request picker, `# @name` targeting, run-all,
  cancel, and repeat.
- **Spec-shaped parsing** — strictly follows the [`.http` file specification](https://http-files.org/guides/introduction):
  `###` separators with titles, `#` and `//` comments, block comments, multi-line URLs, multi-line
  header values, url-encoded, multipart and external bodies, `@var` declarations, `# @…` metadata and
  `??` assertions.
- **Real execution through `curl`** — the parsed request is compiled into a `curl` argv list and run
  without a shell, so quoting behaves the same on Windows, macOS and Linux.
- **Environments** — profiles and shared variables from a single JSON file, with per-request override.
- **Variables** — `{{var}}`, `{{%urlEncoded}}`, dynamic helpers (`{{$uuid}}`, `{{$timestamp}}`,
  `{{$randomInt 1 100}}`, …) and named-response chaining.
- **JavaScript hooks** — pre-request scripts and response handlers (`< {% … %}` / `> {% … %}`) in a
  sandboxed Node.js or Deno runtime, with a `client` / `request` / `response` / `crypto` API.
- **Copy as `curl`** — one command away, with `native`, `pwsh`, `sh` and `cmd` quoting, secrets masked.
- **Formatting** — a canonical, idempotent layout for `.http` files; JSON bodies formatted by `jq`, JS
  fences by `oxfmt` when available.
- **Clear responses** — response window with headers and pretty body, plus a per-request inline badge
  showing status, latency and size.

## Requirements

| Component | Required | Notes |
|---|---|---|
| Neovim | yes | 0.10+ (`vim.system`, `vim.uv`); developed on 0.12.6 |
| `curl` | yes | Any recent build; 7.70+ enables exact timing metadata via `%{json}` |
| `jq` | no | JSON body formatting; without it a built-in ordered printer is used |
| `oxfmt` | no | JS fence formatting; without it fences are left untouched |
| `node` or `deno` | no | Only for `< {% … %}` / `> {% … %}` scripts; Node is preferred |
| `http` tree-sitter parser | no | Highlighting, folding and injections only; everything works without it. Highlighting is owned by your parser manager, not by this plugin (see [Syntax highlighting](#syntax-highlighting)) |

## Installation

Requirements are listed above; `curl` is the only hard dependency. The plugin itself is a plain Neovim
plugin directory — nothing to build.

### lazy.nvim

```lua
{
  'z3sh3/rikuesto',
  ft = { 'http', 'rest' },
  init = function()
    -- Neovim already maps *.http to the `http` filetype, but not *.rest. Registering the
    -- extension here makes `ft = { 'rest' }` lazy-loading work (the plugin would otherwise not
    -- be loaded yet when a .rest file is opened).
    vim.filetype.add({ extension = { rest = 'http' } })
  end,
  opts = {
    -- anything from the Configuration section; omit for defaults
  },
}
```

Prefer eager loading? Use `lazy = false` instead of `ft`/`init` — that is also fine, the plugin has no
startup cost beyond registering `:Rikuesto` and the filetype mapping.

### Built-in `vim.pack` (Neovim 0.12+)

```lua
vim.pack.add({ 'https://github.com/z3sh3/rikuesto' })
vim.filetype.add({ extension = { rest = 'http' } })
require('rikuesto').setup({})
```

### Manual install

Clone the repository into any directory on `runtimepath`, or into a package directory:

```sh
git clone https://github.com/z3sh3/rikuesto \
  "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/plugins/start/rikuesto"
```

```powershell
# PowerShell 7 on Windows
git clone https://github.com/z3sh3/rikuesto `
  "$env:LOCALAPPDATA\nvim-data\site\pack\plugins\start\rikuesto"
```

Then add setup to your `init.lua`:

```lua
vim.filetype.add({ extension = { rest = 'http' } })  -- optional, for .rest files
require('rikuesto').setup()
```

### After installing

```vim
:checkhealth rikuesto    " verifies curl, jq, oxfmt, the JS runtime and the tree-sitter parser
:Rikuesto help           " lists every command
```

`:Rikuesto` is registered by the plugin itself, so it is available even if you never call `setup()`;
`setup()` only changes defaults (and, with `keymaps`, the buffer-local mappings).

## Quick start

`api.http`:

```http
@host = https://jsonplaceholder.typicode.com

# Fetch one post
GET {{host}}/posts/1

###

# Create a post
POST {{host}}/posts
Content-Type: application/json

{
  "title": "hello",
  "userId": 1
}

> {%
  client.test("created", function () {
    client.assert(response.status === 201);
  });
%}
```

1. Put the cursor on a request and run `:Rikuesto run` (or `<localleader>rr`).
2. The response opens in a vertical split on the right; press `q` to close it.
3. `:Rikuesto curl!` copies the equivalent curl command to your clipboard.
4. `:Rikuesto format` reflows the file.

## Commands

| Command | Description |
|---|---|
| `:Rikuesto run` | Run the request under the cursor |
| `:Rikuesto run all` | Run every request in the buffer, in order |
| `:Rikuesto run <name>` | Run the request declared with `# @name <name>` |
| `:Rikuesto cancel` | Cancel the request in flight |
| `:Rikuesto repeat` | Run the previous request again |
| `:Rikuesto curl [dialect]` | Print the curl command (`auto`, `pwsh`, `sh`, `cmd`, `native`) |
| `:Rikuesto curl!` / `:Rikuesto copy` | Copy the curl command to the export register |
| `:Rikuesto format` | Format the buffer (idempotent) |
| `:Rikuesto list` | Pick a request from a list and run it |
| `:Rikuesto env` | Pick an environment profile interactively |
| `:Rikuesto env list\|reload\|check\|edit\|set <profile>` | Inspect, reload, edit or switch environments |
| `:Rikuesto vars` | Show the variables resolved for the cursor request (secrets masked) |
| `:Rikuesto js [runtime]` | Show or set the JS runtime (`auto`, `node`, `deno`, `none`) |
| `:Rikuesto response [open\|close\|last]` | Reopen or close the response window |
| `:Rikuesto response [all\|header\|body\|script]` | Show the last response in one view |
| `:Rikuesto log [clear]` | Open the diagnostic log buffer |
| `:Rikuesto help` | List the commands (also the no-argument form) |

## Keymaps

**The plugin installs no keymaps by default.** Every action is available as `:Rikuesto …` and as a
`<Plug>(rikuesto-…)` mapping, so you decide what to bind.

Bind only what you need (buffer-local, `.http` / `.rest` files):

```lua
require('rikuesto').setup({
  keymaps = {
    rr = '<Space>r', -- run the request under the cursor
    rc = '<Space>c', -- copy the request as a curl command
    re = '<Space>e', -- pick an environment profile
  },
})
```

An explicit table maps **exactly** the keys you list — nothing else. Use `keymaps = true` for the full
optional set (prefixed with `maplocalleader`), or bind the `<Plug>` mappings yourself.

| Option | Effect |
|---|---|
| `keymaps = false` | no keymaps (default) |
| `keymaps = true` | full set: `<localleader>rr` run, `ra` run all, `rc` copy as curl, `rf` format, `re` environment, `rl` list, `rx` cancel, `rv` variables |
| `keymaps = { rr = '<Space>r', … }` | only the listed actions, on the given lhs |

```lua
-- rebind with <Plug> if you prefer your own commands
vim.keymap.set('n', '<Space>r', '<Plug>(rikuesto-run)', { buffer = true })
```

### Cancelling a request

While a request is in flight the plugin installs a **temporary** buffer-local `<C-c>` mapping that
cancels it; the mapping disappears as soon as the response arrives, so no permanent shortcut is added.
Change or disable it with `cancel_key`:

```lua
require('rikuesto').setup({ cancel_key = '<C-c>' })  -- default
require('rikuesto').setup({ cancel_key = false })   -- keep <C-c> untouched
```

`:Rikuesto cancel` always works, regardless of `cancel_key` or `keymaps`.

## Configuration

```lua
require('rikuesto').setup({
  env = {
    path = nil,          -- nil -> %LOCALAPPDATA%\nvim\rikuesto\env.json (XDG elsewhere)
    profile = nil,       -- nil -> env.json global.env
  },
  tools = {
    curl = nil,          -- nil -> resolved from PATH
    jq = nil,
    oxfmt = nil,
  },
  curl = {
    extra_args = {},     -- prepended to every curl invocation
    follow_redirects = true,
    max_time_ms = 30000,
    inline_body_max = 8000,  -- larger bodies are passed via a temp file
    insecure = false,
    proxy = nil,
    keep_temp_on_error = false,
  },
  js = {
    runtime = 'auto',    -- auto (node, then deno) | node | deno | none
    timeout_ms = 3000,
    allow_net = false,   -- grant the sandbox network access
    allow_fs = false,
    pre_request_scripts = true,
    response_handlers = true,
  },
  format = {
    json = 'auto',       -- auto (jq, then built-in printer) | jq | internal
    js = 'auto',         -- auto (oxfmt) | oxfmt | none
    indent = 2,
    align_variables = true,
    sort_headers = false,
    explode_query = 'keep',
  },
  curl_export = {
    dialect = 'auto',    -- auto | pwsh | sh | cmd | native
    register = '+',
    mask_secrets = false, -- true replaces secrets with *** (the command stops running)
  },
  ui = {
    response = { layout = 'right', size = 0.5, open = 'auto', view = 'all', max_bytes = 2097152 },
    extmark = { enabled = true },
  },
  keymaps = false,          -- no shortcuts by default; true = full set, table = only those keys
  cancel_key = '<C-c>',     -- temporary in-flight cancel mapping; false disables it
  mask_patterns = { 'token', 'secret', 'password', 'authorization', 'cookie', 'api_key' },
  log = { level = 'warn', keep = 500 },
})
```

## Environments

Environment variables come from a single JSON file, by default
`%LOCALAPPDATA%\nvim\rikuesto\env.json` on Windows and `$XDG_CONFIG_HOME/nvim/rikuesto/env.json`
elsewhere. Override the location with `env.path` in `setup()` or with the `RIKUESTO_ENV` variable.

```json
{
  "global": {
    "env": "dev",
    "var": {
      "api_key": "shared-default",
      "host": "http://localhost:3000"
    }
  },
  "dev": {
    "api_key": "dev-token",
    "host": "https://dev.example.com"
  },
  "prod": {
    "api_key": "prod-token",
    "host": "https://api.example.com"
  }
}
```

- `global.env` is the profile used when nothing else is selected.
- `global.var` holds shared variables; a profile overrides the ones it redefines.
- Any other top-level key is a profile name.
- Precedence for a single request: pre-request script output → named-response references → block
  `@var` → file `@var` → environment → `{{$dynamic}}`.

## JavaScript scripting

Scripts run in a separate process, sandboxed, and are skipped with a warning when no runtime is found.

```http
< {%
  request.variables.set("ts", Date.now());
%}

POST https://example.com/signed
X-Timestamp: {{ts}}
Content-Type: application/json

{"ok": true}

> {%
  client.test("status is 200", function () {
    client.assert(response.status === 200);
  });
  client.global.set("token", response.body.token);
%}
```

Available in scripts:

- `client.test(name, fn)`, `client.assert(cond, msg)`, `client.log(text)`, `client.exit()`
- `client.global.set/get/clear/clearAll`
- `request.variables.set/get`, `request.environment.get`, `request.method`, `request.url`,
  `request.headers.all`, `request.body.getRaw()`, `request.body.tryGetSubstituted()`
- `response.status`, `response.body` (parsed JSON when applicable), `response.headers.valueOf/valuesOf`,
  `response.contentType`, `response.cookiesByName`
- `crypto.hmac.sha256(...)`, `crypto.sha256(...)`, `crypto.sha512(...)`

External scripts are supported too: `> ./handler.js` and `< ./pre.js`, resolved relative to the file.
Network and file-system access are denied unless you enable them in `setup()`.

## Copy as curl

`:Rikuesto curl` prints the command for the cursor request; `:Rikuesto curl!` (or `:Rikuesto copy`)
copies it to `curl_export.register` (default `+`). The output is a command you can paste into a shell
and run:

- the request is fully resolved first — `{{variables}}`, dynamic variables and named-response chains
  are substituted, so no `{{...}}` survives;
- **no file references**: the response-capture plumbing is stripped (`-sS`, `--no-progress-meter`,
  `-D`, `-o`, `-w '%{json}'`), and every payload is inlined as `--data-raw '...'` — including bodies
  that live in a `< ./body.json` file and bodies large enough that the plugin uses a temp file
  internally;
- **real values**: `curl_export.mask_secrets` is `false` by default, so `***` never replaces your
  credentials or JSON fields. Turn it on when the copy leaves your machine;
- **quotes only where needed**: it starts with the plain command word (`curl.exe` on Windows, `curl`
  elsewhere — never a quoted absolute path, which is a `ParserError` in PowerShell), and arguments are
  quoted only when they contain whitespace or shell metacharacters:

```text
curl.exe -L --max-time 30 https://jsonplaceholder.typicode.com/posts
curl.exe -X POST -H 'Content-Type: application/json' --data-raw '{"a":1}' https://api.example.com/x
```

Pick the quoting flavour with `:Rikuesto curl pwsh`, `:Rikuesto curl sh`, `:Rikuesto curl cmd`, or set
`curl_export.dialect`. The default `auto` is the platform shell (`pwsh` on Windows, `sh` elsewhere);
`native` prints one argument per line and is a reference listing, not a runnable command.

When a body cannot be inlined losslessly (unreadable file, NUL bytes, `-F name=@file`) the command
keeps no file reference either — you get a warning describing what was dropped. A copy longer than the
Windows 32,767-character command-line limit is still produced, with a warning.

## Syntax highlighting

Highlighting is **not** this plugin's job: it never calls `vim.treesitter.start()`. Install the `http`
parser with whatever you already use, and let that plugin own the highlighter:

```lua
require('tree-sitter-manager').setup({ ensure_installed = { 'http' } })
```

One thing to watch: Neovim does not enable tree-sitter on its own, and a parser manager only starts
doing it once its `setup()` has run. If you lazy-load your parser manager (for example on
`VeryLazy`), a `.http` file opened before that point stays unhighlighted — the plugin no longer papers
over this. Load the manager before the first file is read (`event = { 'BufReadPre', 'BufNewFile' }`) or
eagerly, and highlighting works for every buffer.

Since parsing, formatting and completion never use tree-sitter, a missing parser only means no colours.

## Response window

After a request the response opens in a split and renders the status line, headers and a pretty body
(JSON is decoded, `HEAD` responses show no body). Press `q` to close it.

### Views

The response buffer can show one block at a time. The keys below are **buffer-local**: they only exist
inside the response buffer, never in your `.http` files, and need no configuration.

| Key | View | Content |
|---|---|---|
| `A` | `all` (**default**) | status line + headers + body + `??` assertions; no script output |
| `H` | `header` | status line (`HTTP/1.1 200 OK · 132 ms · 1.2 KB`) + every response header |
| `B` | `body` | the body, JSON pretty-printed, with no `--- body ---` title line (the body fills the whole view); a clipped body starts with `(truncated)` |
| `S` | `script` | what your JS produced: `console.log` output, `client.test` results, script errors (pre-request and response-handler phases merged) |
| `J` / `K` | next / previous | walk the `header → body → script → all` order, wrapping at both ends |

The current view is also written into the buffer name (`rikuesto://response/<view>`), so the status
line shows where you are. `ui.response.view` seeds the first window of a session; after that your last
choice sticks for the next response, and `:Rikuesto response <view>` does the same thing by command
(it reopens the last response in that view when the window is closed).

```lua
require('rikuesto').setup({ ui = { response = { view = 'body' } } })
```

| `ui.response.layout` | Placement |
|---|---|
| `right` (**default**) | vertical split to the right |
| `bottom` | horizontal split below |
| `left` | vertical split to the left |
| `top` | horizontal split above |
| `float` | floating window |

`size` is the fraction of the **editor** the window takes — width for vertical layouts, height for
horizontal ones; the default `0.5` splits the screen in half. Because it is measured against
`vim.o.columns`/`vim.o.lines` and not against the current window, a sidebar makes the response look
wider than the configured fraction. Legacy values still work: `split`/`botright` mean `bottom`,
`vsplit` means `right`.

```lua
require('rikuesto').setup({ ui = { response = { layout = 'bottom', size = 0.35 } } })
```

## Formatting

`:Rikuesto format` rebuilds the file from the parsed structure: normalized separators and request
lines, one space after header colons, aligned `@var` declarations, exactly one blank line before a body.
Comments and script fences keep their content; JSON bodies are pretty-printed by `jq` (or by a built-in
printer that preserves key order and number literals), and JS fences by `oxfmt`.

Formatting is idempotent and fail-soft: if an external tool errors, times out, or returns nothing, that
fragment is left exactly as you wrote it. JSON5-style bodies (comments, trailing commas) are left alone
by design.

## Health check

```vim
:checkhealth rikuesto
```

Reports the curl binary and version, whether `%{json}` is supported, `jq`/`oxfmt` availability, the JS
runtime, the tree-sitter parser, the env file state and a parser smoke test.

## Troubleshooting

- **"no request under the cursor"** — the cursor must be inside a request block (between `###`
  separators), not on the separator line itself.
- **Scripts are skipped** — no `node`/`deno` on `PATH`, or `js.runtime = 'none'`. Check
  `:Rikuesto js` and `:checkhealth rikuesto`.
- **Timeouts** — raise `curl.max_time_ms` or add `# @timeout 60000` above the request.
- **Empty response body for HEAD** — expected: a HEAD response has no body by definition.
- **`{{name}}` left verbatim** — the variable is not defined in any scope; `:Rikuesto vars` shows what
  was resolved.
- **No syntax highlighting** — the `http` tree-sitter parser is missing (`:checkhealth rikuesto`
  reports it), or your parser manager had not run `setup()` yet when the buffer was opened. The
  plugin never starts tree-sitter: requests and formatting keep working either way.

## Development

```sh
nvim --headless -l tests/tools/syntax_check.lua    # syntax check every Lua file
nvim --headless -l tests/run.lua                   # unit suites
nvim --headless -l tests/smoke/run_ui.lua          # command, keymap and window smoke test
nvim --headless -l tests/integration/run_http.lua  # 18 real requests from test.http (network)
```

## Limitations

- No LSP; completion is `omnifunc`-based (variables, dynamic names, named responses).
- Not supported: resty's `{{> ./script.sh}}`, httpyac's `...spread` headers, VS 2022 secret providers,
  interactive `$input` prompts.
- `??` assertions cover a fixed grammar (`status`, `header`, `duration`, `body` with the common
  operators), not arbitrary expressions.
- GraphQL, WebSocket and gRPC get no protocol-level features; GraphQL is a body kind only.

## Documentation

- Repository: <https://github.com/z3sh3/rikuesto>
- [`AGENTS.md`](AGENTS.md) — architecture and design requirements (the binding contract for changes)
- [`docs/DESIGN.md`](docs/DESIGN.md) — design, rationale, measurements and the verified-facts log
- [`docs/INTERFACES.md`](docs/INTERFACES.md) — frozen module APIs
- [`docs/reports/summary.md`](docs/reports/summary.md) — delivery summary and test matrix
