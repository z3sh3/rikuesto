-- Line-based parser for one request block. This is the semantic source of truth
-- for HTTP structure; no treesitter API is involved (docs/DESIGN.md §3, appendix B).
local M = {}

local metadata = require('rikuesto.parse.metadata')
local scripts = require('rikuesto.parse.scripts')
local str = require('rikuesto.util.str')
local variables = require('rikuesto.parse.variables')

-- Union of the http-files.org standard methods and the WebDAV/extension ones.
local METHODS = {
    CONNECT = true,
    COPY = true,
    DELETE = true,
    GET = true,
    HEAD = true,
    LOCK = true,
    MKCOL = true,
    MOVE = true,
    OPTIONS = true,
    PATCH = true,
    POST = true,
    PROPFIND = true,
    PUT = true,
    REPORT = true,
    SEARCH = true,
    TRACE = true,
    UNLOCK = true,
}

-- `# @lang <value>` overrides the body kind.
local LANG_KINDS = {
    json = 'json',
    xml = 'xml',
    graphql = 'graphql',
    urlencoded = 'urlencoded',
    multipart = 'multipart',
    raw = 'raw',
    text = 'raw',
}

-- Checked in order against the lower-cased Content-Type value.
local CONTENT_TYPE_KINDS = {
    { kind = 'multipart', needle = 'multipart/form-data' },
    { kind = 'urlencoded', needle = 'x-www-form-urlencoded' },
    { kind = 'graphql', needle = 'graphql' },
    { kind = 'json', needle = 'json' },
    { kind = 'xml', needle = 'xml' },
}

local function is_comment(line)
    return line:match('^%s*#') ~= nil or line:match('^%s*//') ~= nil
end

-- RFC 7230 tchar set for header names: keeps JSON/urlencoded body lines from
-- being mistaken for headers when the separating blank line is missing.
local HEADER_PATTERN = "^([%w!#%$%%&'%*%+%-%.%^_`|~]+)%s*:%s*(.-)%s*$"

--- Skip `/* ... */` lines. Returns skipped, still_inside_comment.
local function skip_block_comment(line, inside)
    if inside then
        return true, line:find('*/', 1, true) == nil
    end
    if line:match('^%s*/%*') then
        return true, line:find('*/', 1, true) == nil
    end
    return false, false
end

--- Last `Content-Type` wins, matching the header de-duplication rule.
local function content_type_of(headers)
    local found
    for _, header in ipairs(headers) do
        if header.name:lower() == 'content-type' then
            found = header.value
        end
    end
    return found
end

--- Body kind + external path. Priority: single-line `< ./path` (structural),
--- `# @lang`, `Content-Type`, first non-space character.
local function detect_body(text, content_type, lang)
    if not text:find('\n', 1, true) then
        local path = text:match('^<%s*(%S+)%s*$')
        if path then
            return 'external', path
        end
    end
    if lang then
        local kind = LANG_KINDS[lang:lower()]
        if kind then
            return kind
        end
    end
    if content_type then
        local lower = content_type:lower()
        for _, entry in ipairs(CONTENT_TYPE_KINDS) do
            if lower:find(entry.needle, 1, true) then
                return entry.kind
            end
        end
    end
    local first = text:match('^%s*(.)')
    if first == '{' or first == '[' then
        return 'json'
    end
    if first == '<' then
        return 'xml'
    end
    return 'raw'
end

--- `[Method] URL [HTTP-Version]`; parses into `req` and reports a missing URL.
local function parse_request_line(req, line, row, add_diagnostic)
    local text = str.trim(line)
    local word, rest = text:match('^(%S+)%s*(.*)$')
    if word and METHODS[word:upper()] then
        req.method = word:upper()
        text = rest
    end
    req.url_line = row
    local url, version = text:match('^(.-)%s+(HTTP/%d[%d%.]*)$')
    if url then
        req.http_version = version
        text = url
    end
    req.url = str.trim(text)
    if req.url == '' then
        add_diagnostic(row, 0, 'error', 'parse.no_url', 'request line has no URL')
    end
