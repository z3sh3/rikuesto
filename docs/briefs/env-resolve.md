# Brief: env + resolve 模块

Implement the **env** and **resolve** modules of the rikuesto Neovim plugin (pure Lua, zero third-party deps).
Repo root: `D:/Project/rikuesto` (your cwd).

## Read first (mandatory)

1. `docs/INTERFACES.md` — §3 (env API) and §4 (resolve API) are binding contracts; do not change names/fields.
2. `docs/DESIGN.md` §6 (variables: precedence, recursion, cycle detection) and §10 (env config: path order, schema, merge order).
3. `env.json` in the repo root — the real user config schema you must support: `{ "global": { "env": "dev", "var": {...} }, "dev": {...}, "prod": {...} }`.

## Files you own (write ONLY these)

- `lua/rikuesto/env/file.lua`, `lua/rikuesto/env/profile.lua`, `lua/rikuesto/env/api.lua`
- `lua/rikuesto/resolve/vars.lua`, `lua/rikuesto/resolve/dynamic.lua`, `lua/rikuesto/resolve/pyencode.lua`, `lua/rikuesto/resolve/chain.lua`
- `tests/env_spec.lua`, `tests/resolve_spec.lua`
- `tests/fixtures/env_basic.json`, `tests/fixtures/env_broken.json` (create them)

Do NOT modify `lua/rikuesto/config.lua`, `lua/rikuesto/util/*`, `tests/helper.lua`, `tests/run.lua`, or anything outside the list. Report needed changes elsewhere instead of editing.

## env requirements

- Path resolution order: `setup().env.path` -> `$RIKUESTO_ENV` -> `%LOCALAPPDATA%/nvim/rikuesto/env.json` on Windows, else `$XDG_CONFIG_HOME/nvim/rikuesto/env.json` (fallback `~/.config`). Use `vim.env`, `vim.fn.expand`, `vim.fs`.
- Parse with `vim.json.decode` inside `pcall`; a broken file must NOT throw: return `ok=false` plus `diagnostics` (include the decode error message) and still expose `active`/`global_var` as empty.
- Merge: `variables()` = `global.var` overridden by the active profile's keys; non-string scalars are stringified (numbers, booleans); tables are tolerated and must not break `variables()`.
- `global.env` is the default profile; `setup().env.profile` overrides it; `api.switch(name)` changes the in-memory active profile and fails with a clear error for unknown names.
- Cache by `mtime` (`vim.uv.fs_stat`) and expose `api.reload()`.

## resolve requirements

- `vars.substitute(text, scope)` -> `new_text, used[]`. Single pass over `{{ ... }}` with recursive expansion of substituted values; depth limit 10; visited-set cycle detection reported through `scope.report('cycle', { name = ... })` and the placeholder left untouched.
- Precedence (highest first): `scope.request`, `scope.chain` (named-response refs), `scope.block`, `scope.file`, `scope.env`, dynamic `{{$...}}` when `scope.dynamic`. Unknown names: leave `{{name}}` verbatim and call `scope.report('unknown', { name = name })`.
- `{{%name}}` -> percent-encode the resolved value via `pyencode.encode` (must not double-encode `%XX`).
- Do NOT substitute inside script sources — that is the caller's business; just don't crash on odd input.
- `dynamic.expand('$uuid', args)` etc. Support: `$uuid`/`$guid`, `$timestamp [offset unit]`, `$isoTimestamp`, `$datetime rfc1123|iso8601`, `$randomInt [min max]`, `$random.integer(a,b)`, `$random.float(a,b)`, `$random.alphabetic(n)`, `$random.alphanumeric(n)`, `$random.hexadecimal(n)`, `$random.email`, `$processEnv NAME`, `$env.NAME`, `$projectRoot`. Return `nil` for unknown names so callers can fall through.
- `chain.lookup(expr, named_responses)`: support `name.response.status`, `name.response.body.*`, `name.response.body.$.a.b[0]` (JSONPath subset), `name.response.headers.<Header>` (case-insensitive).

## Tests

Two spec files, each ending with `t.finish()`. Cover: env path priority (temp dir + `vim.env.RIKUESTO_ENV`), profile override of `global.var`, broken JSON diagnostics, `switch()` unknown profile, mtime reload; resolve: precedence matrix, recursion, cycle detection (assert it returns quickly), `{{%var}}` encoding, dynamic variable shapes (uuid regex, timestamp is digits, `$randomInt 1 5` in range), unknown leaves placeholder, chain JSONPath subset. Tests must not touch the network.

## Verify

`nvim --headless -l tests/run.lua env` and `nvim --headless -l tests/run.lua resolve` from the repo root; iterate until PASS.

## Report back

Files created, final test lines, contract ambiguities resolved, anything left out.
