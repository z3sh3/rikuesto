-- curl argv construction, "copy as curl" rendering and URL credentials.
-- Pure assertions: nothing here spawns a process or touches the network.
local t = require('tests.helper')
local curl = require('rikuesto.http.curl')
local exporter = require('rikuesto.http.exporter')
local auth = require('rikuesto.http.auth')

local function context(overrides)
    local ctx = {
        curl_bin = 'curl',
        follow_redirects = true,
        max_time_ms = 30000,
        insecure = false,
        proxy = nil,
        extra_args = {},
        inline_body_max = 8000,
        tmpdir = vim.fn.tempname(),
    }
    for key, value in pairs(overrides or {}) do
        ctx[key] = value
    end
    return ctx
end

local function temp_path(spec, kind)
    for _, file in ipairs(spec.temp_files) do
        if file.kind == kind then
            return file.path
        end
    end
    return nil
end

local function temp_dir(spec)
    return vim.fn.fnamemodify(temp_path(spec, 'headers'), ':h')
end

local function cleanup(spec)
    local dirs = { temp_dir(spec) }
    for _, file in ipairs(spec.temp_files) do
        local dir = vim.fn.fnamemodify(file.path, ':h')
        if dir ~= dirs[1] then
            dirs[#dirs + 1] = dir
        end
    end
    for _, dir in ipairs(dirs) do
        pcall(vim.fn.delete, dir, 'rf')
    end
end

local function normalized(spec)
    local dir = temp_dir(spec)
    local out = {}
    for index, arg in ipairs(spec.argv) do
        out[index] = (arg:gsub(vim.pesc(dir), '<tmp>'))
    end
    return out
end

local function golden(name)
    local path = t.root() .. '/tests/golden/' .. name
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        error(('missing golden %s (%s)'):format(name, path))
    end
    return lines
end

local function index_of(argv, value)
    for index, arg in ipairs(argv) do
        if arg == value then
            return index
        end
    end
    return nil
end

local function flag_value(argv, flag)
    local index = index_of(argv, flag)
    return index and argv[index + 1] or nil
end

t.module('http.curl')

-- GET: no -X, redirects on, one -H per header (argv golden).
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://api.example.com/users',
        headers = {
            { name = 'Accept', value = 'application/json' },
            { name = 'X-Trace', value = 'abc' },
        },
        meta = {},
    }, context())
    t.same(golden('curl_basic.args'), normalized(spec), 'GET argv matches tests/golden/curl_basic.args')
    t.eq(spec.meta.method, 'GET', 'meta.method is GET')
    t.eq(spec.meta.has_body, false, 'meta.has_body is false')
    t.eq(spec.meta.inline_body, false, 'meta.inline_body is false')
    t.eq(#spec.temp_files, 3, 'declares headers + output + writeout temp files')
    t.eq(vim.fn.isdirectory(temp_dir(spec)), 1, 'scratch directory exists for -D/-o')
    cleanup(spec)
end

-- POST with a small JSON body: --data-raw, no temp payload file.
do
    local spec = curl.build({
        method = 'POST',
        url = 'https://api.example.com/items',
        headers = { { name = 'Content-Type', value = 'application/json' } },
        body = { kind = 'json', text = '{"name":"rikuesto"}' },
        meta = {},
    }, context())
    t.same({
        'curl', '-sS', '--no-progress-meter',
        '-D', temp_path(spec, 'headers'),
        '-o', temp_path(spec, 'output'),
        '-w', '%{json}',
        '-X', 'POST', '-L', '--max-time', '30',
        '-H', 'Content-Type: application/json',
        '--data-raw', '{"name":"rikuesto"}',
        'https://api.example.com/items',
    }, spec.argv, 'inline JSON body uses --data-raw')
    t.eq(spec.meta.inline_body, true, 'meta.inline_body is true')
    t.eq(spec.meta.has_body, true, 'meta.has_body is true')
    t.eq(#spec.temp_files, 3, 'no payload temp file when the body is inline')
    cleanup(spec)
end

-- POST with a body above inline_body_max: payload temp file, never written by build().
do
    local text = '{"payload":"' .. string.rep('x', 40) .. '"}'
    local spec = curl.build({
        method = 'POST',
        url = 'https://api.example.com/items',
        headers = {},
        body = { kind = 'json', text = text },
        meta = {},
    }, context({ inline_body_max = 16 }))
    local payload = temp_path(spec, 'body')
    t.same({
        'curl', '-sS', '--no-progress-meter',
        '-D', temp_path(spec, 'headers'),
        '-o', temp_path(spec, 'output'),
        '-w', '%{json}',
        '-X', 'POST', '-L', '--max-time', '30',
        '--data-binary', '@' .. payload,
        'https://api.example.com/items',
    }, spec.argv, 'oversized body uses --data-binary @tempfile')
    t.eq(spec.meta.inline_body, false, 'meta.inline_body is false')
    t.eq(vim.fn.filereadable(payload), 0, 'build() does not write the payload')
    t.eq(#spec.temp_files, 4, 'payload temp file is declared')
    local declared = spec.temp_files[4]
    t.eq(declared.kind, 'body', 'payload entry kind is body')
    t.eq(declared.text, text, 'payload text is handed to runner')
    cleanup(spec)
end

-- external body: absolute path, --data-binary.
do
    local spec = curl.build({
        method = 'PUT',
        url = 'https://api.example.com/raw',
        headers = {},
        body = { kind = 'external', file = './payload.json' },
        meta = {},
    }, context())
    local expected = vim.fn.fnamemodify('./payload.json', ':p')
    t.same({
        'curl', '-sS', '--no-progress-meter',
        '-D', temp_path(spec, 'headers'),
        '-o', temp_path(spec, 'output'),
        '-w', '%{json}',
        '-X', 'PUT', '-L', '--max-time', '30',
        '--data-binary', '@' .. expected,
        'https://api.example.com/raw',
    }, spec.argv, 'external body is an absolute @file')
    t.eq(spec.meta.inline_body, false, 'external body is not inline')
    t.eq(#spec.temp_files, 3, 'external body needs no payload temp file')
    cleanup(spec)
end

-- multipart: one -F per body line, plus --http2 and no -L (# @no-redirect).
do
    local spec = curl.build({
        method = 'POST',
        url = 'https://api.example.com/upload',
        http_version = 'HTTP/2',
        headers = { { name = 'Content-Type', value = 'multipart/form-data' } },
        body = { kind = 'multipart', text = 'name=zeng\nfile=@./avatar.png\n' },
        meta = { no_redirect = true },
    }, context())
    t.same(golden('curl_multipart.args'), normalized(spec), 'multipart argv matches tests/golden/curl_multipart.args')
    t.eq(index_of(spec.argv, '-L'), nil, '# @no-redirect omits -L')
    t.eq(flag_value(spec.argv, '--max-time'), '30', 'max-time rendered in seconds')
    cleanup(spec)
end

-- urlencoded bodies are written line-per-pair in .http files.
do
    local spec = curl.build({
        method = 'POST',
        url = 'https://api.example.com/token',
        headers = {},
        body = { kind = 'urlencoded', text = 'grant_type=client_credentials\nscope=read write\n' },
        meta = {},
    }, context())
    t.eq(flag_value(spec.argv, '--data-raw'), 'grant_type=client_credentials&scope=read write',
        'urlencoded lines are joined with &')
    cleanup(spec)
end

-- HTTP version flags.
do
    local function version_flag(http_version)
        local spec = curl.build({
            method = 'GET',
            url = 'https://api.example.com/x',
            headers = {},
            http_version = http_version,
            meta = {},
        }, context())
        local flag = index_of(spec.argv, '--http2') and '--http2'
            or (index_of(spec.argv, '--http1.1') and '--http1.1' or nil)
        cleanup(spec)
        return flag
    end
    t.eq(version_flag('HTTP/2'), '--http2', 'HTTP/2 -> --http2')
    t.eq(version_flag('HTTP/1.1'), '--http1.1', 'HTTP/1.1 -> --http1.1')
    t.eq(version_flag(nil), nil, 'no version suffix -> no flag')
end

-- follow_redirects=false drops -L; HEAD must use --head (never `-X HEAD`, which hangs until
-- --max-time because curl then waits for a body the server never sends).
do
    local spec = curl.build({
        method = 'HEAD',
        url = 'https://api.example.com/x',
        headers = {},
        meta = {},
    }, context({ follow_redirects = false }))
    t.eq(index_of(spec.argv, '-L'), nil, 'follow_redirects = false omits -L')
    t.eq(index_of(spec.argv, '-X'), nil, 'HEAD never uses -X')
    t.eq(index_of(spec.argv, '--head') ~= nil, true, 'HEAD becomes --head')
    cleanup(spec)
end

-- insecure + proxy + timeout from request metadata.
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://example.com/secure',
        headers = {},
        meta = { insecure = true, proxy = 'http://127.0.0.1:8888', timeout_ms = 1500 },
    }, context())
    t.same({
        'curl', '-sS', '--no-progress-meter',
        '-D', temp_path(spec, 'headers'),
        '-o', temp_path(spec, 'output'),
        '-w', '%{json}',
        '-L', '-k', '--proxy', 'http://127.0.0.1:8888', '--max-time', '2',
        'https://example.com/secure',
    }, spec.argv, 'insecure + proxy + timeout argv')
    cleanup(spec)
end

-- insecure + proxy can also come from the config-derived context.
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://example.com/secure',
        headers = {},
        meta = {},
    }, context({ insecure = true, proxy = 'http://proxy.local:3128' }))
    t.eq(index_of(spec.argv, '-k') ~= nil, true, 'ctx.insecure adds -k')
    t.eq(flag_value(spec.argv, '--proxy'), 'http://proxy.local:3128', 'ctx.proxy adds --proxy')
    cleanup(spec)
end

-- extra_args land right after the binary, before the fixed flags.
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://api.example.com/x',
        headers = {},
        meta = {},
    }, context({ extra_args = { '--compressed', '--connect-timeout', '5' } }))
    t.eq(spec.argv[1], 'curl', 'argv[1] is the binary')
    t.same({ '--compressed', '--connect-timeout', '5' }, { spec.argv[2], spec.argv[3], spec.argv[4] },
        'extra_args come directly after the binary')
    cleanup(spec)
