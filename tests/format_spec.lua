-- Formatter tests: structure rebuild, golden comparison, idempotency and fail-soft paths.
-- The ParseResult tables are built by hand (the contract is frozen) so these tests never
-- depend on rikuesto.parse.*; external tools are stubbed or skipped when absent.
local t = require('tests.helper')
local config = require('rikuesto.config')
local formatter = require('rikuesto.format.formatter')
local request = require('rikuesto.format.request')
local js_block = require('rikuesto.format.js_block')
local tools = require('rikuesto.format.tools')

t.module('format')

local root = t.root()

local function read_lines(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        error('missing file ' .. path)
    end
    return lines
end

--- Replace `tbl[key]` for the duration of `fn`.
local function with_stub(tbl, key, value, fn)
    local saved = tbl[key]
    tbl[key] = value
    local ok, err = pcall(fn)
    tbl[key] = saved
    if not ok then
        error(err)
    end
end

--------------------------------------------------------------------------------
-- Hand-built ParseResult for tests/fixtures/format_in.http
--------------------------------------------------------------------------------

local function row_of(lines, needle, from)
    for index = from or 1, #lines do
        if lines[index]:find(needle, 1, true) then
            return index - 1 -- ParseResult rows are 0-based
        end
    end
    error('fixture row not found: ' .. needle)
end

--- Build the ParseResult for the format fixture without using the parse module.
local function build_fixture_result(lines)
    local pre_fence = row_of(lines, '< {%')
    local pre_source = table.concat({ lines[pre_fence + 2], lines[pre_fence + 3] }, '\n')
    local pre_close = row_of(lines, '%}', pre_fence + 1)

    local list_url = row_of(lines, 'api/users?page=1')
    local list_accept = row_of(lines, 'accept:')
    local list_ctype = row_of(lines, 'Content-Type:application/json')
    local list_body = row_of(lines, '{"a":1')

    local create_url = row_of(lines, 'POST https://{{host}}/api/users')
    local create_ctype = row_of(lines, 'Content-Type: application/json')
    local create_trace = row_of(lines, 'X-Trace:')
    local create_body = row_of(lines, '"name"') - 1 -- the JSON body opens one row earlier, on its own line
    local post_fence = row_of(lines, '> {%')
    local post_source = table.concat({ lines[post_fence + 2], lines[post_fence + 3] }, '\n')
    local post_close = row_of(lines, '%}', post_fence + 1)

    local form_url = row_of(lines, 'POST https://{{host}}/api/form')
    local form_ctype = row_of(lines, 'application/x-www-form-urlencoded')
    local form_body = row_of(lines, 'a=1&b=2&c=3')
    local form_assertion = row_of(lines, '?? status')

    return {
        preamble = {
            variables = { host = 'example.com', version = 'v2', note = 'see below' },
            scripts = {
                pre = {
                    {
                        lang = 'javascript',
                        source = pre_source,
                        post = false,
                        offset = { row = pre_fence + 1, col = 0 },
                    },
                },
            },
            meta = {},
        },
        file_variables = { host = 'example.com', version = 'v2', note = 'see below' },
        requests = {
            {
                index = 1,
                title = 'list users',
                method = 'GET',
                url = 'https://{{host}}/api/users?page=1&limit=10',
                url_line = list_url,
                headers = {
                    { name = 'accept', value = 'application/json', row = list_accept },
                    { name = 'Content-Type', value = 'application/json', row = list_ctype },
                },
                body = {
                    kind = 'json',
                    text = '{"a":1,"z":[1,2],"big":1234567890123456789,"f":1.0}',
                    range = { start_row = list_body, end_row = list_body + 1 },
                },
                scripts = { pre = {}, post = {} },
                assertions = {},
                meta = { raw = {} },
                range = { start_row = list_url, end_row = list_body + 1 },
            },
            {
                index = 2,
                title = 'create user',
                method = 'POST',
                url = 'https://{{host}}/api/users',
                http_version = 'HTTP/1.1',
                url_line = create_url,
                headers = {
                    { name = 'Content-Type', value = 'application/json', row = create_ctype },
                    { name = 'X-Trace', value = 'abc', row = create_trace },
                },
                body = {
                    kind = 'json',
                    text = '{\n"name":"x",\n"tags":["a","b"]\n}',
                    range = { start_row = create_body, end_row = create_body + 4 },
                },
                scripts = {
                    pre = {},
                    post = {
                        {
                            lang = 'javascript',
                            source = post_source,
                            post = true,
                            offset = { row = post_fence + 1, col = 0 },
                        },
                    },
                },
                assertions = {},
                meta = { raw = {} },
                range = { start_row = create_url, end_row = post_close + 1 },
            },
            {
                index = 3,
                title = 'form post',
                method = 'POST',
                url = 'https://{{host}}/api/form',
                url_line = form_url,
                headers = {
                    { name = 'Content-Type', value = 'application/x-www-form-urlencoded', row = form_ctype },
                },
                body = {
                    kind = 'urlencoded',
                    text = 'a=1&b=2&c=3',
                    range = { start_row = form_body, end_row = form_body + 1 },
                },
                scripts = { pre = {}, post = {} },
                assertions = { { row = form_assertion, raw = '?? status == 200' } },
                meta = { raw = {} },
                range = { start_row = form_url, end_row = form_assertion + 1 },
            },
        },
        diagnostics = {},
        _rows = {
            pre_fence = pre_fence,
            pre_close = pre_close,
            post_fence = post_fence,
            post_close = post_close,
        },
    }
end

local golden = read_lines(root .. '/tests/golden/format_out.http')
local fixture = t.fixture('format_in.http')
local fixture_result = build_fixture_result(fixture)

--------------------------------------------------------------------------------
-- Golden output (deterministic: no external tools)
--------------------------------------------------------------------------------

config.setup({ format = { json = 'internal', js = 'none' } })
local formatted = formatter.format_lines(fixture, fixture_result)

t.ok(formatted.changed, 'fixture is reformatted')
t.eq(#formatted.diagnostics, 0, 'no diagnostics for internal-only formatting')
t.same(formatted.lines, golden, 'formatted fixture matches tests/golden/format_out.http')

-- a formatted buffer is a fixed point of the structural rules
local restable = formatter.format_lines(formatted.lines, nil)
t.ok(not restable.changed, 'formatted output is stable without a ParseResult')
t.same(restable.lines, golden, 'structural pass keeps the golden unchanged')

--------------------------------------------------------------------------------
-- Structure rules
--------------------------------------------------------------------------------

local function lines_of(list)
    return table.concat(list, '\n')
end

t.contains(lines_of(formatted.lines), '### list users', 'separator has exactly one space')
t.contains(lines_of(formatted.lines), 'GET https://{{host}}/api/users?page=1&limit=10',
    'request line is method + url')
t.contains(lines_of(formatted.lines), 'POST https://{{host}}/api/users HTTP/1.1',
    'http version is kept on the request line')
t.contains(lines_of(formatted.lines), 'Content-Type: application/json', 'header colon spacing')
t.contains(lines_of(formatted.lines), 'X-Trace: abc', 'header value whitespace trimmed')
t.contains(lines_of(formatted.lines), 'accept: application/json', 'header case preserved')
t.contains(lines_of(formatted.lines), '// create one user, keep this comment where it is',
    'comment text and position preserved')
t.contains(lines_of(formatted.lines), '@host    = example.com', 'variables are aligned')
t.contains(lines_of(formatted.lines), '@version := v2', ':= declaration kept as-is')
t.contains(lines_of(formatted.lines), '  "big": 1234567890123456789', 'big integer survives formatting')
t.contains(lines_of(formatted.lines), '  "f": 1.0', '1.0 survives formatting')
t.contains(lines_of(formatted.lines), 'a=1\n&b=2\n&c=3', 'urlencoded body is one pair per line')
t.contains(lines_of(formatted.lines), '?? status == 200', 'assertion kept after the body')

-- blank line bookkeeping: exactly one blank line before bodies and before `###`
local blanks
do
    blanks = 0
    for index = 2, #formatted.lines do
        if formatted.lines[index] == '' and formatted.lines[index - 1] == '' then
            blanks = blanks + 1
        end
    end
end
t.eq(blanks, 0, 'no double blank lines')
t.eq(formatted.lines[#formatted.lines], '?? status == 200', 'no trailing blank line')

--------------------------------------------------------------------------------
-- Idempotency with a single block (the same ParseResult still applies)
--------------------------------------------------------------------------------

local mini = {
    '### one',
    'POST   https://api.test/things?b=2&a=1',
    'Content-Type:application/json',
    'accept:   */*',
    '',
    '{"b":2,"a":1,"n":1.50}',
}
local mini_result = {
    requests = {
        {
            index = 1,
            title = 'one',
            method = 'POST',
            url = 'https://api.test/things?b=2&a=1',
            url_line = 1,
            headers = {
                { name = 'Content-Type', value = 'application/json', row = 2 },
                { name = 'accept', value = '*/*', row = 3 },
            },
            body = { kind = 'json', text = '{"b":2,"a":1,"n":1.50}', range = { start_row = 5, end_row = 6 } },
            scripts = { pre = {}, post = {} },
            assertions = {},
            meta = { raw = {} },
            range = { start_row = 1, end_row = 6 },
        },
    },
}

config.setup({ format = { json = 'internal', js = 'none' } })
local mini_once = formatter.format_lines(mini, mini_result)
local mini_twice = formatter.format_lines(mini_once.lines, mini_result)
t.ok(mini_once.changed, 'single block reformatted')
t.ok(not mini_twice.changed, 'format(format(x)) equals format(x)')
t.same(mini_twice.lines, mini_once.lines, 'idempotent for the internal JSON printer')

--------------------------------------------------------------------------------
-- header sorting / variable alignment options
--------------------------------------------------------------------------------

config.setup({ format = { json = 'internal', js = 'none', sort_headers = true } })
local sorted = formatter.format_lines(mini, mini_result)
t.contains(lines_of(sorted.lines), 'accept: */*\nContent-Type: application/json',
    'sort_headers orders headers by name')

config.setup({ format = { json = 'internal', js = 'none', align_variables = false } })
local unaligned = formatter.format_lines(fixture, fixture_result)
t.contains(lines_of(unaligned.lines), '@version := v2', 'unaligned variables keep :=')
t.contains(lines_of(unaligned.lines), '\n@note = see below', 'align_variables=false assigns one space')

--------------------------------------------------------------------------------
-- Multi-line URL handling (cfg.format.explode_query)
--------------------------------------------------------------------------------

local multi_url = {
    '### multi',
    'GET https://api.test/items',
    '    ?page=1',
    '    &limit=2',
}
local multi_result = {
    requests = {
        {
            index = 1,
            title = 'multi',
            method = 'GET',
            url = 'https://api.test/items?page=1&limit=2',
            url_line = 1,
            headers = {},
            scripts = { pre = {}, post = {} },
            assertions = {},
            meta = { raw = {} },
            range = { start_row = 1, end_row = 4 },
        },
    },
}

config.setup({ format = { json = 'internal', js = 'none', explode_query = 'keep' } })
t.same(formatter.format_lines(multi_url, multi_result).lines, multi_url, 'keep preserves the user layout')

config.setup({ format = { json = 'internal', js = 'none', explode_query = 'inline' } })
t.same(formatter.format_lines(multi_url, multi_result).lines, {
    '### multi',
    'GET https://api.test/items?page=1&limit=2',
}, 'inline joins the URL onto one line')

config.setup({ format = { json = 'internal', js = 'none', explode_query = 'explode' } })
t.same(formatter.format_lines(multi_url, multi_result).lines, {
    '### multi',
    'GET https://api.test/items?page=1',
    '&limit=2',
}, 'explode puts each query pair on its own line')

--------------------------------------------------------------------------------
-- request.lua units
--------------------------------------------------------------------------------

t.same(request.request_line({ method = 'get', url = 'https://x/y' }, {}, {}), { 'GET https://x/y' },
    'method is upper-cased and defaults are applied')
t.eq(request.normalize_url('https://x/a   b'), 'https://x/a b', 'url whitespace collapsed')
t.eq(request.normalize_url('https://{{ host }}/x  y'), 'https://{{ host }}/x y',
    'whitespace inside {{ }} is untouched')

t.same(request.header_lines({
    headers = {
        { name = 'X-Long', value = 'part1\npart2' },
        { name = 'X-Empty', value = '' },
    },
}, {}), { 'X-Long: part1', '  part2', 'X-Empty:' }, 'header continuation indents by two spaces')

t.same(request.urlencoded_lines('a=1&b=2'), { 'a=1', '&b=2' }, 'urlencoded pairs get & prefixes')
t.same(request.urlencoded_lines('a=1&\nb=2'), { 'a=1', '&b=2' }, 'urlencoded line breaks collapse')
t.eq(request.urlencoded_lines(''), nil, 'empty urlencoded body yields no lines')

t.eq(request.assertion_line({ raw = '??  status   ==   200' }), '?? status == 200', 'assertion whitespace collapsed')
t.eq(request.assertion_line({ raw = 'status == 200' }), '?? status == 200', 'missing ?? prefix is added')

t.eq(request.body_span({ body = { range = { start_row = 3, end_row = 5 }, text = 'a\nb' } }), 2,
    'body span follows the parsed range')

--------------------------------------------------------------------------------
-- Script fences
--------------------------------------------------------------------------------

local script_lines = {
    '### scripted',
    '< {%',
    'function pre(){',
    'return 1',
    '}',
    '%}',
    'GET https://api.test/x',
}
local script_result = {
    requests = {
        {
            index = 1,
            title = 'scripted',
            method = 'GET',
            url = 'https://api.test/x',
            url_line = 5,
            headers = {},
            scripts = { pre = {}, post = {} },
            assertions = {},
            meta = { raw = {} },
            range = { start_row = 1, end_row = 6 },
        },
    },
    preamble = { scripts = { pre = {} }, variables = {}, meta = {} },
}

config.setup({ format = { json = 'internal', js = 'none' } })
t.same(formatter.format_lines(script_lines, script_result).lines, script_lines,
    'js = none leaves the fence body verbatim')

config.setup({ format = { json = 'internal', js = 'auto' } })
local script_failure_diagnostics = {}
with_stub(tools, 'oxfmt', function()
    return nil, 'forced failure'
end, function()
    local failed = formatter.format_lines(script_lines, script_result)
    t.same(failed.lines, script_lines, 'failing oxfmt keeps the script verbatim')
    t.eq(#failed.diagnostics, 1, 'failing oxfmt records one diagnostic')
    t.eq(failed.diagnostics[1] and failed.diagnostics[1].code, 'format.js', 'diagnostic code is format.js')
    t.eq(failed.diagnostics[1] and failed.diagnostics[1].severity, 'warning', 'diagnostic is a warning')
    script_failure_diagnostics = failed.diagnostics
end)
t.eq(#script_failure_diagnostics, 1, 'script diagnostic captured')

t.eq(js_block.format('', {}), nil, 'empty script is not formatted')

--------------------------------------------------------------------------------
-- Structure edge cases (inline fences, handler lines, malformed fences)
--------------------------------------------------------------------------------

local edge_lines = {
    '### edge',
    '< {% return request.variables.get("t") %}',
    'GET https://api.test/x',
    'X-Long: part1',
    '    part2',
    '',
    '{"a":1}',
    '> ./handler.js',
    '> {% return response.status %}',
}
local edge_result = {
    requests = {
        {
            index = 1,
            title = 'edge',
            method = 'GET',
            url = 'https://api.test/x',
            url_line = 2,
            headers = { { name = 'X-Long', value = 'part1\npart2', row = 3 } },
            body = { kind = 'json', text = '{"a":1}', range = { start_row = 6, end_row = 7 } },
            scripts = { pre = {}, post = {} },
            assertions = {},
            meta = { raw = {} },
            range = { start_row = 2, end_row = 9 },
        },
    },
}

config.setup({ format = { json = 'internal', js = 'none' } })
t.same(formatter.format_lines(edge_lines, edge_result).lines, {
    '### edge',
    '< {%',
    'return request.variables.get("t")',
    '%}',
    'GET https://api.test/x',
    'X-Long: part1',
    '  part2',
    '',
    '{',
    '  "a": 1',
    '}',
    '',
    '> ./handler.js',
    '',
    '> {%',
    'return response.status',
    '%}',
}, 'inline fences are split, header continuation is rebuilt, handler gets a blank line')

local broken_fence = { '### bad', 'PUT https://api.test/raw', '< {%', 'const x = 1', '', 'raw line' }
local broken_result = {
    requests = {
        {
            index = 1,
            title = 'bad',
            method = 'PUT',
            url = 'https://api.test/raw',
            url_line = 1,
            headers = {},
            scripts = { pre = {}, post = {} },
            assertions = {},
            meta = { raw = {} },
            range = { start_row = 1, end_row = 6 },
        },
    },
}
t.same(formatter.format_lines(broken_fence, broken_result).lines, broken_fence,
    'an unterminated fence is left alone')

--------------------------------------------------------------------------------
-- External tools: jq
--------------------------------------------------------------------------------

local availability = tools.available()
t.eq(type(availability.jq), 'boolean', 'tools.available().jq is a boolean')
t.eq(type(availability.oxfmt), 'boolean', 'tools.available().oxfmt is a boolean')

if availability.jq then
    local pretty, err = tools.jq('{"z":1,"a":2}')
    t.eq(err, nil, 'jq call succeeds')
    t.contains(pretty or '', '"z": 1', 'jq output is re-indented')
    t.contains(pretty or '', '"a": 2', 'jq keeps key order')

    local bad, bad_err = tools.jq('{oops}')
    t.eq(bad, nil, 'jq rejects invalid JSON')
    t.ok(type(bad_err) == 'string' and bad_err ~= '', 'jq failure returns an error message')

    config.setup({ format = { json = 'auto', js = 'none', cache = false } })
    local via_jq = formatter.format_lines(mini, mini_result)
    t.contains(lines_of(via_jq.lines), '  "n": 1.50', 'jq keeps the number literal 1.50')
    t.eq(#via_jq.diagnostics, 0, 'successful jq run records no diagnostic')

    config.setup({ format = { json = 'auto', js = 'none', cache = true } })
    local cached_once = formatter.format_lines(mini, mini_result)
    local cached_twice = formatter.format_lines(mini, mini_result)
    t.same(cached_twice.lines, cached_once.lines, 'cached tool output is identical')
else
    print('SKIP format: jq not available')
end

if availability.oxfmt then
    config.setup({ format = { json = 'internal', js = 'auto' } })
    local scripted = formatter.format_lines(script_lines, script_result)
    t.contains(lines_of(scripted.lines), '  function pre() {', 'oxfmt indents the fence body by two spaces')
    t.contains(lines_of(scripted.lines), '    return 1;', 'oxfmt keeps nested indentation')
    t.eq(#scripted.diagnostics, 0, 'successful oxfmt run records no diagnostic')

    local scripted_again = formatter.format_lines(scripted.lines, script_result)
    t.ok(not scripted_again.changed, 'formatted script fence is stable')
    t.same(scripted_again.lines, scripted.lines, 'oxfmt output is idempotent')

    local wrapped, wrap_err = js_block.format('return response.status', { indent = '  ' })
    t.eq(wrap_err, nil, 'top-level return is wrapped successfully')
    t.contains(wrapped or '', 'return response.status;', 'wrapped fragment is unwrapped again')
    t.matches(wrapped or '', '^  ', 'formatted fragment is re-indented by two spaces')
else
    print('SKIP format: oxfmt not available')
end

--------------------------------------------------------------------------------
-- Fail-soft JSON path (jq forced to fail)
--------------------------------------------------------------------------------

local json_lines = {
    '### body',
    'POST https://api.test/x',
    'Content-Type: application/json',
    '',
    '{"a":1,"b":[1,2]}',
}
local json_result = {
    requests = {
        {
            index = 1,
            title = 'body',
            method = 'POST',
            url = 'https://api.test/x',
            url_line = 1,
            headers = { { name = 'Content-Type', value = 'application/json', row = 2 } },
            body = { kind = 'json', text = '{"a":1,"b":[1,2]}', range = { start_row = 4, end_row = 5 } },
            scripts = { pre = {}, post = {} },
            assertions = {},
            meta = { raw = {} },
            range = { start_row = 1, end_row = 5 },
        },
    },
}

config.setup({ format = { json = 'auto', js = 'none' } })
local failed_body
with_stub(tools, 'available', function()
    return { jq = true, oxfmt = false }
end, function()
    with_stub(tools, 'jq', function()
        return nil, 'forced failure'
    end, function()
        failed_body = formatter.format_lines(json_lines, json_result)
    end)
end)
t.same(failed_body.lines, json_lines, 'failing jq keeps the body verbatim')
t.eq(#failed_body.diagnostics, 1, 'failing jq records one diagnostic')
t.eq(failed_body.diagnostics[1] and failed_body.diagnostics[1].code, 'format.json', 'diagnostic code is format.json')
t.ok(not failed_body.changed, 'failed JSON formatting reports no change')

--------------------------------------------------------------------------------
-- format_buffer
--------------------------------------------------------------------------------

local parse_key = 'rikuesto.parse.block'
local saved_parse = package.loaded[parse_key]
package.loaded[parse_key] = {
    parse = function()
        return mini_result
    end,
}

local bufnr = vim.api.nvim_create_buf(true, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, mini)
vim.bo[bufnr].fileformat = 'dos'

config.setup({ format = { json = 'internal', js = 'none' } })
local ok_first, changed_first = formatter.format_buffer(bufnr)
t.ok(ok_first, 'format_buffer reports success')
t.ok(changed_first, 'format_buffer reports a change')
t.same(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), mini_once.lines, 'buffer holds the formatted lines')

local ok_second, changed_second = formatter.format_buffer(bufnr)
t.ok(ok_second, 'second format_buffer call reports success')
t.ok(not changed_second, 'second format_buffer call reports no change')
t.eq(vim.bo[bufnr].fileformat, 'dos', 'fileformat is untouched')

local has_cr = false
for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find('\r', 1, true) then
        has_cr = true
    end
end
t.ok(not has_cr, 'no carriage returns are inserted into the buffer')

vim.api.nvim_buf_delete(bufnr, { force = true })
package.loaded[parse_key] = saved_parse

t.eq(formatter.format_buffer(9999), false, 'invalid buffer number is rejected')

-- Regression: separator titles must come from the separator line itself. Files may contain
-- `### ====` banners or consecutive `###` separators that open no request; pairing separators
-- with `requests[index]` duplicated titles and shifted them to the top of the buffer.
do
    local block = require('rikuesto.parse.block')
    local src = {
        '### ==========',
        '### banner text',
        '',
        '@base = http://x',
        '',
        '### REQ A',
        'GET {{base}}/a',
        '',
        '###',
        '### REQ B',
        'POST {{base}}/b',
        'Content-Type: application/json',
        '',
        '{"a":1}',
    }
    local once = formatter.format_lines(src, block.parse(src))
    local twice = formatter.format_lines(once.lines, block.parse(once.lines))
    t.same(once.lines, twice.lines, 'banner separators stay idempotent')
    local joined = table.concat(once.lines, '\n')
    t.eq(select(2, joined:gsub('### REQ A', '')), 1, 'separator title is emitted exactly once')
    t.eq(select(2, joined:gsub('### banner text', '')), 1, 'banner separator survives formatting')
    t.eq(select(2, joined:gsub('### ==========', '')), 1, 'first banner line survives formatting')
    t.eq(select(2, joined:gsub('### REQ B', '')), 1, 'second request title is emitted exactly once')
end

config.reset()
t.finish()
