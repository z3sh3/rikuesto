-- Behaviour tests for the parse layer: block splitting, request lines, headers,
-- bodies, scripts, variables, metadata, assertions and the full test.http corpus.
-- Nothing here touches the network or treesitter.
-- Row expectations (url_line / range / script offset) are 0-based and tied to the
-- current contents of tests/fixtures/parse_*.http.
local t = require('tests.helper')
local block = require('rikuesto.parse.block')
local cursor = require('rikuesto.parse.cursor')
local metadata = require('rikuesto.parse.metadata')
local request = require('rikuesto.parse.request')
local scripts = require('rikuesto.parse.scripts')
local variables = require('rikuesto.parse.variables')

t.module('parse')

local function parse(lines)
    return block.parse(lines)
end

local function new_scope()
    return {
        variables = {},
        lazy_variables = {},
        scripts = { pre = {} },
        meta = metadata.empty(),
    }
end

--- First header with a matching (case-insensitive) name.
local function header_value(req, name)
    local lower = name:lower()
    for _, header in ipairs(req.headers) do
        if header.name:lower() == lower then
            return header.value
        end
    end
    return nil
end

local function has_code(diagnostics, code)
    for _, diagnostic in ipairs(diagnostics) do
        if diagnostic.code == code then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------- variables

do
    local parsed = variables.parse_line('@base = https://example.test')
    t.eq(parsed.name, 'base', 'variables: name')
    t.eq(parsed.value, 'https://example.test', 'variables: value')
    t.eq(parsed.lazy, false, 'variables: = is not lazy')

    local lazy = variables.parse_line('@ts := 1700000000')
    t.eq(lazy.name, 'ts', 'variables: lazy name')
    t.eq(lazy.value, '1700000000', 'variables: lazy value')
    t.eq(lazy.lazy, true, 'variables: := is lazy')

    t.eq(variables.parse_line('  @indented = v').value, 'v', 'variables: indented declaration')
    t.eq(variables.parse_line('@empty =').value, '', 'variables: empty value')
    t.eq(variables.parse_line('GET https://example.test'), nil, 'variables: request line is not a variable')
    t.eq(variables.parse_line(''), nil, 'variables: blank line is not a variable')
    t.eq(variables.parse_line(nil), nil, 'variables: nil input')
end

-- ---------------------------------------------------------------- metadata

do
    local name = metadata.parse_line('# @name login')
    t.eq(name.key, 'name', 'metadata: name key')
    t.eq(name.value, 'login', 'metadata: name value')

    local flag = metadata.parse_line('// @no-redirect')
    t.eq(flag.key, 'no-redirect', 'metadata: // comment form')
    t.eq(flag.value, nil, 'metadata: flag has no value')

    t.eq(metadata.parse_line('GET https://example.test'), nil, 'metadata: request line is not metadata')
    t.eq(metadata.parse_line('# plain comment'), nil, 'metadata: plain comment is not metadata')

    local meta = metadata.empty()
    t.eq(metadata.apply(meta, metadata.parse_line('# @no-redirect'), 0), true, 'metadata: apply flag')
    t.eq(meta.no_redirect, true, 'metadata: no_redirect set')
    t.eq(metadata.apply(meta, metadata.parse_line('# @no-cookie-jar'), 0), true, 'metadata: apply no-cookie-jar')
    t.eq(meta.no_cookie_jar, true, 'metadata: no_cookie_jar set')
    metadata.apply(meta, metadata.parse_line('# @timeout 1500'), 0)
    t.eq(meta.timeout_ms, 1500, 'metadata: timeout_ms')
    metadata.apply(meta, metadata.parse_line('# @proxy http://p.test:1'), 0)
    t.eq(meta.proxy, 'http://p.test:1', 'metadata: proxy')
    metadata.apply(meta, metadata.parse_line('# @lang JSON'), 0)
    t.eq(meta.lang, 'json', 'metadata: lang is lower-cased')

    local unknown = metadata.parse_line('# @whatever yes')
    t.eq(metadata.apply(metadata.empty(), unknown, 0), false, 'metadata: unknown key is not applied')

    local bad_meta = metadata.empty()
    local handled, diagnostic = metadata.apply(bad_meta, metadata.parse_line('# @timeout soon'), 7)
    t.eq(handled, true, 'metadata: invalid timeout is still consumed')
    t.eq(bad_meta.timeout_ms, nil, 'metadata: invalid timeout leaves timeout_ms nil')
    t.eq(diagnostic.code, 'parse.invalid_timeout', 'metadata: invalid timeout diagnostic')
    t.eq(diagnostic.severity, 'warning', 'metadata: invalid timeout severity')
    t.eq(diagnostic.row, 7, 'metadata: diagnostic row')
