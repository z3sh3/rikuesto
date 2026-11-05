# Brief: parse 模块

Implement the **parse** module of the rikuesto Neovim plugin (pure Lua, zero third-party deps).
Repo root: `D:/Project/rikuesto` (your cwd).

## Read first (mandatory)

1. `docs/INTERFACES.md` — the interface contract. Data structures §1.2/§1.3/§1.4/§1.5 and API §2 are binding; do not change field names.
2. `docs/DESIGN.md` §5 (parser design) and appendix A (spec checklist). §3 explains WHY treesitter must NOT be used for semantics: **do not call any treesitter API here**.
3. `docs/experiments/ts-http/fixture.http`, `fixture2.http`, `fixture3.http` — real spec samples (multi-line URL, multi-line header value, external body, pre/post scripts, `# @name`).
4. `test.http` in the repo root — the integration corpus you must be able to parse (15 requests, `@base` file variable, `### ---- title` separators, methods GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS, multi-line JSON bodies, trailing `###`).

## Files you own (write ONLY these)

- `lua/rikuesto/parse/block.lua` — `block.parse(lines) -> ParseResult`; `block.request_at(result, row) -> Request|nil`
- `lua/rikuesto/parse/request.lua` — `request.parse_chunk(chunk) -> Request|nil, diagnostics`
- `lua/rikuesto/parse/variables.lua`
- `lua/rikuesto/parse/metadata.lua`
- `lua/rikuesto/parse/scripts.lua`
- `lua/rikuesto/parse/cursor.lua`
- `tests/parse_spec.lua`
- `tests/fixtures/parse_basic.http`, `tests/fixtures/parse_edge.http` (create them)

Do NOT modify `lua/rikuesto/config.lua`, `lua/rikuesto/util/*`, `tests/helper.lua`, `tests/run.lua`, or any file outside the list. If you believe another file must change, report it instead of editing it.

## Behaviour requirements (all tested)

- `###` separators (3+ `#`); trailing text on the separator line is the NEXT block's `title`. Blank lines and comments around separators are tolerated. A `###` at EOF must not create an empty request.
- Comments `#` and `//`; block comments `/* ... */` (skip lines, never end a body early because of them).
- Request line `[Method] URL [HTTP-Version]`; method defaults to `GET` and is upper-cased; accept GET HEAD POST PUT DELETE CONNECT PATCH OPTIONS TRACE PROPFIND LOCK UNLOCK MKCOL COPY MOVE SEARCH REPORT.
- URL continuation: following lines that begin with whitespace, or with `?`/`&`, are appended (joined without the leading whitespace). Only while still in the request-line section.
- Headers `Name: Value`, one per line. Header-value continuation: a following line starting with whitespace is appended to the previous header value with a single space. Blank line ends the header section.
- Body: everything after the first blank line until the next `###` or a `>` handler line. `body.kind` is decided by `# @lang`, else `Content-Type` (json/xml/graphql/urlencoded/multipart), else first non-space char (`{`/`[` -> json, `<` -> xml), else `raw`. `external` when the body is a single line `< ./path`. Keep `body.text` byte-exact (no trimming of internal content).
- Scripts: `< {% ... %}` (pre), `> {% ... %}` (post), `> ./file.js` (post, `file`), `< ./file.js` (pre, `file`). Compute `offset` correctly. **Important**: a handler line works with OR without a preceding blank line — see DESIGN §3 evidence.
- Variables: `@name = value` and `@name := value` (lazy flag), at file level (before the first request) and inside a request block; file-level ones go to `ParseResult.file_variables`.
- Metadata comments `# @name`, `# @ref`, `# @no-redirect`, `# @no-cookie-jar`, `# @insecure`, `# @timeout <ms>`, `# @proxy <url>`, `# @lang <lang>`; unknown `@xxx` goes to `meta.raw`.
- Assertions: lines starting with `?? ` inside a block collect into `assertions` (row + raw).
- Parser NEVER throws: malformed input produces `Diagnostic` entries (severity `error`/`warning`) with 0-based row/col and `code` like `parse.no_url`.
- `range` fields: `{ start_row, end_row }`, end exclusive, 0-based. `url_line` = row of the request line.

## Tests

`tests/parse_spec.lua` must use `require('tests.helper')` and end with `t.finish()`. Cover at minimum: basic single request; multi-request with titles; method default; URL continuation (both styles); header continuation; body kind detection for json/xml/urlencoded/external/multipart; `@var` and `:=`; all metadata keys; pre/post scripts with and without blank line; `> ./file.js`; assertions; empty file; only-preamble file; CRLF tolerance; and **the full `test.http`** (assert 15 requests, method sequence, that each POST has `Content-Type: application/json` and a `body.text` starting with `{`, and that `{{base}}` stays unresolved in `url`).

## Verify

Run `nvim --headless -l tests/run.lua parse` from the repo root and iterate until it prints PASS with 0 failures. Do not start servers, do not use the network, do not use treesitter.

## Report back

List the files you created, the final test output line(s), any contract ambiguity you resolved (and how), and anything you deliberately left out.
