-- Turns curl's scratch files (headers dump, body, `-w '%{json}'` output) into the
-- Response structure of INTERFACES §1.6. The writeout JSON is the primary source of
-- metadata; the headers dump is the fallback for curl < 7.70 (DESIGN §7.2).
local str = require('rikuesto.util.str')

local M = {}

local DEFAULT_MAX_BYTES = 2097152
local TIMEOUT_EXIT_CODES = { [28] = true }
local NETWORK_EXIT_CODES = { [6] = true, [7] = true, [35] = true, [52] = true, [55] = true, [56] = true }

local function read_text(path)
    if type(path) ~= 'string' or path == '' then
        return ''
    end
    -- luv instead of vim.fn.readfile: byte-exact and safe inside libuv callbacks.
    local fd = vim.uv.fs_open(path, 'r', 0)
    if not fd then
        return ''
    end
    local stat = vim.uv.fs_fstat(fd)
    local text = ''
    if stat and stat.size and stat.size > 0 then
        text = vim.uv.fs_read(fd, stat.size, 0) or ''
    end
    vim.uv.fs_close(fd)
    return text
end

local function first_line(text)
    if type(text) ~= 'string' then
        return ''
    end
    return str.trim(text:match('^[^\r\n]*') or '')
end

local function to_number(value)
    if type(value) == 'number' then
        return value
    end
    if type(value) == 'string' then
        return tonumber(value)
    end
    return nil
end

--- `application/json; charset=utf-8` -> { mime = 'application/json', charset = 'utf-8' }
local function split_content_type(value)
    if type(value) ~= 'string' then
        return nil
    end
    local mime = str.trim(value:match('^([^;]*)') or '')
    if mime == '' then
        return nil
    end
    local charset = value:match('[Cc][Hh][Aa][Rr][Ss][Ee][Tt]%s*=%s*"?([^";%s]+)"?')
    return { mime = mime, charset = charset }
end

local function parse_status_line(line)
    local version, status, reason = line:match('^HTTP/(%d[%.%d]*)%s+(%d%d%d)%s*(.*)$')
    if not version then
        return nil
    end
    return { http_version = version, status = tonumber(status), reason = str.trim(reason) }
end

