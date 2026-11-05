# Brief: format 模块

Implement the **format** module of the rikuesto Neovim plugin (pure Lua + optional external tools).
Repo root: `D:/Project/rikuesto` (your cwd).

## Read first (mandatory)

1. `docs/INTERFACES.md` §1.2-§1.5 (Script/Body/Request/ParseResult) and §7 (format API) — binding.
2. `docs/DESIGN.md` §9 in full: the three-way split (HTTP structure = self-written; JSON = `jq`; JS fences = `oxfmt`), the invariants (idempotency, fail-soft, minimal range), the call protocol (§9.3), the structure rules table (§9.4), plus appendix C (the ordered JSON printer spec).
3. `docs/DESIGN.md` appendix D.2 items 1/2 — verified tool behaviour: `jq --indent 2 .` preserves key order and number literals; `oxfmt --stdin-filepath` formats JS but **collapses** JSON objects, hence JSON must never go through oxfmt.

## Files you own (write ONLY these)

- `lua/rikuesto/format/formatter.lua`, `lua/rikuesto/format/request.lua`, `lua/rikuesto/format/tools.lua`, `lua/rikuesto/format/json_internal.lua`, `lua/rikuesto/format/js_block.lua`
- `tests/format_spec.lua`, `tests/json_internal_spec.lua`
- `tests/fixtures/format_in.http`, `tests/golden/format_out.http`

Do NOT modify `lua/rikuesto/config.lua`, `lua/rikuesto/util/*`, `tests/helper.lua`, `tests/run.lua`, or anything outside the list. **Do not depend on `rikuesto.parse.*`**: build the `ParseResult`/`Request` tables by hand in tests (the contract is frozen), so your work does not block on another agent.

## formatter.format_lines(lines, result)

- Rebuild the buffer from the parsed structure (never regex-patch blindly): separators `###` + one space + title; request line `METHOD URL [VERSION]`; headers `Name: Value` (keep original case, one space after the colon, optional sort only when `config.format.sort_headers`); exactly one blank line before the body; at most one trailing newline per block.
- `@var` declarations: align `=` inside a contiguous group when `config.format.align_variables` (`vim.fn.strdisplaywidth`); keep `:=` as-is.
- Comment lines keep their exact text and position. Script fences (`< {%`, `%}`, `> {%`) go on their own lines and **the JS inside is delegated to `tools.oxfmt`** (wrap fragments in `(async function(){ ... })`, then strip the wrapper and re-indent by 2; if wrapping fails, try unwrapped; if that fails, keep the source untouched).
- Body: JSON -> `tools.jq` when available and `config.format.json ~= 'internal'`, else `json_internal.pretty`; xml/graphql/raw untouched; `urlencoded` keeps one pair per line with `&` prefixes.
- Fail-soft: any external tool failure/timeout/empty output keeps that fragment verbatim and records a diagnostic; never abort the whole format.
- Idempotency: `format_lines(format_lines(x).lines)` equals itself.
- Also expose `format_buffer(bufnr)` -> `ok, changed`: single `nvim_buf_set_lines` replacement; skip when unchanged; respect `vim.bo[bufnr].fileformat` (restore CRLF handling on write).

## tools

`tools.jq(text, opts)` and `tools.oxfmt(text, filetype, opts)` call `vim.system(argv, { stdin = text, text = true }):wait(config.format.tool_timeout_ms)`; resolve binaries through `require('rikuesto.util.platform').resolve_tool('jq'|'oxfmt')`; return `nil, err` on non-zero/empty/timeout. Cache results keyed by `{ tool, version, sha1(text) }` when `config.format.cache` (use `vim.fn.sha256`). `tools.available()` -> `{ jq = bool, oxfmt = bool }`.

## json_internal

A whitespace-only, order-preserving JSON pretty-printer exactly as appendix C: a character scanner that skips string contents/escapes, re-indents by `indent`, keeps numbers/strings byte-identical, and returns the input unchanged when braces/brackets are unbalanced or a string is unterminated. It must never convert `1.0` to `1` and must not lose big integers (it does not parse numbers at all).

## Tests

- `tests/json_internal_spec.lua`: nested objects/arrays, key order `{"z":1,"a":2}` preserved, `1234567890123456789` and `1.0` preserved, `\u` escapes untouched, broken JSON returned unchanged, idempotency.
- `tests/format_spec.lua`: from `tests/fixtures/format_in.http` (write it: messy spacing, mis-aligned `@var`s, a one-line JSON body, a badly indented JS fence, a `//` comment) build the Request tables by hand, format, compare with `tests/golden/format_out.http`; assert idempotency; assert fail-soft when `tools.jq` is forced to fail.
- No network. Tool tests must skip gracefully (not fail) when `jq`/`oxfmt` are absent.

## Verify

`nvim --headless -l tests/run.lua format` and `nvim --headless -l tests/run.lua json_internal` from the repo root; iterate until PASS.

## Report back

Files created, final test lines, exact tool invocation strings used, anything left out.