end

-- ---------------------------------------------------------------- scripts

do
    local fence_shape, fence_post = scripts.classify('> {%')
    t.eq(fence_shape, 'fence', 'scripts: classify post fence')
    t.eq(fence_post, true, 'scripts: post fence is a response handler')
    local pre_shape, pre_post = scripts.classify('< {%')
    t.eq(pre_shape, 'fence', 'scripts: classify pre fence')
    t.eq(pre_post, false, 'scripts: pre fence is a pre-request script')
    local file_shape, file_post = scripts.classify('  > ./handler.js')
    t.eq(file_shape, 'file', 'scripts: classify post file')
    t.eq(file_post, true, 'scripts: post file is a response handler')
    t.eq(scripts.classify('GET https://example.test'), nil, 'scripts: request line is not a handler')
    t.eq(scripts.classify('>'), nil, 'scripts: bare marker is not a handler')

    local multi = { '> {%', '  const ts = Date.now();', '%}' }
    local script, next_row = scripts.parse_fence(multi, 0)
    t.eq(script.post, true, 'scripts: multi-line fence is post')
    t.eq(script.source, '  const ts = Date.now();', 'scripts: multi-line source keeps indentation')
    t.same(script.offset, { row = 1, col = 0 }, 'scripts: multi-line offset')
    t.eq(next_row, 3, 'scripts: next_row after the fence')

    local single = { '< {% client.log(1); %}' }
    local inline = scripts.parse_fence(single, 0)
    t.eq(inline.post, false, 'scripts: single-line fence is pre')
    t.eq(inline.source, 'client.log(1);', 'scripts: single-line source')
    t.same(inline.offset, { row = 0, col = 5 }, 'scripts: single-line offset')

    local external = scripts.parse_fence({ '> ./handler.js' }, 0)
    t.eq(external.file, './handler.js', 'scripts: external path')
    t.eq(external.post, true, 'scripts: external post')
    t.same(external.offset, { row = 0, col = 2 }, 'scripts: external offset')

    local unclosed, after = scripts.parse_fence({ '> {%', '  client.log(1);' }, 0)
    t.eq(unclosed, nil, 'scripts: unterminated fence returns nil')
    t.eq(after, 2, 'scripts: unterminated fence consumes the buffer')
end

-- ------------------------------------------------------- request.parse_chunk

do
    local lines = { '@host = example.test', '', 'GET https://{{host}}/a' }
    local scope = new_scope()
    local req = request.parse_chunk({
        lines = lines,
        first_row = 0,
        end_row = #lines,
        index = 1,
        head_scope = 'file',
    }, scope)
    t.eq(req.url, 'https://{{host}}/a', 'parse_chunk: url')
    t.eq(scope.variables.host, 'example.test', 'parse_chunk: file scope variable')
    t.eq(req.variables.host, nil, 'parse_chunk: file scope variable is not block scope')

    local block_scope = new_scope()
    local block_req = request.parse_chunk({
        lines = lines,
        first_row = 0,
        end_row = #lines,
        index = 2,
        head_scope = 'block',
    }, block_scope)
    t.eq(block_req.variables.host, 'example.test', 'parse_chunk: block scope variable')
    t.eq(block_scope.variables.host, nil, 'parse_chunk: block scope variable stays block level')

    local orphan_scope = new_scope()
    local orphan = request.parse_chunk({ lines = { '@a = 1', '# just a comment' }, first_row = 0, end_row = 2 }, orphan_scope)
    t.eq(orphan, nil, 'parse_chunk: no request line returns nil')
    t.eq(orphan_scope.variables.a, '1', 'parse_chunk: request-less chunk keeps variables in the file scope')
end

-- ------------------------------------------------------------ parse_basic

