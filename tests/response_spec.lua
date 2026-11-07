-- Response parsing from curl's scratch files: writeout JSON, headers dump fallback,
-- redirect folding, truncation and transport-error classification.
local t = require('tests.helper')
local response = require('rikuesto.http.response')

local HEADERS = table.concat({
    'HTTP/1.1 301 Moved Permanently',
    'Location: https://example.com/final',
    'Content-Length: 0',
    '',
    'HTTP/1.1 200 OK',
    'Content-Type: application/json; charset=utf-8',
    'X-Trace: abc',
    'X-Folded: first',
    ' second',
    'Content-Length: 292',
    '',
}, '\r\n')

local WRITEOUT = table.concat({
    '{"http_code":200,"time_total":0.123456,"size_download":292,',
    '"content_type":"application/json; charset=utf-8",',
    '"url_effective":"https://example.com/final","num_redirects":1}',
})

local function scratch()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    return dir
end

local function write(path, text)
    local file = assert(io.open(path, 'wb'))
    file:write(text)
    file:close()
end

--- Runs one parse over freshly written scratch files (a nil field = file absent).
local function parse_case(files, meta)
    local dir = scratch()
    local paths = {
        headers = dir .. '/headers.txt',
        body = dir .. '/body.bin',
        writeout = dir .. '/writeout.json',
    }
    for key, text in pairs(files or {}) do
        write(paths[key], text)
    end
    local parsed = response.parse(paths, meta or {})
    pcall(vim.fn.delete, dir, 'rf')
    return parsed
end

local function header_value(parsed, name)
    for _, header in ipairs(parsed.headers) do
        if string.lower(header.name) == string.lower(name) then
            return header.value
        end
    end
    return nil
end

t.module('http.response')