end

--- Parse one chunk of `.http` source.
---
--- chunk = { lines = string[], first_row = 0, end_row = #lines, index = 1,
---           title = '...', head_scope = 'file'|'block' }
---   `lines` holds the whole buffer (1-based Lua table, so `lines[row + 1]` is the
---   text of 0-based row `row`); `first_row`/`end_row` bound the chunk (end exclusive).
---   `head_scope` decides where declarations seen before the request line belong:
---   'file' (first request of the file) or 'block'.
--- scope = optional out table { variables, lazy_variables, scripts = { pre = {} }, meta }
---   that receives file-level constructs when the chunk yields no request.
---
--- Returns Request|nil, Diagnostic[].
function M.parse_chunk(chunk, scope)
    chunk = type(chunk) == 'table' and chunk or {}
    local lines = chunk.lines or {}
    local first_row = chunk.first_row or 0
    local end_row = chunk.end_row or #lines
    local diagnostics = {}

    local req = {
        index = chunk.index,
        name = nil,
        ref = nil,
        title = chunk.title,
        method = 'GET',
        url = '',
        http_version = nil,
        headers = {},
        body = nil,
        scripts = { pre = {}, post = {} },
        assertions = {},
        variables = {},
        lazy_variables = {},
        meta = metadata.empty(),
        range = { start_row = first_row, end_row = first_row },
        url_line = nil,
    }

    local function add_diagnostic(row, col, severity, code, message)
        diagnostics[#diagnostics + 1] = {
            row = row,
            col = col,
            severity = severity,
            message = message,
            code = code,
        }
    end

    local state = 'head' -- head -> url -> headers -> body
    local inside_comment = false
    local last_header = nil
    local meta_entries = {}
    local head_vars, head_lazy = {}, {}
    local body_lines = {}
    local body_first_row, body_last_row, body_end_row = nil, nil, nil
    local pending_blanks = 0
    local body_done = false
    local first_content_row, last_content_row = nil, nil
    local stop = false

    local function append_body(row, text)
        if body_done then
            return
        end
        if body_first_row == nil then
            body_first_row = row
            pending_blanks = 0 -- blank lines before the body are the separator
        end
        while pending_blanks > 0 do
            body_lines[#body_lines + 1] = ''
            pending_blanks = pending_blanks - 1
        end
        body_lines[#body_lines + 1] = text
        body_last_row = row
    end

    local function close_body()
        if body_done then
            return
        end
        body_done = true
        if body_last_row ~= nil then
            body_end_row = body_last_row + 1
        end
    end

    local row = first_row
    while row < end_row and not stop do
        local line = lines[row + 1]
        if type(line) ~= 'string' then
            line = ''
        end
        local advance = 1

        repeat
            local skipped, still_inside = skip_block_comment(line, inside_comment)
            inside_comment = still_inside
            if skipped then
                break
            end

            -- Defensive: block.lua already splits on separators.
            if line:match('^###+') then
                stop = true
                break
            end

            if str.is_blank(line) then
                if state == 'url' or state == 'headers' then
                    state = 'body'
                elseif state == 'body' and body_first_row ~= nil and not body_done then
                    pending_blanks = pending_blanks + 1
                end
                break
            end

            if first_content_row == nil then
                first_content_row = row
            end
            last_content_row = row

            local entry = metadata.parse_line(line)
            if entry then
                meta_entries[#meta_entries + 1] = { parsed = entry, row = row }
                break
            end

            if is_comment(line) then
                break
            end

            if line:match('^%s*%?%?') then
                close_body()
                req.assertions[#req.assertions + 1] = { row = row, raw = str.trim(line) }
                break
            end

            local variable = variables.parse_line(line)
            if variable then
                if state == 'head' then
                    head_vars[variable.name] = variable.value
                    if variable.lazy then
                        head_lazy[variable.name] = true
                    end
                else
                    req.variables[variable.name] = variable.value
                    if variable.lazy then
                        req.lazy_variables[variable.name] = true
                    end
                end
                break
            end

            local shape, post = scripts.classify(line)
            -- `< ./payload.bin` inside a body is the external body, not a pre-request script.
            local external_body = shape == 'file' and not post and state == 'body'
            if shape and not external_body then
                local script, next_row = scripts.parse_fence(lines, row)
                if script then
                    -- A pre-request script may sit before the request line; only a
                    -- response handler (or a script after body lines) ends the body.
                    if script.post or state == 'body' then
                        close_body()
                    end
                    local bucket = script.post and req.scripts.post or req.scripts.pre
                    bucket[#bucket + 1] = script
                    advance = math.max(1, next_row - row)
                    last_content_row = math.max(last_content_row or row, next_row - 1)
                else
                    add_diagnostic(row, 0, 'error', 'parse.unclosed_script',
                        'script block is not closed with %}')
                    stop = true
                end
                break
            end

            if state == 'head' then
                parse_request_line(req, line, row, add_diagnostic)
                state = 'url'
                break
            end

            if state == 'url' then
                local lead = line:sub(1, 1)
                if str.has_leading_ws(line) or lead == '?' or lead == '&' then
                    req.url = req.url .. str.trim(line)
                    break
                end
                state = 'headers'
            end

            if state == 'headers' then
                local name, value = line:match(HEADER_PATTERN)
                if name then
                    last_header = { name = name, value = value, row = row }
                    req.headers[#req.headers + 1] = last_header
                    break
                end
                if last_header and str.has_leading_ws(line) then
                    last_header.value = last_header.value .. ' ' .. str.trim(line)
                    break
                end
                -- No blank line before the body: accept it and keep going.
                add_diagnostic(row, 0, 'warning', 'parse.header_expected',
                    'expected a header line or a blank line before the body')
                state = 'body'
            end

            if state == 'body' then
                append_body(row, line)
                break
            end
        until true

        row = row + advance
    end

    -- Metadata is applied once, in declaration order (last assignment wins).
    for _, entry in ipairs(meta_entries) do
        local key = entry.parsed.key
        if key == 'name' then
            req.name = entry.parsed.value
        elseif key == 'ref' then
            req.ref = entry.parsed.value
        else
            local handled, diagnostic = metadata.apply(req.meta, entry.parsed, entry.row)
            if not handled then
                req.meta.raw[key] = entry.parsed.value ~= nil and entry.parsed.value or true
            elseif diagnostic then
                diagnostics[#diagnostics + 1] = diagnostic
            end
        end
    end

    if not req.url_line then
        -- No request in this chunk: everything collected belongs to the file scope.
        if scope then
            for name, value in pairs(head_vars) do
                scope.variables[name] = value
            end
            for name in pairs(head_lazy) do
                scope.lazy_variables[name] = true
            end
            for _, script in ipairs(req.scripts.pre) do
                scope.scripts.pre[#scope.scripts.pre + 1] = script
            end
            metadata.merge(scope.meta, req.meta)
        end
        return nil, diagnostics
    end

    local to_file_scope = scope ~= nil and chunk.head_scope == 'file'
    for name, value in pairs(head_vars) do
        if to_file_scope then
            scope.variables[name] = value
        else
            req.variables[name] = value
        end
    end
    for name in pairs(head_lazy) do
        if to_file_scope then
            scope.lazy_variables[name] = true
        else
            req.lazy_variables[name] = true
        end
    end

    if body_first_row ~= nil then
        local text = table.concat(body_lines, '\n')
        local kind, file = detect_body(text, content_type_of(req.headers), req.meta.lang)
        req.body = {
            kind = kind,
            file = file,
            range = { start_row = body_first_row, end_row = body_end_row or (body_last_row + 1) },
        }
        if kind ~= 'external' then
            req.body.text = text
        end
    end

    req.range = {
        start_row = first_content_row or first_row,
        end_row = (last_content_row or first_row) + 1,
    }

    return req, diagnostics
end

return M
