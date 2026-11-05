-- Formatting entry points. The buffer is rebuilt from the parsed structure instead of
-- being patched with regexes: separators, request lines, headers and bodies are re-emitted
-- from ParseResult, comments and unknown rows are copied verbatim, and JSON/JS fragments are
-- delegated to external tools with a fail-soft fallback (DESIGN 9.2-9.4).
local M = {}

local config = require('rikuesto.config')
local request = require('rikuesto.format.request')
local js_block = require('rikuesto.format.js_block')
local util_str = require('rikuesto.util.str')
local log = require('rikuesto.util.log')

--- `@name = value` / `@name := value` declaration.
local VAR_DECL = '^([ \t]*)(@[%w_%-%.]+)%s*(:?=)[ \t]*(.*)$'
--- Script fence opening line: `< {% ...` (pre-request) or `> {% ...` (response handler).
local FENCE_OPEN = '^([ \t]*)([<>])[ \t]*{%%(.*)$'
--- `> ./handler.js`: an external response script, which needs a blank line before it.
local HANDLER_LINE = '^[ \t]*>[ \t]*[^%s{]'

local function format_cfg()
    local cfg = config.get()
    return (cfg and cfg.format) or {}
end

local function display_width(text)
    local ok, width = pcall(vim.fn.strdisplaywidth, text)
    if ok and type(width) == 'number' then
        return width
    end
    return #text
end

local function is_comment(line)
    return line:match('^%s*#') ~= nil or line:match('^%s*//') ~= nil or line:match('^%s*/%*') ~= nil
end

--- 0-based row from ParseResult to a 1-based row into `lines`.
local function to_row(row0)
    if type(row0) ~= 'number' then
        return nil
    end
    return row0 + 1
end

