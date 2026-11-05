# Brief: js 沙箱子系统

Implement the **js** sandbox subsystem of the rikuesto Neovim plugin (Lua driver + one self-written JS harness; no npm packages).
Repo root: `D:/Project/rikuesto` (your cwd).

## Read first (mandatory)

1. `docs/INTERFACES.md` §6 (js API) and `docs/DESIGN.md` §8.3 — binding field names for the payload in both directions.
2. `docs/DESIGN.md` §8 in full, especially §8.2 and its "three parameter details verified by measurement" list:
   - node needs `--permission --allow-fs-read=<harness dir>` because sibling `import` is blocked otherwise (measured `ERR_ACCESS_DENIED`).
   - deno has **NO** `--no-net` flag (measured `error: unexpected argument`); deno denies everything by default, so just don't grant, or use `--deny-net --deny-write --deny-env --deny-run`.
   - node's permission model does NOT restrict `process.env` (measured) while deno's `--deny-env` does.
3. `docs/DESIGN.md` appendix D.2/D.3 for the rest of the verified behaviour.

## Files you own (write ONLY these)

- `lua/rikuesto/js/runtime.lua`, `lua/rikuesto/js/sandbox.lua`, `lua/rikuesto/js/bridge.lua`
- `lua/rikuesto/js/harness/harness.mjs`
- `lua/rikuesto/js/harness/shims/client.mjs`, `shims/response.mjs`, `shims/request.mjs`, `shims/crypto.mjs`
- `tests/js_spec.lua`
- `tests/fixtures/js_payload.json` (sample payload for the harness round trip)

Do NOT modify `lua/rikuesto/config.lua`, `lua/rikuesto/util/*`, `tests/helper.lua`, `tests/run.lua`, or anything outside the list. Report needed changes instead of editing.

## runtime.lua

- `runtime.available()` -> `'node'|'deno'|nil`, honouring `config.js.runtime` (`auto` -> node first, then deno).
- `sandbox.argv(kind, harness_path)` builds the argv:
  - node: `{ node, '--permission', '--allow-fs-read=' .. harness_dir, harness_path }` (add `--allow-net` only when `config.js.allow_net`; grant fs write only when `config.js.allow_fs`);
  - deno: `{ deno, 'run', '--quiet', '--no-prompt', '--deny-net', '--deny-write', '--deny-env', '--deny-run', harness_path }`, granting with `--allow-*` only when the config allows it.
- `runtime.run(payload, opts)` -> `result|nil, err`: encode the payload with `bridge.encode`, run `vim.system(argv, { stdin = text, text = true, timeout = opts.timeout_ms })`, synchronously wait (only used right before/after a request, never on a hot path), parse stdout as JSON, and map failures: non-zero exit -> `nil, stderr`; unparsable stdout -> `nil, ('harness returned non-JSON: %s'):format(stdout)`. Merge `result.logs` into `require('rikuesto.util.log')` at debug level.
- `runtime.describe()` -> `{ runtime, bin, version, sandbox = true|false }` (use `util.platform.tool_version`).

## harness.mjs (single entry, ESM)

- Reads the whole payload from **stdin**, runs the user script inside a `new Function`/`AsyncFunction` sandbox with the shims in scope, and always prints exactly one JSON object on stdout. Wrap everything in try/catch and never let the process die: on error emit `{ vars:{}, globals:{}, logs:[], tests:[], errors:[{ message, stack }] }`.
- `phase === 'pre'`: expose `request` (`variables.set/get` backed by a local Map seeded from `payload.vars`, `environment.get`, `headers.all`, `method`, `url`, `body.getRaw()`, `body.tryGetSubstituted()`) and `client.log/test/assert/exit`. Return `vars`/`globals`.
- `phase === 'post'`: expose `response` (`.status`, `.body` auto-`JSON.parse`d when the content type is JSON, `.headers.valueOf/valuesOf`, `.contentType`, `.cookiesByName`), `client.test(name, fn)` collecting pass/fail instead of throwing, `client.assert`, `client.global.set/get/clear/clearAll`, `client.global.headers.set`, `client.log`, `client.exit()`.
- `crypto.mjs`: `crypto.hmac.sha256(...)`, `sha256`, `sha512` via `node:crypto` (works on deno too through the node compat layer).
- Everything the user script prints must go to `logs`, not stdout — stdout stays pure JSON.

## bridge.lua

`encode(value)` -> JSON string (via `vim.json.encode` guarded by `pcall`), `decode(text)` -> `value|nil, err`, `base64_encode/decode` (use `vim.base64` if present, else a small pure-Lua fallback).

## Tests

`tests/js_spec.lua` (ends with `t.finish()`):

1. `runtime.available()` returns node or deno on this machine; if neither exists, record a note and skip the rest **without failing** the suite.
2. Pre-request round trip: script sets `request.variables.set('sig', 'abc')` -> `result.vars.sig == 'abc'`.
3. Post round trip: `client.test('status', () => client.assert(response.status === 200))` -> `tests[1].pass == true`; a failing assert -> `pass == false` while the harness still exits 0.
4. `crypto.hmac.sha256('k','x')` returns a 64-char hex string.
5. A throwing script -> `errors` non-empty, exit code 0.
6. Sandbox proof: a script calling `require('fs').writeFileSync(...)` (or `import('node:fs')`) must fail or be blocked, never silently succeed.
7. stdout purity: the result parses even when the script logs plenty of text.

Call the harness through `runtime.run` with a hand-built payload (do not depend on other rikuesto modules).

## Verify

`nvim --headless -l tests/run.lua js` from the repo root; iterate until PASS. node 26 and deno 2.9 are installed on this machine.

## Report back

Files created, final test lines, the exact argv used per runtime, what the sandbox actually blocks (measured), anything left out.