-- Full metadata path: `-w '%{json}'` present.
do
    local parsed = parse_case({
        headers = HEADERS,
        body = '{"id":7,"name":"rikuesto"}',
        writeout = WRITEOUT,
    }, { url = 'https://example.com/start' })

    t.eq(parsed.ok, true, 'ok on a completed request')
    t.eq(parsed.error, nil, 'no error')
    t.eq(parsed.status, 200, 'status from writeout')
    t.eq(parsed.reason, 'OK', 'reason from the last status line')
    t.eq(parsed.http_version, '1.1', 'http_version from the last status line')
    t.eq(parsed.duration_ms, 123.5, 'time_total seconds -> duration_ms')
    t.eq(parsed.size, 292, 'size_download -> size')
    t.eq(parsed.redirects, 1, 'num_redirects -> redirects')
    t.eq(parsed.url_effective, 'https://example.com/final', 'url_effective from writeout')
    t.eq(parsed.truncated, false, 'not truncated')
    t.same(parsed.content_type, { mime = 'application/json', charset = 'utf-8' }, 'content_type split')
    t.eq(parsed.json and parsed.json.id, 7, 'body decoded into json')
    t.eq(parsed.json and parsed.json.name, 'rikuesto', 'json string field')
    t.eq(#parsed.headers, 4, 'only the final block headers are kept')
    t.eq(header_value(parsed, 'Content-Type'), 'application/json; charset=utf-8', 'content-type header')
    t.eq(header_value(parsed, 'X-Folded'), 'first second', 'obs-fold continuation joined')
    t.contains(parsed.raw_headers, 'HTTP/1.1 200 OK', 'raw_headers carries the final status line')
    t.eq(parsed.raw_headers:find('Location', 1, true), nil, 'raw_headers drops the redirect block')
end

-- 4xx is a completed request (only transport failures set `error`).
do
    local parsed = parse_case({
        headers = 'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\n',
        body = 'nope',
        writeout = '{"http_code":404,"time_total":0.02,"size_download":4,"num_redirects":0}',
    })
    t.eq(parsed.ok, true, '404 keeps ok true')
    t.eq(parsed.status, 404, 'status 404')
    t.eq(parsed.reason, 'Not Found', 'reason 404')
    t.eq(parsed.json, nil, 'non-JSON body leaves json nil')
    t.same(parsed.content_type, { mime = 'text/plain' }, 'content_type without charset')
end

-- curl < 7.70 fallback: no `%{json}`, rebuild from the headers dump.
do
    local parsed = parse_case({
        headers = HEADERS,
        body = '{"a":1}',
    }, { url = 'https://example.com/start' })

    t.eq(parsed.status, 200, 'fallback status from the last status line')
    t.eq(parsed.reason, 'OK', 'fallback reason')
    t.eq(parsed.duration_ms, nil, 'fallback has no duration')
    t.eq(parsed.redirects, 1, 'fallback counts redirects from the dump')
    t.eq(parsed.size, 7, 'fallback size is the body length')
    t.eq(parsed.url_effective, 'https://example.com/start', 'fallback url_effective from meta')
    t.eq(parsed.json and parsed.json.a, 1, 'fallback still decodes json')
    t.eq(parsed.error, nil, 'fallback has no error')
end

-- An empty writeout file is the same fallback path.
do
    local parsed = parse_case({ headers = HEADERS, body = '', writeout = '' })
    t.eq(parsed.status, 200, 'empty writeout falls back to the dump')
    t.eq(parsed.size, 0, 'empty body -> size 0')
    t.eq(parsed.ok, true, 'empty writeout is not an error')
end

-- Truncation: body clipped to max_bytes, size keeps the real download size.
do
    local parsed = parse_case({
        headers = 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n',
        body = string.rep('a', 100),
        writeout = '{"http_code":200,"time_total":0.01,"size_download":100,"num_redirects":0}',
    }, { max_bytes = 40 })
    t.eq(parsed.truncated, true, 'truncated flag set')
    t.eq(#parsed.body, 40, 'body clipped to max_bytes')
    t.eq(parsed.size, 100, 'size keeps the real byte count')
    t.eq(parsed.json, nil, 'truncated body is not decoded')
end

-- Truncation never splits a UTF-8 sequence.
do
    local parsed = parse_case({
        headers = 'HTTP/1.1 200 OK\r\n\r\n',
        body = string.rep('\195\169', 10),
        writeout = '{"http_code":200,"time_total":0.01,"size_download":20,"num_redirects":0}',
    }, { max_bytes = 5 })
    t.eq(parsed.truncated, true, 'multi-byte body truncated')
    t.eq(#parsed.body, 4, 'clipped body ends on a character boundary')
end

-- Transport errors: timeout, network, cancelled, missing metadata.
do
    local timed_out = parse_case({
        headers = '',
        body = '',
        writeout = '{"http_code":0,"time_total":30.0}',
    }, { exit_code = 28, stderr = 'curl: (28) Operation timed out after 30001 milliseconds' })
    t.eq(timed_out.error and timed_out.error.kind, 'timeout', 'exit 28 -> timeout')
    t.eq(timed_out.ok, false, 'timeout is not ok')
    t.contains(timed_out.error.message, 'timed out', 'timeout message from stderr')

    local killed = parse_case({}, { signal = 9, timed_out = true })
    t.eq(killed.error and killed.error.kind, 'timeout', 'killed by vim.system timeout -> timeout')

    local network = parse_case({}, { exit_code = 6, stderr = 'curl: (6) Could not resolve host: nope.invalid' })
    t.eq(network.error and network.error.kind, 'network', 'exit 6 -> network')
    t.contains(network.error.message, 'Could not resolve host', 'network message from stderr')

    local cancelled = parse_case({}, { cancelled = true, exit_code = -1 })
    t.eq(cancelled.error and cancelled.error.kind, 'cancelled', 'cancel has its own error kind')
    t.eq(cancelled.error and cancelled.error.message, 'request cancelled', 'cancel message')

    local nothing = parse_case({})
    t.eq(nothing.error and nothing.error.kind, 'curl', 'missing metadata -> curl error')
    t.contains(nothing.error.message, 'no response metadata', 'missing metadata message')
    t.eq(nothing.status, 0, 'missing metadata -> status 0')
    t.eq(nothing.ok, false, 'missing metadata is not ok')
end

t.finish()