--- Lexically locate script fences so we know which rows belong to the fence, not just
--- the script `source` (the Script contract does not record the closing fence row).
local function scan_scripts(lines)
    local regions = {}
    local row = 1
    while row <= #lines do
        local indent, mark, rest = lines[row]:match(FENCE_OPEN)
        if not indent then
            row = row + 1
        else
            local code = {}
            local close_row
            -- code that starts on the fence line itself is shifted by the fence delimiter,
            -- so drop its indentation; continuation lines keep theirs (JS is whitespace sensitive)
            local inline_start = not util_str.is_blank(rest)
            local first_close = rest:find('%}', 1, true)
            if first_close then
                code[1] = util_str.rtrim(rest:sub(1, first_close - 1))
                close_row = row
            else
                code[1] = util_str.rtrim(rest)
                local probe = row + 1
                while probe <= #lines do
                    local index = lines[probe]:find('%}', 1, true)
                    if index then
                        code[#code + 1] = util_str.rtrim(lines[probe]:sub(1, index - 1))
                        close_row = probe
                        break
                    end
                    code[#code + 1] = lines[probe]
                    probe = probe + 1
                end
            end
            if close_row then
                while #code > 0 and util_str.is_blank(code[#code]) do
                    code[#code] = nil
                end
                while #code > 0 and util_str.is_blank(code[1]) do
                    table.remove(code, 1)
                end
                if inline_start and #code > 0 then
                    code[1] = util_str.ltrim(code[1])
                end
                regions[#regions + 1] = {
                    open_row = row,
                    close_row = close_row,
                    indent = indent,
                    kind = mark == '<' and 'pre' or 'post',
                    code = code,
                }
                row = close_row + 1
            else
                row = row + 1
            end
        end
    end
    return regions
end

--- Row -> what to emit for it. Rows without a plan are copied verbatim.
local function build_plans(lines, result)
    local total = #lines
    local plan = {}
    local requests = (result and result.requests) or {}

    local separators = {}
    for row = 1, total do
        if lines[row]:match('^%s*###') then
            separators[#separators + 1] = row
        end
    end

    local regions = scan_scripts(lines)

    -- Separator titles come from the separator line itself, normalised to `### <title>`. Deriving
    -- them from `requests[index]` is wrong: files can carry separator lines that open no request
    -- (`### =====` banners, consecutive `###`), which shifts the pairing and duplicates titles.
    for _, row in ipairs(separators) do
        local rest = (lines[row]:gsub('^%s*###', ''))
        plan[row] = {
            kind = 'separator',
            title = util_str.trim((tostring(rest):gsub('%s+', ' '))),
        }
    end

    for _, req in ipairs(requests) do
        local range = req.range or {}
        local block_first = to_row(range.start_row) or 1
        -- range.end_row is 0-based and exclusive, which is exactly the 1-based last row
        local block_last = tonumber(range.end_row) or total
        local next_separator = total + 1
        for _, separator in ipairs(separators) do
            if separator > block_first and separator < next_separator then
                next_separator = separator
            end
        end
        if block_last >= next_separator then
            block_last = next_separator - 1
        end
        if block_first < 1 then
            block_first = 1
        end
        if block_last > total then
            block_last = total
        end

        local url_row = to_row(req.url_line)
        if not url_row or url_row < block_first or url_row > block_last then
            url_row = block_first
        end

        local header_rows = {}
        for _, header in ipairs(req.headers or {}) do
            local row = to_row(header.row)
            if row and row >= 1 and row <= total then
                header_rows[#header_rows + 1] = row
            end
        end
        table.sort(header_rows)

        local body_first = req.body and req.body.range and to_row(req.body.range.start_row) or nil
        if body_first and (body_first < url_row or body_first > total) then
            body_first = nil
        end

        -- structural rows of this block, used to delimit the request-line and header sections
        local structural = {}
        for _, row in ipairs(header_rows) do
            structural[#structural + 1] = row
        end
        if body_first then
            structural[#structural + 1] = body_first
        end
        for _, region in ipairs(regions) do
            structural[#structural + 1] = region.open_row
        end
        for _, assertion in ipairs(req.assertions or {}) do
            local row = to_row(assertion.row)
            if row then
                structural[#structural + 1] = row
            end
        end
        table.sort(structural)

        local function first_after(floor)
            for _, row in ipairs(structural) do
                if row > floor then
                    return row
                end
            end
            return block_last + 1
        end

        local section_end = first_after(url_row)
        plan[url_row] = { kind = 'request', req = req, url_row = url_row, row_end = section_end }
        for row = url_row + 1, section_end - 1 do
            plan[row] = { kind = 'skip' } -- URL continuation rows are re-emitted by request_line
        end

        if header_rows[1] and header_rows[1] > url_row then
            plan[header_rows[1]] = { kind = 'headers', req = req }
            for index = 2, #header_rows do
                plan[header_rows[index]] = { kind = 'skip' }
            end
            local zone_end = first_after(header_rows[#header_rows])
            for row = header_rows[1] + 1, zone_end - 1 do
                -- header continuation rows (and the blank line before the body) are
                -- regenerated from the header values; comments keep their own row
                if not is_comment(lines[row]) and not lines[row]:match(VAR_DECL) then
                    plan[row] = { kind = 'skip' }
                end
            end
        end

        if body_first then
            plan[body_first] = { kind = 'body', req = req }
            local body_last = body_first + request.body_span(req) - 1
            if body_last > total then
                body_last = total
            end
            for row = body_first + 1, body_last do
                plan[row] = { kind = 'skip' }
            end
        end

        for _, assertion in ipairs(req.assertions or {}) do
            local row = to_row(assertion.row)
            if row and row >= 1 and row <= total then
                plan[row] = { kind = 'assertion', assertion = assertion }
            end
        end
    end

    for row = 1, total do
        if plan[row] == nil and lines[row]:match(HANDLER_LINE) then
            plan[row] = { kind = 'handler' }
        end
    end

    for _, region in ipairs(regions) do
        if plan[region.open_row] == nil then
            plan[region.open_row] = { kind = 'script', region = region }
            for row = region.open_row + 1, region.close_row do
                plan[row] = { kind = 'skip' }
            end
        end
    end

    return plan
end

local function emit(lines, plan, cfg, diagnostics)
    local out = {}

    local function push(line)
        out[#out + 1] = line
    end

    local function strip_trailing_blanks()
        while #out > 0 and out[#out] == '' do
            out[#out] = nil
        end
    end

    local function push_blank()
        if #out == 0 or out[#out] == '' then
            return
        end
        push('')
    end

    --- Exactly one blank line between the previous content and the next structural element.
    local function separate()
        strip_trailing_blanks()
        if #out > 0 then
            push('')
        end
    end

    --- Emit a contiguous run of `@var = value` rows with their `=` aligned.
    local function emit_var_group(start_row)
        local entries = {}
        local row = start_row
        while row <= #lines and plan[row] == nil do
            local leading, name, operator, value = lines[row]:match(VAR_DECL)
            if not leading then
                break
            end
            entries[#entries + 1] = {
                leading = leading,
                name = name,
                operator = operator,
                value = util_str.trim(value),
            }
            row = row + 1
        end

        local widths = {}
        local max_width = 0
        for index, entry in ipairs(entries) do
            widths[index] = display_width(entry.leading .. entry.name)
            if widths[index] > max_width then
                max_width = widths[index]
            end
        end
        for index, entry in ipairs(entries) do
            local padding = 1
            if cfg.align_variables ~= false then
                padding = max_width - widths[index] + 1
            end
            local suffix = entry.value ~= '' and (' ' .. entry.value) or ''
            push(entry.leading .. entry.name .. string.rep(' ', padding) .. entry.operator .. suffix)
        end
        return row
    end

    local function emit_script(region)
        local inner
        if cfg.js ~= 'none' then
            local formatted, err = js_block.format(table.concat(region.code, '\n'), {
                indent = region.indent .. string.rep(' ', cfg.indent or 2),
            })
            if formatted then
                inner = util_str.lines(formatted)
            else
                diagnostics[#diagnostics + 1] = {
                    row = region.open_row - 1,
                    col = 0,
                    severity = 'warning',
                    message = 'oxfmt failed, script kept verbatim: ' .. tostring(err),
                    code = 'format.js',
                }
            end
        end
        if not inner then
            inner = region.code
        end
        if region.kind == 'post' then
            separate() -- `> {%` must be preceded by a blank line to parse as a handler
        end
        push(region.indent .. (region.kind == 'pre' and '< {%' or '> {%'))
        for _, line in ipairs(inner) do
            push(line)
        end
        push(region.indent .. '%}')
    end

    local row = 1
    while row <= #lines do
        local entry = plan[row]
        local kind = entry and entry.kind
        if kind == 'separator' then
            separate()
            push(entry.title ~= '' and ('### ' .. entry.title) or '###')
            row = row + 1
        elseif kind == 'request' then
            local section = {}
            for index = entry.url_row, entry.row_end - 1 do
                section[#section + 1] = lines[index]
            end
            while #section > 0 and util_str.is_blank(section[#section]) do
                section[#section] = nil
            end
            for _, line in ipairs(request.request_line(entry.req, section, cfg)) do
                push(line)
            end
            row = row + 1
        elseif kind == 'headers' then
            for _, line in ipairs(request.header_lines(entry.req, cfg)) do
                push(line)
            end
            row = row + 1
        elseif kind == 'body' then
            local body_lines = request.body_lines(entry.req, lines, cfg, diagnostics)
            separate()
            for _, line in ipairs(body_lines) do
                push(line)
            end
            row = row + 1
        elseif kind == 'script' then
            emit_script(entry.region)
            row = entry.region.close_row + 1
        elseif kind == 'handler' then
            separate()
            push(util_str.rtrim(lines[row]))
            row = row + 1
        elseif kind == 'assertion' then
            separate()
            push(request.assertion_line(entry.assertion))
            row = row + 1
        elseif kind == 'skip' then
            row = row + 1
        elseif util_str.is_blank(lines[row]) then
            push_blank()
            row = row + 1
        elseif lines[row]:match(VAR_DECL) then
            row = emit_var_group(row)
        else
            push(lines[row]) -- comments, `> ./file.js`, any row we do not own
            row = row + 1
        end
    end

    strip_trailing_blanks()
    return out
end

--- Format `lines` according to `result` (a ParseResult, possibly nil).
--- Returns { lines = string[], changed = bool, diagnostics = Diagnostic[] }.
function M.format_lines(lines, result)
    local cfg = format_cfg()
    local diagnostics = {}

    local source = {}
    for index, line in ipairs(lines or {}) do
        source[index] = (tostring(line):gsub('\r$', ''))
    end
    if #source == 0 then
        return { lines = {}, changed = false, diagnostics = diagnostics }
    end

    local plan = build_plans(source, result)
    local formatted = emit(source, plan, cfg, diagnostics)
    return {
        lines = formatted,
        changed = not vim.deep_equal(source, formatted),
        diagnostics = diagnostics,
    }
end

--- Parse a buffer when the parse module is available, so this module never blocks on it.
local function parse_buffer(lines)
    local ok, block = pcall(require, 'rikuesto.parse.block')
    if not ok or type(block) ~= 'table' or type(block.parse) ~= 'function' then
        return nil
    end
    local parsed, result = pcall(block.parse, lines)
    if not parsed then
        log.debug('format: parse failed (%s)', tostring(result))
        return nil
    end
    return result
end

--- Format a buffer in place with a single `nvim_buf_set_lines` call (one undo block).
--- Line contents are stored without EOL bytes, so `fileformat` still decides how the
--- buffer is written (dos -> CRLF) - nothing here needs to restore it.
function M.format_buffer(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false, false
    end
    local read, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
    if not read then
        return false, false
    end

    local formatted = M.format_lines(lines, parse_buffer(lines))
    for _, diagnostic in ipairs(formatted.diagnostics) do
        log.debug('format: %s', diagnostic.message)
    end
    if not formatted.changed then
        return true, false
    end

    local written = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, formatted.lines)
    if not written then
        return false, false
    end
    return true, true
end

return M