end

-- URL credentials become -u and are stripped from the URL (never logged as a URL).
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://alice:s3cret@example.com/private',
        headers = {},
        meta = {},
    }, context())
    t.eq(flag_value(spec.argv, '-u'), 'alice:s3cret', 'URL userinfo becomes -u')
    t.eq(spec.argv[#spec.argv], 'https://example.com/private', 'credentials are stripped from the URL')
    t.eq(spec.meta.url, 'https://example.com/private', 'meta.url is the credential-free URL')
    cleanup(spec)
end

-- An explicit Authorization header wins over URL userinfo.
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://alice:s3cret@example.com/private',
        headers = { { name = 'Authorization', value = 'Bearer token' } },
        meta = {},
    }, context())
    t.eq(index_of(spec.argv, '-u'), nil, 'Authorization header suppresses -u')
    t.eq(flag_value(spec.argv, '-H'), 'Authorization: Bearer token', 'Authorization header is still sent')
    cleanup(spec)
end

t.finish()

t.module('http.auth')

do
    local parsed = auth.from_url('https://alice:s3cret@example.com/api')
    t.eq(parsed and parsed.user, 'alice', 'from_url user')
    t.eq(parsed and parsed.pass, 's3cret', 'from_url pass')
    t.eq(parsed and parsed.clean_url, 'https://example.com/api', 'from_url clean_url')

    local token_only = auth.from_url('https://token@example.com/api')
    t.eq(token_only and token_only.user, 'token', 'user without password')
    t.eq(token_only and token_only.pass, nil, 'missing password stays nil')
    t.eq(token_only and token_only.clean_url, 'https://example.com/api', 'clean_url without password')

    local colon_pass = auth.from_url('http://user:pa:ss@host:8080/x?y=1')
    t.eq(colon_pass and colon_pass.pass, 'pa:ss', 'password keeps inner colons')
    t.eq(colon_pass and colon_pass.clean_url, 'http://host:8080/x?y=1', 'clean_url keeps port and query')

    t.eq(auth.from_url('https://example.com/api@v1'), nil, '@ after the path is not userinfo')
    t.eq(auth.from_url('https://example.com:8080/x'), nil, 'plain URL has no credentials')
    t.eq(auth.from_url('not a url'), nil, 'non-URL returns nil')
    t.eq(auth.from_url(''), nil, 'empty string returns nil')
    t.eq(auth.from_url(nil), nil, 'nil returns nil')
