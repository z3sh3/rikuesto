# Brief: http（传输层）模块

Implement the **http** (transport) module of the rikuesto Neovim plugin (pure Lua, zero third-party deps).
Repo root: `D:/Project/rikuesto` (your cwd).

## Read first (mandatory)

1. `docs/INTERFACES.md` §1.6 (Response) and §5 (http API) — binding.
2. `docs/DESIGN.md` §7 in full, especially §7.2 the `.http -> curl` mapping table, §7.3 temp-file strategy, §7.5 masking, and the "three verified curl facts" box after the table (`%{json}` needs >= 7.70; `-d @file` strips CR/LF so use `--data-binary`; Windows 32767 command-line limit).
3. `docs/DESIGN.md` appendix D.2 for corrections already applied.

## Files you own (write ONLY these)

- `lua/rikuesto/http/curl.lua`, `lua/rikuesto/http/exporter.lua`, `lua/rikuesto/http/runner.lua`, `lua/rikuesto/http/response.lua`, `lua/rikuesto/http/auth.lua`
- `tests/http_spec.lua`, `tests/response_spec.lua`
- `tests/golden/curl_basic.args`, `tests/golden/curl_multipart.args` (argv golden files, one arg per line)

Do NOT modify anything outside the list (no config/util/test-runner edits). Report needed changes instead.

## curl.build(req, ctx) requirements

- Emits `{ argv, temp_files, meta }`. `argv` order: `{ curl_bin }`, `extra_args...`, flags, headers, body flags, URL last.
- Always: `-sS --no-progress-meter -D <tmp>/headers.txt -o <tmp>/body.bin -w %{json}`. Since `build()` must not write the payload, it may create the directory with `vim.fn.tempname()` + `vim.fn.mkdir(..., 'p')` and must list every path in `temp_files` with its `kind` so `runner` writes/reads/cleans them. Paths stay stable inside one `spec`.
- Method: `-X METHOD`, omitted when method is GET or HEAD **and** there is no body.
- Headers: one `-H` per header, exact `name: value`.
- Body: `raw|json|xml|graphql|urlencoded` -> `--data-raw <text>` when `#text <= ctx.inline_body_max`, else `--data-binary @<tmp>/payload.bin`; `external` -> `--data-binary @<absolute path>`; `multipart` -> one `-F name=value` per body line; `none` -> nothing.
- `http_version == 'HTTP/2'` -> `--http2`; `'HTTP/1.1'` -> `--http1.1`.
- `ctx.follow_redirects` and `req.meta.no_redirect`: add `-L` unless `no_redirect`.
- `ctx.insecure` or `req.meta.insecure` -> `-k`; `req.meta.proxy` or `ctx.proxy` -> `--proxy <url>`; `req.meta.timeout_ms` or `ctx.max_time_ms` -> `--max-time <ceil(ms/1000)>`.
- `auth.from_url(url)` pulls `user:pass@` out of the URL; callers then pass `-u user:pass`.

## runner

- `runner.run(spec, ctx, on_done)` writes pending temp files (payload body via `vim.uv` in binary mode, byte-exact UTF-8), then `vim.system(spec.argv, { text = true, timeout = ctx.max_time_ms + 5000 }, cb)`.
- Returns a job table with `:cancel()` (kill) and tracks `done`. `on_done(response, err)` receives a `Response` built by `http.response.parse`. Clean temp files unless `ctx.keep_temp_on_error`.
- Never block the event loop.

## response.parse

- Input: the three temp paths (headers, body, writeout) plus meta.
- Prefer parsing the writeout JSON object (`%{json}`): `http_code`, `time_total`, `size_download`, `content_type`, `url_effective`, `num_redirects`. Fall back to the last status line of the headers dump when that JSON is missing (curl < 7.70).
- Headers: fold the redirect chain and keep the **last** response block; handle `Name: Value` plus obs-fold continuation lines; expose ordered `headers` and `raw_headers`.
- `json` field: `pcall(vim.json.decode, body)`; `content_type` split into `{ mime, charset }`; `truncated` when `ctx.max_bytes` (default 2MB) is exceeded (body clipped, `truncated = true`).
- `error = { kind = 'timeout'|'curl'|'network', message }` when exit code/stderr says so; still fill whatever was parsed.

## exporter.to_string(argv, dialect)

- `native`: newline per argument, no quoting (safest; documented in DESIGN §7.6).
- `pwsh`: single quotes with `''` escaping. `sh`: single quotes with `'\''` escaping. `cmd`: double quotes with `^` escaping.
- `command_line(argv)` -> single-line space-joined string for logs.

## Tests

- `tests/http_spec.lua`: build argv for GET with headers, POST JSON under and over `inline_body_max`, external body, multipart body, HTTP/2, no_redirect, insecure+proxy+timeout, and `auth.from_url`. Compare complex cases with the golden files (write the goldens yourself, one argv element per line) and assert element-wise equality elsewhere.
- `tests/response_spec.lua`: build temp files by hand (headers dump with a redirect chain, JSON body, writeout JSON) and assert status/headers/json/duration/redirects; also test the missing-`%{json}` fallback and the truncation path.
- No network access in tests; no server startup.

## Verify

`nvim --headless -l tests/run.lua http` and `nvim --headless -l tests/run.lua response` from the repo root; iterate until PASS.

## Report back

Files created, final test lines, any deviation from the argv rules (with reason), anything left out.
