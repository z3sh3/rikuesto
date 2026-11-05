# AGENTS.md

Binding architecture and design requirements for **rikuesto**, a Neovim HTTP client for `.http`/`.rest`
files. This file is the global contract for any AI agent (or human) changing this repository. Read it
before writing code, and treat every rule here as a hard requirement unless a change is explicitly
approved by the maintainer.

Design rationale lives in [`docs/DESIGN.md`](docs/DESIGN.md); the frozen module API lives in
[`docs/INTERFACES.md`](docs/INTERFACES.md). When this file and those documents disagree, the newer
verified evidence wins — and all three must be updated in the same change.

---

## 1. Product scope

- An HTTP client **inside Neovim**: parse `.http` files, execute them with `curl`, render responses,
  format files, copy requests as curl commands.
- Syntax compliance targets the `.http` file specification: <https://http-files.org/guides/introduction>.
- Project name `rikuesto` is the Japanese pronunciation of "request".

### Non-goals

- No GUI, no Postman/OpenAPI collection import.
- No GraphQL/WebSocket/gRPC protocol specialisation (GraphQL only as a body kind).
- No LSP server.
- No npm packages, no LuaRocks, no vendored third-party Lua modules.

---

## 2. Non-negotiable constraints

| # | Constraint | Why |
|---|---|---|
| C1 | **Zero third-party Lua modules.** Only Neovim built-ins (`vim.system`, `vim.json`, `vim.uv`, `vim.fs`, `vim.treesitter`). | The original requirement is "introduce no external modules unless unavoidable"; `rest.nvim`'s LuaRocks dependency chain is explicitly rejected as Windows-unfriendly. |
| C2 | **External executables only, never bundled**: `curl` (required), `jq` (optional, JSON formatting), `oxfmt` (optional, JS formatting), `node` **or** `deno` (optional, JS scripts). | They are "already existing tools"; nothing is shipped or installed by the plugin. |
| C3 | **Requests always go through `curl` invoked as an argv list** (`vim.system`), never through a shell. | Eliminates PowerShell/cmd quoting bugs and the `curl` → `Invoke-WebRequest` alias trap. |
| C4 | **Windows-first.** The maintainer runs PowerShell 7; never target PowerShell 5.1, never emit PS-specific workarounds into Lua, always use `vim.fn`/`vim.fs`/`vim.uv` for paths. | Documented project environment. |
| C5 | **Never start servers, databases or browsers for testing.** The integration suite uses a public HTTP API. | Explicit project instruction. |
| C6 | **Secrets never reach logs or exported commands.** Mask everything matching `config.mask_patterns` before logging, echoing or `setreg`. | `env.json` holds real tokens on user machines. |

Optional integrations (fzf-lua, any picker/statusline plugin) must be `pcall(require, ...)`-guarded and
degrade to `vim.ui`/plain output. Never hard-require a plugin.

---

## 3. Architecture

### 3.1 Layer map and dependency direction

```text
plugin/rikuesto.lua   filetype detection + lazy :Rikuesto registration
ftplugin/http.lua     buffer-local commentstring/omnifunc/keymaps
        │
        ▼
commands.lua / keymaps.lua / health.lua / ui/*        (presentation, no I/O of its own)
        │
        ▼
exec.lua              orchestration: parse → resolve → pre-JS → curl → response → post-JS → assertions
        │
        ├── parse/*    .http → ParseResult (REQUEST STRUCTURES; no treesitter)
        ├── resolve/*  {{}} substitution, dynamic vars, percent-encoding, named-response chaining
        ├── env/*      env.json profiles and path resolution
        ├── http/*     curl argv builder, async runner, response parser, curl exporter, auth
        ├── js/*       node/deno sandbox driver + self-written single-file harness
        └── format/*   structure formatter, jq/oxfmt adapters, ordered JSON printer
```

Rules:

- Dependencies point **downward only**. `parse/`, `env/`, `resolve/` must not require `http/`, `ui/`,
  `js/` or `exec`. `http/` must not require `ui/` or `commands`.
- No cycles. If a new module needs something from above its layer, it takes it as a **parameter**
  (see `exec.lua` passing `scope`, `ctx`, `spec`).
- UI only renders; it never executes requests. `exec.lua` is the only place that sequences a run.

### 3.2 The single most important invariant: parsing

**The line-based parser in `lua/rikuesto/parse/` is the only semantic source of truth.**
Tree-sitter is used **only** for highlighting, folding, injections and a non-blocking cross-check
diagnostic.

Do not re-litigate this without new measured evidence. The rejected alternative was "parse with
`tree-sitter-http`":

- The grammar's error recovery is built for colouring, not semantics: on unsupported input it invents
  a parse instead of failing.