end

t.finish()

t.module('http.exporter')

do
    local argv = { 'curl', '-H', 'X-Test: a b', 'https://example.com' }
    t.eq(exporter.to_string(argv, 'native'), table.concat(argv, '\n'), 'native = one argument per line')
    t.eq(exporter.to_string(argv, 'sh'), "curl -H 'X-Test: a b' https://example.com",
        'sh quotes only the argument that needs it')
    t.eq(exporter.to_string({ 'curl', "It's" }, 'pwsh'), "curl 'It''s'", 'pwsh doubles single quotes')
    t.eq(exporter.to_string({ 'curl', "It's" }, 'sh'), "curl 'It'\\''s'", 'sh closes/escapes/reopens')
    t.eq(exporter.to_string({ 'curl', 'a^b', 'say "hi"' }, 'cmd'), 'curl "a^^b" "say \\"hi\\""',
        'cmd escapes ^ and "')
    t.eq(exporter.to_string(argv, 'nope'), table.concat(argv, '\n'), 'unknown dialect falls back to native')
    t.eq(exporter.to_string({ 'curl', '', 'a b', 'a;b', 'a*b', 'a{b}' }, 'pwsh'),
        "curl '' 'a b' 'a;b' 'a*b' 'a{b}'", 'shell metacharacters force quoting')
    -- A quoted word is a *string expression* in PowerShell, not a command, so a path that
    -- needs quoting must be introduced by the call operator `&`.
    t.eq(exporter.to_string({ 'C:\\Program Files\\curl.exe', '-X', 'POST' }, 'pwsh'),
        "& 'C:\\Program Files\\curl.exe' -X POST", 'pwsh prefixes a quoted command word with &')
    t.eq(exporter.to_string({ '/opt/my tools/curl', '-X', 'POST' }, 'sh'),
        "'/opt/my tools/curl' -X POST", 'sh accepts a quoted command word as is')
    t.eq(exporter.command_line({ 'curl', '-X', 'POST' }), 'curl -X POST', 'command_line joins with spaces')
    t.eq(exporter.command_line({}), '', 'command_line of an empty argv')
    t.eq(exporter.command_line({ 'curl', '-H', 'Authorization: Bearer abc', 'https://example.com' }),
        'curl -H Authorization: *** https://example.com', 'command_line masks header secrets per argument')
    t.eq(exporter.command_line({ 'curl', '-u', 'alice:s3cret', 'https://example.com' }),
        'curl -u *** https://example.com', 'command_line masks -u credentials')
    t.eq(exporter.to_string({ 'curl', '-u', 'alice:s3cret' }, 'native'), 'curl\n-u\nalice:s3cret',
        'copy as curl keeps the real credentials')
    t.eq(exporter.resolve_dialect(nil), require('rikuesto.util.platform').is_windows and 'pwsh' or 'sh',
        'auto dialect resolves to the platform shell')
    t.eq(exporter.resolve_dialect(''), exporter.resolve_dialect('auto'), 'empty dialect means auto')
    t.eq(exporter.resolve_dialect('sh'), 'sh', 'an explicit dialect is kept')