--- Splits a `-D` dump into one block per response so a redirect chain keeps its last block.
local function parse_headers_dump(text)
    local blocks = {}
    local block = nil
    for _, line in ipairs(str.lines(text)) do
        local status = parse_status_line(line)
        if status then
            block = {
                http_version = status.http_version,
                status = status.status,
                reason = status.reason,
                headers = {},
                raw = { line },
            }
            blocks[#blocks + 1] = block
        elseif block then
            block.raw[#block.raw + 1] = line
            if str.is_blank(line) then
                -- header section terminator; nothing to record
            elseif str.has_leading_ws(line) and #block.headers > 0 then
                -- obs-fold continuation of the previous header value
                local last = block.headers[#block.headers]
                last.value = last.value .. ' ' .. str.trim(line)
            else
                local name, value = line:match('^([^:%s]+)%s*:%s*(.*)$')
                if name then
                    block.headers[#block.headers + 1] = { name = name, value = str.trim(value) }
                end
            end
        end
    end
    for _, item in ipairs(blocks) do
        while #item.raw > 0 and str.is_blank(item.raw[#item.raw]) do
            item.raw[#item.raw] = nil
        end
    end
    return blocks
end

--- Clip to `max` bytes without splitting a UTF-8 sequence.
local function clip_utf8(text, max)
    if max <= 0 then
        return ''
    end
    local cut = max
    while cut > 0 do
        local byte = text:byte(cut)
        if byte and byte >= 0x80 and byte < 0xC0 then
            cut = cut - 1 -- walk back into the middle of a multi-byte character
        else
            break
        end
    end
    if cut <= 0 then
        return ''
    end
    local lead = text:byte(cut)
    local width = 1
    if lead >= 0xF0 then
        width = 4
    elseif lead >= 0xE0 then
        width = 3
    elseif lead >= 0xC0 then
        width = 2
    end
    if cut + width - 1 <= max then
        return text:sub(1, cut + width - 1)
    end
    return text:sub(1, cut - 1)
end

local function classify(meta, has_metadata)
    -- A user cancel is not a transport failure: keep it distinguishable so the UI can say so.
    if meta.cancelled then
        return { kind = 'cancelled', message = 'request cancelled' }
    end
    local code = to_number(meta.exit_code) or 0
    local message = first_line(meta.stderr)
    local lowered = string.lower(message)
    if meta.timed_out or TIMEOUT_EXIT_CODES[code] or lowered:find('timed out', 1, true)
        or lowered:find('timeout', 1, true) then
        return { kind = 'timeout', message = message ~= '' and message or 'curl timed out' }
    end
    if code ~= 0 then
        return {
            kind = NETWORK_EXIT_CODES[code] and 'network' or 'curl',
            message = message ~= '' and message or ('curl exited with code ' .. code),
        }
    end
    if not has_metadata then
        return { kind = 'curl', message = message ~= '' and message or 'curl returned no response metadata' }
    end
    return nil
end

--- @param paths table { headers = path, body = path, writeout = path }
--- @param meta table { exit_code, stderr, signal, timed_out, cancelled, url, max_bytes }
--- @return table Response
function M.parse(paths, meta)
    paths = paths or {}
    meta = meta or {}

    local body = read_text(paths.body)
    -- `--head` writes the response headers into the `-o` target, so a HEAD response has no body.
    if string.upper(tostring(meta.method or '')) == 'HEAD' then
        body = ''
    end
    local body_bytes = #body
    local blocks = parse_headers_dump(read_text(paths.headers))
    local last = blocks[#blocks] or nil

    local writeout = nil
    local writeout_text = read_text(paths.writeout)
    if writeout_text ~= '' then
        local ok, decoded = pcall(vim.json.decode, writeout_text)
        if ok and type(decoded) == 'table' then
            writeout = decoded
        end
    end

    local content_type_text = nil
    if last then
        for _, header in ipairs(last.headers) do
            if string.lower(header.name) == 'content-type' then
                content_type_text = header.value
                break
            end
        end
    end
    if writeout and type(writeout.content_type) == 'string' and writeout.content_type ~= '' then
        content_type_text = writeout.content_type
    end

    local status = writeout and to_number(writeout.http_code) or nil
    if not status or status == 0 then
        status = last and last.status or 0
    end
    local time_total = writeout and to_number(writeout.time_total) or nil
    local size = writeout and to_number(writeout.size_download) or nil
    local redirects = writeout and to_number(writeout.num_redirects) or nil
    if not redirects then
        redirects = math.max(#blocks - 1, 0)
    end

    local truncated = false
    local max_bytes = to_number(meta.max_bytes) or DEFAULT_MAX_BYTES
    if body ~= '' and #body > max_bytes then
        truncated = true
        body = clip_utf8(body, max_bytes)
    end

    local url_effective = meta.url
    if writeout and type(writeout.url_effective) == 'string' then
        url_effective = writeout.url_effective -- JSON null decodes to vim.NIL, not a string
    end

    local response = {
        ok = false,
        status = status or 0,
        reason = last and last.reason or '',
        http_version = last and last.http_version or nil,
        headers = last and last.headers or {},
        body = body,
        truncated = truncated,
        json = nil,
        content_type = split_content_type(content_type_text),
        duration_ms = time_total and (math.floor(time_total * 10000 + 0.5) / 10) or nil,
        size = size or body_bytes,
        url_effective = url_effective,
        redirects = redirects,
        raw_headers = last and table.concat(last.raw, '\n') or '',
        error = nil,
    }

    if not truncated and body ~= '' then
        local ok, decoded = pcall(vim.json.decode, body)
        if ok and type(decoded) == 'table' then
            response.json = decoded
        end
    end

    response.error = classify(meta, writeout ~= nil or last ~= nil or body_bytes > 0)
    response.ok = response.error == nil
    return response
end

return M