- Measured failures (`docs/experiments/ts-http/`): a multi-line header value becomes an `ERROR` cascade
  that turns the JSON body into phantom requests; `> {%` immediately after the request line — the
  exact form used by the spec's own examples — is split into three phantom requests; `> ./handler.js`
  becomes a `target_url`. Some cases produce **no** `ERROR` node at all, i.e. silently wrong.
- `json_body` only matches `/[{\[]\s+/`, so `{"a":1}` degrades to `raw_body`.
- Reading `grammar.js` is not enough: `res_handler_script` is defined, yet unreachable in the common
  form. Always verify grammar behaviour by running a probe.

Consequence: any new `.http` feature must be implemented in `parse/` first; treesitter queries may
never become load-bearing.

### 3.3 Frozen data structures (see `docs/INTERFACES.md`)

- `Request`, `ParseResult`, `Body`, `Script`, `Response`, `Diagnostic`.
- All rows/cols are **0-based**; ranges are `{ start_row, end_row }` with `end_row` **exclusive**.
- `ParseResult` carries `requests`, `preamble`, `file_variables`, `file_lazy_variables`, `diagnostics`.
- `Request.variables` / `Request.lazy_variables` hold block-scope `@name = value` / `@name := value`.
- Adding/renaming a field requires updating `docs/INTERFACES.md` §10 (change log) and the tests in the
  same change.

### 3.4 Variable resolution order (highest → lowest)

1. `scope.request` — pre-request script output
2. `scope.chain` — named-response references (`{{login.response.body.$.token}}`)
3. `scope.block` — `@var` inside the request block
4. `scope.file` — file-level `@var`
5. `scope.env` — active env profile over `global.var`
6. dynamic `{{$...}}`
7. unresolved → keep `{{name}}` verbatim and report `unknown` (never silently empty)

Recursion depth is capped at 10 with a visited-set cycle guard. `{{%name}}` percent-encodes after
resolution and must not double-encode `%XX`.

### 3.5 Transport rules (`lua/rikuesto/http/curl.lua`)

Baseline argv: `-sS --no-progress-meter -D <tmp>/headers.txt -o <tmp>/body.bin -w '%{json}'`, one temp
directory per request, payload written by the runner (binary, byte-exact).

| Rule | Reason (measured) |
|---|---|
| `HEAD` → `--head`, never `-X HEAD` | `-X HEAD` waits for a body that never arrives (exit 28 at `--max-time`); omitting `-X` silently becomes GET |
| Response body is cleared when `meta.method == 'HEAD'` | `--head` writes the response headers into the `-o` target |
| File bodies → `--data-binary @file` | `-d @file` strips CR/LF and NUL bytes |
| Inline bodies under `curl.inline_body_max`, files above | Windows `CreateProcessW` command line is capped at 32,767 chars |
| `%{json}` parsing with a header-dump fallback | `%{json}` requires curl ≥ 7.70 |
| `-X` omitted for bodiless GET | curl's default |
| Redirects: `-L` unless `# @no-redirect` | matches JetBrains behaviour |

`runner.lua` is asynchronous (`vim.system` callback → `vim.schedule` before touching the UI), cancels
via `job:cancel()`, and cleans temp files unless `keep_temp_on_error`.

### 3.6 JS sandbox rules (`lua/rikuesto/js/`)

- Runtime preference `auto` → **node first**, then deno. Node is not optional-by-default and **deno is
  never required**.
- node argv: `node --permission --allow-fs-read=<harness dir> harness.mjs`. The read allowance is
  mandatory because sibling `import` of shims is otherwise denied (`ERR_ACCESS_DENIED`). Granting
  `--allow-net` / fs write only follows `config.js.allow_net` / `allow_fs`.
- deno argv: `deno run --quiet --no-prompt --deny-net --deny-write --deny-env --deny-run harness.mjs`.
  **deno has no `--no-net` flag** (measured: `unexpected argument`); it denies everything by default.
- The harness is a single self-written ESM entry plus four shims; no npm dependencies. It reads one
  JSON payload on stdin and always prints exactly one JSON object on stdout — user `console.log` output
  goes to `logs`, never stdout.
- node's permission model does **not** restrict `process.env` (measured); treat "the script can read
  the shell environment" as a known boundary and prefer deno for sensitive setups.
- Payload/result field names are frozen in `docs/DESIGN.md` §8.3.

### 3.7 Formatting rules (`lua/rikuesto/format/`)

- The HTTP **structure** is always re-emitted by this plugin (no existing tool understands `.http`).
- JSON bodies go to `jq --indent 2 .` (ordered, literal-preserving); JS fences go to
  `oxfmt --stdin-filepath`, wrapped in `(async function(){...})` first.