end

-- Copy as curl must produce a runnable command: no response-capture plumbing
-- (`-sS`, `-D`, `-o`, `-w`) and no file reference (regression: the run argv used to be
-- copied verbatim, so the pasted command wrote temp files and printed metadata).
do
    local text = '{"password":"s3cret","note":"' .. string.rep('x', 40) .. '"}'
    local spec = curl.build({
        method = 'POST',
        url = 'https://api.example.com/items',
        headers = { { name = 'Authorization', value = 'Bearer abc123' } },
        body = { kind = 'json', text = text },
        meta = {},
    }, context({ inline_body_max = 16 }))
    t.eq(#spec.temp_files, 4, 'the run argv really does use a payload temp file')
    local argv, notes = exporter.export_argv(spec)
    t.eq(#notes, 0, 'an inline-able payload needs no note')
    t.eq(exporter.to_string(argv, 'sh'), table.concat({
        'curl', '-X', 'POST', '-L', '--max-time', '30',
        '-H', "'Authorization: Bearer abc123'",
        '--data-raw', "'" .. text .. "'",
        'https://api.example.com/items',
    }, ' '), 'export inlines the body and drops every capture flag')
    for _, flag in ipairs({ '-sS', '--no-progress-meter', '-D', '-o', '-w', '--write-out' }) do
        t.eq(index_of(argv, flag), nil, 'export contains no ' .. flag)
    end
    for _, arg in ipairs(argv) do
        t.eq(arg:find('payload.bin', 1, true), nil, 'export references no temp file')
    end
    cleanup(spec)
end

-- `< ./body.json`: the file reference is replaced by the file's bytes.
do
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/body.json'
    vim.fn.writefile({ '{"a":1}' }, path)
    local spec = curl.build({
        method = 'PUT',
        url = 'https://api.example.com/raw',
        headers = {},
        body = { kind = 'external', file = path },
        meta = {},
    }, context())
    local argv, notes = exporter.export_argv(spec)
    -- `readfile(..., 'b')` keeps the file's trailing newline as an empty last line, so the
    -- inlined body is byte-identical to what `--data-binary @file` used to send.
    t.same({ 'curl', '-X', 'PUT', '-L', '--max-time', '30', '--data-raw', '{"a":1}\n',
        'https://api.example.com/raw' }, argv, 'external body is inlined, not referenced')
    t.eq(#notes, 1, 'inlining an external file is reported')
    vim.fn.delete(path, 'rf')
    cleanup(spec)
end

-- The copied command starts with a command word, not with the resolved binary path: a
-- quoted path is a ParserError in PowerShell and noise in every other shell.
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://api.example.com/x',
        headers = {},
        body = { kind = 'none' },
        meta = {},
    }, context({ curl_bin = 'C:\\Program Files\\Git\\ucrt64\\bin\\curl.EXE' }))
    local argv = exporter.export_argv(spec)
    t.eq(argv[1], 'curl.exe', 'the resolved curl path becomes the curl.exe command word')
    t.eq(exporter.to_string(argv, 'pwsh'), 'curl.exe -L --max-time 30 https://api.example.com/x',
        'a plain GET needs no quoting at all')
    cleanup(spec)
end

-- An override that is not a curl binary keeps its path (and pwsh then needs `&`).
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://api.example.com/x',
        headers = {},
        body = { kind = 'none' },
        meta = {},
    }, context({ curl_bin = 'D:\\my tools\\curlish.exe' }))
    local argv = exporter.export_argv(spec)
    t.eq(argv[1], 'D:\\my tools\\curlish.exe', 'a non-curl override keeps its full path')
    t.eq(exporter.to_string(argv, 'pwsh'),
        "& 'D:\\my tools\\curlish.exe' -L --max-time 30 https://api.example.com/x",
        'pwsh runs a quoted path through the call operator')
    cleanup(spec)