do
    local lines = t.fixture('parse_basic.http')
    local result = parse(lines)

    t.eq(#result.requests, 3, 'basic: request count')
    t.eq(#result.diagnostics, 0, 'basic: no diagnostics')

    local first = result.requests[1]
    t.eq(first.index, 1, 'basic: index')
    t.eq(first.method, 'GET', 'basic: method')
    t.eq(first.url, 'https://{{host}}/items', 'basic: url keeps placeholders')
    t.eq(first.name, 'list', 'basic: # @name')
    t.eq(first.title, nil, 'basic: preamble request has no title')
    t.eq(first.url_line, 4, 'basic: url_line')
    t.same(first.range, { start_row = 0, end_row = 6 }, 'basic: block range')
    t.eq(#first.headers, 1, 'basic: header count')
    t.eq(first.headers[1].name, 'Accept', 'basic: header name')
    t.eq(first.headers[1].row, 5, 'basic: header row')
    t.eq(first.body, nil, 'basic: no body')
    t.eq(#first.scripts.pre, 0, 'basic: no pre script')
    t.eq(#first.scripts.post, 0, 'basic: no post script')

    t.eq(result.file_variables.host, 'example.com', 'basic: file variable')
    t.eq(result.file_variables.token, 'abc', 'basic: lazy file variable value')
    t.eq(result.file_lazy_variables.token, true, 'basic: lazy flag')
    t.eq(result.preamble.variables.host, 'example.com', 'basic: preamble variable')

    local second = result.requests[2]
    t.eq(second.title, 'Create item', 'basic: separator title')
    t.eq(second.method, 'POST', 'basic: post method')
    t.eq(header_value(second, 'X-Trace'), 'one two', 'basic: header value continuation')
    t.eq(second.body.kind, 'json', 'basic: json body kind')
    t.eq(second.body.text, '{\n  "name": "widget",\n  "tags": ["a", "b"]\n}', 'basic: body text is byte exact')
    t.same(second.body.range, { start_row = 15, end_row = 19 }, 'basic: body range')
    t.eq(#second.scripts.post, 1, 'basic: post script count')
    t.eq(second.scripts.post[1].source, '  client.log("created");', 'basic: post script source')
    t.same(second.scripts.post[1].offset, { row = 21, col = 0 }, 'basic: post script offset')

    local third = result.requests[3]
    t.eq(third.title, 'Submit the form', 'basic: third title')
    t.eq(third.body.kind, 'urlencoded', 'basic: urlencoded body kind')
    t.eq(third.body.text, 'a=1&b=2', 'basic: urlencoded body text')
    t.eq(header_value(third, 'Authorization'), 'Bearer {{token}}', 'basic: unresolved placeholder in header')
end

-- ------------------------------------------------------------- parse_edge

do
    local result = parse(t.fixture('parse_edge.http'))
    t.eq(#result.requests, 7, 'edge: request count')
    t.eq(#result.diagnostics, 0, 'edge: no diagnostics')

    local implicit = result.requests[1]
    t.eq(implicit.method, 'GET', 'edge: method defaults to GET')
    t.eq(implicit.url, 'https://example.com/implicit?page=1&limit=10', 'edge: url continuation both styles')
    t.eq(implicit.url_line, 10, 'edge: continuation keeps url_line')
    t.eq(implicit.meta.timeout_ms, 2500, 'edge: timeout_ms')
    t.eq(implicit.meta.proxy, 'http://localhost:8080', 'edge: proxy')
    t.eq(implicit.meta.no_redirect, true, 'edge: no_redirect')
    t.eq(implicit.meta.no_cookie_jar, true, 'edge: no_cookie_jar')
    t.eq(implicit.meta.insecure, true, 'edge: insecure')
    t.eq(implicit.meta.raw['custom-thing'], 'abc', 'edge: unknown metadata goes to meta.raw')
    t.eq(implicit.body, nil, 'edge: implicit GET has no body')

    local xml = result.requests[2]
    t.eq(xml.title, 'XML payload', 'edge: title after two separator lines')
    t.eq(xml.http_version, 'HTTP/1.1', 'edge: http version')
    t.eq(xml.url, 'https://example.com/xml', 'edge: url without version suffix')
    t.eq(xml.name, 'xmlPayload', 'edge: name metadata')
    t.eq(xml.body.kind, 'xml', 'edge: xml body kind')
    t.eq(xml.body.text, '<note>\n  <to>you</to>\n</note>', 'edge: xml body text')

    local external = result.requests[3]
    t.eq(external.ref, 'xmlPayload', 'edge: ref metadata')
    t.eq(external.body.kind, 'external', 'edge: external body kind')
    t.eq(external.body.file, './payload.bin', 'edge: external body file')
    t.eq(external.body.text, nil, 'edge: external body has no text')

    t.eq(result.requests[4].body.kind, 'multipart', 'edge: multipart body kind')
    t.eq(result.requests[5].body.kind, 'graphql', 'edge: graphql body kind')

    local scripted = result.requests[6]
    t.eq(#scripted.scripts.pre, 1, 'edge: pre script without a blank line before the request')
    t.eq(scripted.scripts.pre[1].source, '  request.variables.set("nonce", "abc");', 'edge: pre script source')
    t.same(scripted.scripts.pre[1].offset, { row = 52, col = 0 }, 'edge: pre script offset')
    t.eq(#scripted.scripts.post, 1, 'edge: post file script without a blank line')
    t.eq(scripted.scripts.post[1].file, './handler.js', 'edge: post file script path')
    t.eq(scripted.scripts.post[1].post, true, 'edge: post file script is a response handler')
    t.same(scripted.scripts.post[1].offset, { row = 55, col = 2 }, 'edge: post file script offset')
    t.eq(scripted.body, nil, 'edge: scripts do not invent a body')

    local asserted = result.requests[7]
    t.eq(asserted.meta.lang, 'json', 'edge: @lang metadata')
    t.eq(asserted.body.kind, 'json', 'edge: @lang overrides Content-Type')
    t.eq(asserted.variables.count, '2', 'edge: block variable')
    t.eq(asserted.lazy_variables.lazy, true, 'edge: block lazy variable')
    t.eq(#asserted.assertions, 2, 'edge: assertion count')
    t.eq(asserted.assertions[1].row, 67, 'edge: assertion row')
    t.eq(asserted.assertions[1].raw, '?? status == 200', 'edge: assertion raw text')
    t.eq(#asserted.scripts.post, 1, 'edge: assertion block keeps the post script')
    t.eq(asserted.scripts.post[1].source, '  client.log("checked");', 'edge: post script after assertions')
end

-- ------------------------------------------------------------ inline cases

do
    local empty = parse({})
    t.eq(#empty.requests, 0, 'inline: empty file')
    t.eq(#empty.diagnostics, 0, 'inline: empty file has no diagnostics')
    t.eq(parse(nil).requests ~= nil, true, 'inline: nil input does not raise')
    t.eq(#parse({ '', '', '' }).requests, 0, 'inline: blank lines only')

    t.eq(#parse({ '###' }).requests, 0, 'inline: lone separator creates no request')
    t.eq(#parse({ 'GET https://a.test/x', '###' }).requests, 1, 'inline: trailing separator creates no request')
end

do
    local only_preamble = parse({
        '@a = 1',
        '@b := 2',
        '# @timeout 100',
        '< {%',
        '  pre();',
        '%}',
    })
    t.eq(#only_preamble.requests, 0, 'preamble: no requests')
    t.eq(only_preamble.file_variables.a, '1', 'preamble: file variable')
    t.eq(only_preamble.file_lazy_variables.b, true, 'preamble: lazy file variable')
    t.eq(only_preamble.preamble.meta.timeout_ms, 100, 'preamble: meta')
    t.eq(#only_preamble.preamble.scripts.pre, 1, 'preamble: file level pre script')
    t.eq(only_preamble.preamble.scripts.pre[1].source, '  pre();', 'preamble: pre script source')
end

do
    local crlf = parse({ 'GET https://a.test/x\r', 'Accept: application/json\r', '\r', '{"a":1}\r' })
    local req = crlf.requests[1]
    t.eq(req.url, 'https://a.test/x', 'crlf: url has no carriage return')
    t.eq(req.headers[1].value, 'application/json', 'crlf: header value')
    t.eq(req.body.text, '{"a":1}', 'crlf: body text')
    t.eq(req.body.kind, 'json', 'crlf: body kind from the first character')
end

do
    local result = parse({
        '# leading comment',
        '// another comment',
        '/* block',
        '   comment */',
        'GET https://a.test/x',
        '',
        '###',
        '### second title',
        'GET https://a.test/y',
        '###',
    })
    t.eq(#result.requests, 2, 'separators: two requests around comment-only blocks')
    t.eq(result.requests[1].url, 'https://a.test/x', 'separators: first request skips block comments')
    t.eq(result.requests[1].title, nil, 'separators: first request has no title')
    t.eq(result.requests[2].title, 'second title', 'separators: title belongs to the next block')
    t.eq(result.requests[2].url, 'https://a.test/y', 'separators: second request url')
end

do
    local result = parse({ 'GET' })
    t.eq(#result.requests, 1, 'no_url: request is still returned')
    t.eq(result.requests[1].url, '', 'no_url: empty url')
    t.eq(result.diagnostics[1].code, 'parse.no_url', 'no_url: diagnostic code')
    t.eq(result.diagnostics[1].severity, 'error', 'no_url: diagnostic severity')
    t.eq(result.diagnostics[1].row, 0, 'no_url: diagnostic row')
    t.eq(result.diagnostics[1].col, 0, 'no_url: diagnostic col')
end

do
    local result = parse({
        'POST https://a.test/x',
        'Content-Type: application/json',
        '',
        '{',
        '/* ignored */',
        '// ignored too',
        '  "a": 1',
        '}',
    })
    local req = result.requests[1]
    t.eq(req.body.kind, 'json', 'comments: comment lines do not end the body')
    t.eq(req.body.text, '{\n  "a": 1\n}', 'comments: comment lines are not part of the body text')
    t.same(req.body.range, { start_row = 3, end_row = 8 }, 'comments: body range spans the block')
end

do
    local result = parse({
        'POST https://a.test/x',
        'Content-Type: application/json',
        '{"a":1}',
    })
    t.eq(result.requests[1].body.kind, 'json', 'header_expected: body starts without a blank line')
    t.eq(#result.requests[1].headers, 1, 'header_expected: json line is not a header')
    t.eq(result.diagnostics[1].code, 'parse.header_expected', 'header_expected: diagnostic code')
    t.eq(result.diagnostics[1].severity, 'warning', 'header_expected: diagnostic severity')
end

do
    local result = parse({ 'GET https://a.test/x HTTP/2', '  ?a=1', 'Accept: */*' })
    local req = result.requests[1]
    t.eq(req.http_version, 'HTTP/2', 'version: http_version')
    t.eq(req.url, 'https://a.test/x?a=1', 'version: version suffix is not part of the url')
    t.eq(#req.headers, 1, 'version: headers after a continued url')
end

do
    t.eq(parse({ 'get https://a.test/x' }).requests[1].method, 'GET', 'method: lower case is upper-cased')
    t.eq(parse({ 'propfind https://a.test/x' }).requests[1].method, 'PROPFIND', 'method: webdav extension method')
    t.eq(parse({ 'https://a.test/x' }).requests[1].method, 'GET', 'method: missing method defaults to GET')
end

do
    local result = parse({ 'GET https://a.test/x', '@token = t1', 'Accept: */*' })
    t.eq(result.requests[1].variables.token, 't1', 'variables: block level declaration')
    t.eq(result.file_variables.token, nil, 'variables: block level declaration is not file level')
end

do
    local result = parse({ 'GET https://a.test/x', 'Accept: */*', '> ./h.js' })
    t.eq(#result.requests[1].headers, 1, 'handler: headers without a trailing blank line')
    t.eq(result.requests[1].scripts.post[1].file, './h.js', 'handler: post file script without a blank line')
    t.eq(result.requests[1].body, nil, 'handler: no body is invented')
end

do
    local result = parse({ 'GET https://a.test/x', '> {%', '  client.log(1);', '%}' })
    local post = result.requests[1].scripts.post[1]
    t.eq(post.source, '  client.log(1);', 'handler: fence right after the request line')
    t.same(post.offset, { row = 2, col = 0 }, 'handler: fence offset')
end

do
    local result = parse({ 'GET https://a.test/x', '> {%', '  client.log(1);' })
    t.eq(#result.requests[1].scripts.post, 0, 'handler: unterminated fence keeps no script')
    t.eq(has_code(result.diagnostics, 'parse.unclosed_script'), true, 'handler: unterminated fence diagnostic')
end

do
    local result = parse({ '# @name login', '# @ref other', '# @whatever yes', 'GET https://a.test/x' })
    t.eq(result.requests[1].name, 'login', 'meta: @name')
    t.eq(result.requests[1].ref, 'other', 'meta: @ref')
    t.eq(result.requests[1].meta.raw.whatever, 'yes', 'meta: unknown key kept in raw')
end

do
    local result = parse({ '# @timeout soon', 'GET https://a.test/x' })
    t.eq(result.requests[1].meta.timeout_ms, nil, 'meta: invalid timeout is ignored')
    t.eq(has_code(result.diagnostics, 'parse.invalid_timeout'), true, 'meta: invalid timeout diagnostic')
end

do
    local result = parse({
        '< {%',
        '  request.variables.set("a", 1);',
        '%}',
        'POST https://a.test/x',
        'Content-Type: application/json',
        '',
        '{"a":1}',
    })
    local req = result.requests[1]
    t.eq(#req.scripts.pre, 1, 'scripts: pre script before the request line')
    t.eq(req.scripts.pre[1].post, false, 'scripts: pre script flag')
    t.eq(req.body.kind, 'json', 'scripts: pre script keeps the body')
    t.eq(req.body.text, '{"a":1}', 'scripts: body text after a pre script')
end

do
    local result = parse({ 'POST https://a.test/x', 'Content-Type: text/plain', '', 'plain text body' })
    t.eq(result.requests[1].body.kind, 'raw', 'body: text/plain is raw')
    t.eq(result.requests[1].body.text, 'plain text body', 'body: raw text')
end

do
    local result = parse({ 'POST https://a.test/x', '', 'a=1', '&b=2', '', '' })
    t.eq(result.requests[1].body.kind, 'raw', 'body: missing separator lines')
    t.eq(result.requests[1].body.text, 'a=1\n&b=2', 'body: trailing blank lines are trimmed')
end

-- ------------------------------------------------------------- request_at

do
    local result = parse({
        '@a = 1',
        '',
        '###',
        'GET https://a.test/one',
        '',
        '###',
        '### two',
        'POST https://a.test/two',
        'Content-Type: text/plain',
        '',
        'hi',
    })
    t.eq(#result.requests, 2, 'request_at: two requests')
    t.eq(block.request_at(result, 0), nil, 'request_at: preamble row')
    t.eq(block.request_at(result, 2), nil, 'request_at: separator row')
    t.eq(block.request_at(result, 3), result.requests[1], 'request_at: request line row')
    t.eq(block.request_at(result, 4), nil, 'request_at: blank row outside the range')
    t.eq(block.request_at(result, 7), result.requests[2], 'request_at: second request')
    t.eq(block.request_at(result, 10), result.requests[2], 'request_at: body row')
    t.eq(block.request_at(result, 11), nil, 'request_at: past the last block')
    t.eq(block.request_at(result, -1), nil, 'request_at: negative row')
    t.eq(cursor.request_at(result, 7), result.requests[2], 'request_at: cursor wrapper')
end

-- -------------------------------------------------------- the real corpus

do
    local result = block.parse(vim.fn.readfile(t.root() .. '/test.http'))
    t.eq(#result.requests, 18, 'corpus: request count')
    t.eq(#result.diagnostics, 0, 'corpus: no diagnostics')
    t.eq(result.file_variables.base, 'https://jsonplaceholder.typicode.com', 'corpus: @base is a file variable')

    local methods = {}
    for _, req in ipairs(result.requests) do
        methods[#methods + 1] = req.method
    end
    t.eq(table.concat(methods, ' '),
        'GET GET GET GET GET GET POST POST PUT PUT PATCH PATCH DELETE DELETE HEAD OPTIONS GET POST',
        'corpus: method sequence')
    t.eq(result.requests[1].title, '---------- 1. GET - 获取资源列表 ----------', 'corpus: first block title')
    t.eq(result.requests[1].url, '{{base}}/posts', 'corpus: {{base}} stays unresolved')

    for index, req in ipairs(result.requests) do
        if req.method == 'POST' then
            t.eq(header_value(req, 'Content-Type'), 'application/json',
                ('corpus: POST %d Content-Type'):format(index))
            t.eq((req.body.text or '#'):sub(1, 1), '{', ('corpus: POST %d json body'):format(index))
        end
    end

    local last = result.requests[#result.requests]
    t.eq(last.url, '{{base}}/invalid-resource', 'corpus: trailing request url')
    t.eq(last.body.text, '{\n  "foo": "bar"\n}', 'corpus: trailing request body')
end

t.finish()
