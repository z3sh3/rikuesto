-- Renders one parsed Request into .http lines. The formatter owns row placement, blank
-- lines and comment preservation; this module owns the content of each structural element.
local M = {}

local tools = require('rikuesto.format.tools')
local json_internal = require('rikuesto.format.json_internal')
local util_str = require('rikuesto.util.str')
local log = require('rikuesto.util.log')

--- Mask `{{ ... }}` placeholders so whitespace normalization cannot touch variable names.
local function mask_braces(text)
    local saved = {}
    local masked = text:gsub('{{[^{}]*}}', function(match_text)
        saved[#saved + 1] = match_text
        return '\1' .. tostring(#saved) .. '\2'
    end)
    return masked, saved
end

local function unmask_braces(text, saved)
    return (text:gsub('\1(%d+)\2', function(index)
        return saved[tonumber(index)] or ''
    end))
end

--- Collapse whitespace runs, but never inside a `{{ variable }}` placeholder.
function M.collapse_outside_braces(text)
    local masked, saved = mask_braces(text or '')
    masked = util_str.trim((masked:gsub('%s+', ' ')))
    return unmask_braces(masked, saved)
end

--- Collapse consecutive whitespace in a URL (`%20` and `{{ }}` are left alone).
function M.normalize_url(url)
    return M.collapse_outside_braces(url)
end

--- Lines of the request-line section.
--- `section` holds the original rows (request line plus URL continuation rows).
--- `cfg.explode_query`: 'keep' preserves multi-line URLs, 'inline' joins them,
--- 'explode' puts every `&` query pair on its own line.
function M.request_line(req, section, cfg)
    cfg = cfg or {}
    local method = req.method and util_str.trim(req.method):upper() or 'GET'
    local url = M.normalize_url(req.url or '')
    local version = req.http_version and util_str.trim(req.http_version) or ''
    local rows = section or {}
    local mode = cfg.explode_query or 'keep'

    if #rows > 1 and mode == 'keep' then
        local fragment = M.normalize_url(util_str.trim(rows[1]):gsub('^%u+%s+', ''))
        if fragment ~= '' and url:sub(1, #fragment) == fragment then
            local out = { method .. ' ' .. fragment }
            for index = 2, #rows do
                local leading = rows[index]:match('^[ \t]*') or ''
                out[#out + 1] = leading .. M.normalize_url(util_str.trim(rows[index]))
            end
            -- the HTTP version, if any, stays on the row the user wrote it on
            return out
        end
    end

    local suffix = version ~= '' and (' ' .. version) or ''
    if mode == 'explode' then
        local head, query = url:match('^([^?]*%?[^&]*)&(.+)$')
        if head then
            local out = { method .. ' ' .. head .. suffix }
            for pair in query:gmatch('[^&]+') do
                out[#out + 1] = '&' .. pair
            end
            return out
        end
    end
    return { method .. ' ' .. url .. suffix }
end

--- `Name: Value` lines, header case preserved; multi-line values indent by 2 spaces.
function M.header_lines(req, cfg)
    cfg = cfg or {}
    local headers = {}
    for index, header in ipairs(req.headers or {}) do
        headers[index] = header
    end
    if cfg.sort_headers then
        table.sort(headers, function(a, b)
            local name_a = (a.name or ''):lower()
            local name_b = (b.name or ''):lower()
            if name_a == name_b then
                return (a.value or '') < (b.value or '')
            end
            return name_a < name_b
        end)
    end

    local out = {}
    for _, header in ipairs(headers) do
        local name = util_str.trim(header.name or '')
        local value_lines = util_str.lines(util_str.trim(header.value or ''))
        if #value_lines == 0 then
            value_lines = { '' }
        end
        local first = util_str.trim(value_lines[1])
        out[#out + 1] = first ~= '' and (name .. ': ' .. first) or (name .. ':')
        for index = 2, #value_lines do
            out[#out + 1] = '  ' .. util_str.trim(value_lines[index])
        end
    end
    return out
end

--- `a=1` / `&b=2`: one urlencoded pair per line with `&` prefixes.
function M.urlencoded_lines(text)
    local flat = (text or ''):gsub('[\r\n]+', '')
    local out = {}
    for pair in flat:gmatch('[^&]+') do
        local trimmed = util_str.trim(pair)
        if trimmed ~= '' then
            out[#out + 1] = #out == 0 and trimmed or ('&' .. trimmed)
        end
    end
    if #out == 0 then
        return nil
    end
    return out
end

--- `?? status == 200`, whitespace collapsed, prefix kept.
function M.assertion_line(assertion)
    local text = util_str.trim((assertion or {}).raw or '')
    if text:sub(1, 2) ~= '??' then
        text = '?? ' .. text
    end
    return util_str.trim((text:gsub('%s+', ' ')))
end

--- Body rows from the original buffer, falling back to `body.text`.
local function body_source(req, lines)
    local range = req.body and req.body.range
    if range and type(range.start_row) == 'number' and type(range.end_row) == 'number' then
        local rows = {}
        for row = range.start_row + 1, range.end_row do
            if row >= 1 and row <= #lines then
                rows[#rows + 1] = lines[row]
            end
        end
        if #rows > 0 then
            return rows
        end
    end
    return util_str.lines((req.body and req.body.text) or '')
end

--- Pretty-print a JSON body with jq, else with the built-in printer.
--- Returns nil (keep the fragment verbatim) when the external tool fails.
local function format_json(text, cfg, diagnostics, row)
    if util_str.is_blank(text) then
        return nil
    end
    if cfg.json ~= 'internal' and tools.available().jq then
        local output, err = tools.jq(text, { indent = cfg.indent })
        if output then
            local lines = util_str.lines(output)
            if #lines > 0 then
                return lines
            end
            err = 'empty output'
        end
        diagnostics[#diagnostics + 1] = {
            row = type(row) == 'number' and row or 0,
            col = 0,
            severity = 'warning',
            message = 'jq failed, JSON body kept verbatim: ' .. tostring(err),
            code = 'format.json',
        }
        log.debug('format.request: jq failed (%s)', tostring(err))
        return nil
    end
    local pretty = json_internal.pretty(text, cfg.indent)
    if pretty ~= text then
        return util_str.lines(pretty)
    end
    return nil
end

--- Number of source rows the body occupies: the parsed range, widened to the text length
--- so a re-format of already expanded JSON still consumes all of its rows.
function M.body_span(req)
    local range = req.body and req.body.range
    local span = 0
    if range and type(range.start_row) == 'number' and type(range.end_row) == 'number' then
        span = range.end_row - range.start_row
    end
    local text_rows = #util_str.lines((req.body and req.body.text) or '')
    if text_rows > span then
        span = text_rows
    end
    if span < 1 then
        span = 1
    end
    return span
end

--- Body lines for a request: JSON/urlencoded are rebuilt, everything else is verbatim.
function M.body_lines(req, lines, cfg, diagnostics)
    cfg = cfg or {}
    diagnostics = diagnostics or {}
    local body = req.body
    local kind = (body and body.kind) or 'raw'
    local rows = body_source(req, lines)
    local text = table.concat(rows, '\n')

    local formatted
    if kind == 'json' then
        formatted = format_json(text, cfg, diagnostics, body and body.range and body.range.start_row)
    elseif kind == 'urlencoded' then
        formatted = M.urlencoded_lines(text)
    end

    local out = formatted or rows
    -- trailing blank rows are re-created by the formatter's block spacing rules
    while #out > 0 and util_str.is_blank(out[#out]) do
        out[#out] = nil
    end
    return out
end

return M