end

-- User-supplied extra_args are preserved verbatim, including a deliberate -o.
do
    local spec = curl.build({
        method = 'GET',
        url = 'https://api.example.com/x',
        headers = {},
        body = { kind = 'none' },
        meta = {},
    }, context({ extra_args = { '-o', 'keep.txt', '-v' } }))
    local argv = exporter.export_argv(spec)
    t.eq(index_of(argv, '-o') ~= nil, true, 'a user -o from curl.extra_args survives')
    t.eq(index_of(argv, '-v') ~= nil, true, 'a user -v from curl.extra_args survives')
    cleanup(spec)
end

t.finish()

t.module('http.runner')

-- A no-op child process stands in for curl: what is under test is the plumbing
-- (temp files, job handle, on_done, cleanup), never the network.
local function no_op_argv()
    return { vim.v.progpath, '--headless', '-c', 'qa!' }
end

-- Completed child without any response metadata: files cleaned up, error surfaced.
do
    local runner = require('rikuesto.http.runner')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local spec = {
        argv = no_op_argv(),
        temp_files = {
            { path = dir .. '/headers.txt', kind = 'headers' },
            { path = dir .. '/body.bin', kind = 'output' },
            { path = dir .. '/writeout.json', kind = 'writeout' },
        },
        meta = {},
    }
    local done, received, seen_err = false, nil, nil
    local job = runner.run(spec, { max_time_ms = 20000 }, function(parsed, err)
        done = true
        received = parsed
        seen_err = err
    end)
    t.eq(job.done, false, 'job.done is false while the child runs')
    t.eq(type(job.cancel), 'function', 'job exposes job:cancel()')
    vim.wait(30000, function()
        return done
    end, 20)
    t.eq(done, true, 'on_done fires from the main loop')
    t.eq(job.done, true, 'job.done is true afterwards')
    t.eq(vim.fn.isdirectory(dir), 0, 'temp files and directory are cleaned up')
    t.eq(type(received), 'table', 'on_done receives a Response table')
    t.eq(received and received.error and received.error.kind, 'curl', 'empty output -> curl error')
    t.eq(seen_err ~= nil, true, 'error message is passed to on_done')
end

-- keep_temp_on_error: the payload survives, byte-exact, for inspection.
do
    local runner = require('rikuesto.http.runner')
    local text = string.rep('x', 9000)
    local spec = curl.build({
        method = 'POST',
        url = 'https://api.example.com/items',
        headers = {},
        body = { kind = 'raw', text = text },
        meta = {},
    }, context({ keep_temp_on_error = true }))
    local payload = temp_path(spec, 'body')
    spec.argv = no_op_argv()
    local done = false
    runner.run(spec, { max_time_ms = 20000, keep_temp_on_error = true }, function()
        done = true
    end)
    vim.wait(30000, function()
        return done
    end, 20)
    t.eq(vim.fn.filereadable(payload), 1, 'payload temp file is written before the child runs')
    local kept = vim.fn.filereadable(payload) == 1 and table.concat(vim.fn.readfile(payload, 'b'), '\n') or nil
    t.eq(kept, text, 'payload bytes are exact')
    cleanup(spec)
end

t.finish()