- Never send JSON to `oxfmt`: it collapses small objects to one line (measured).
- Every external call is fail-soft: non-zero exit, empty output, or timeout keeps the fragment verbatim
  and records a diagnostic. Formatting must never abort or corrupt content.
- Invariants: **idempotent**, minimal range (bodies/fences only), and separator titles come from the
  separator line itself — never from `requests[index]` (that pairing duplicated titles in files with
  `### ====` banners; regression covered in `tests/format_spec.lua`).
- When `jq` is missing, `format/json_internal.lua` prints JSON by moving whitespace only: it never
  parses numbers, so `1.0` and big integers survive.

### 3.8 UI and command rules

- `:Rikuesto` is registered lazily by `plugin/rikuesto.lua`; `setup()` only configures.
- `<Plug>` mappings are always defined; buffer-local leader maps are added on `FileType http` unless
  `config.keymaps == false`.
- Response window is a non-modifiable scratch buffer (`filetype=rikuesto-response`, or `json`).
- Result badges are virtual text via a dedicated extmark namespace.
- `:checkhealth rikuesto` must report curl version + `%{json}` capability, jq/oxfmt presence, JS
  runtime, treesitter parser, env file state, and a parser smoke test.

---

## 4. Coding conventions

- Lua 5.1 / LuaJIT only: **no `goto`, no `//` integer division, no `table.unpack`** (use `unpack`),
  no bitwise operators.
- 4-space indentation, LF line endings, English comments and log messages.
- Modules return singleton tables. No `print()` in library code — use `rikuesto.util.log` and
  `rikuesto.util.notify`.
- Never throw from parsing, transport or sandbox paths: return `nil, err`, or a result carrying
  `diagnostics`. `pcall` is required around external tools and around optional plugin requires.
- Never touch the UI from a libuv callback: hop with `vim.schedule`.
- Do not edit files outside the module you are asked to change; report the needed change instead.

---

## 5. Verification required before finishing any change

```sh
nvim --headless -l tests/tools/syntax_check.lua      # parse-only check of every Lua file
nvim --headless -l tests/run.lua                     # unit suites (~650 assertions)
nvim --headless -l tests/smoke/run_ui.lua            # commands, keymaps, window, format idempotency
nvim --headless -l tests/integration/run_http.lua    # 18 real requests from test.http (network)
```

- Every bug fix needs a regression test in the owning `tests/*_spec.lua`.
- The integration run rewrites `docs/reports/integration.md`; commit the refreshed report only when the
  behaviour actually changed.
- Never add network access to `tests/*_spec.lua`; network belongs in `tests/integration/`.

---

## 6. Documentation map (keep in sync)

| Path | Contents |
|---|---|
| `docs/DESIGN.md` | Design, rationale, spec checklist (appendix A), treesitter evidence (B), JSON printer (C), verified-facts log (D) |
| `docs/INTERFACES.md` | Frozen module contracts and change log |
| `docs/briefs/*.md` | Per-module work orders used for the parallel build (historical) |
| `docs/reports/*.md` | Module delivery reports, integration run, summary |
| `docs/experiments/ts-http/` | Reproducible treesitter probes and raw outputs |

Behaviour change → update `docs/DESIGN.md` + `docs/INTERFACES.md` + tests in the same commit. Newly
verified external facts go into appendix D, not into scattered comments.

---

## 7. Extension points

- **New dynamic variable**: implement in `resolve/dynamic.lua` (`expand` + `names`), add a shape
  assertion in `tests/resolve_spec.lua`, mention it in `README.md`.
- **New body kind**: extend `parse/request.lua` detection, `http/curl.lua` payload mapping,
  `format/request.lua` rendering; add fixtures for all three.
- **New export dialect**: `http/exporter.lua` + a golden file under `tests/golden/`.
- **New command**: `commands.lua` handler + `:Rikuesto help` text + `keymaps.lua` `<Plug>` if it should
  be bindable.
- **New JS API**: `js/harness/shims/*.mjs` only — keep the harness single-entry and dependency-free.

---

## 8. Known, deliberate limitations (do not "fix" silently)

- JSON5-style bodies (comments, trailing commas) are left unformatted; `jq` rejects them by design.
- Not supported: resty's `{{> ./script.sh}}`, httpyac's `...spread` headers, VS 2022 secret providers,
  interactive `$input` prompts, response-handler `> ./file.js` with Lua bodies.
- Completion is `omnifunc`-only (variables, dynamic names, named responses) — there is no LSP.
- `??` assertions implement a fixed grammar (`status`, `header`, `duration`, `body` + common
  operators), not a general expression evaluator, and never use `load()`.
- The curl binary is resolved from `PATH` (override with `setup({ tools = { curl = ... } })`); on
  Windows a Git-provided curl and `System32\curl.exe` are both acceptable as long as `%{json}` works.
