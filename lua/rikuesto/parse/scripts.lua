-- Script handlers: `< {% ... %}` (pre-request) and `> {% ... %}` (response),
-- plus the external forms `< ./file` and `> ./file` (docs/DESIGN.md §5.6).
local M = {}

local str = require('rikuesto.util.str')

local DEFAULT_LANG = 'javascript'

--- Classify a handler line without parsing it.
--- Returns shape ('fence'|'file'), post (bool) or nil when the line is not a handler.
function M.classify(line)
    if type(line) ~= 'string' then
        return nil
    end
    local marker, rest = line:match('^%s*([<>])%s*(.-)%s*$')
    if not marker then
        return nil
    end
    local post = marker == '>'
    if rest:find('{%', 1, true) == 1 then
        return 'fence', post
    end
    -- `> ./handler.js`: a single path token, never SQL/XML noise such as `> 5`
    if rest ~= '' and not rest:find('%s') then
        return 'file', post
    end
    return nil
end

--- Parse a `{% ... %}` fence whose opening `{%` is at 1-based index `open_col`
--- of `lines[row + 1]`. `source` keeps the original indentation so the JS can be
--- executed verbatim; `offset` is where that source starts in the buffer.
local function parse_block(lines, row, open_col, post)
    local line = lines[row + 1]
    local tail = line:sub(open_col + 2) -- text after `{%`
    local lead = #(tail:match('^%s*') or '')
    local body = {}
    local first_row, first_col

    local close = tail:find('%}', 1, true)
    if close then
        first_row, first_col = row, open_col + 1 + lead
        body[1] = str.trim(tail:sub(1, close - 1))
        return {
            lang = DEFAULT_LANG,
            source = table.concat(body, '\n'),
            file = nil,
            post = post,
            offset = { row = first_row, col = first_col },
        }, row + 1
    end

    if str.is_blank(tail) then
        first_row, first_col = row + 1, 0
    else
        body[#body + 1] = tail
        first_row, first_col = row, open_col + 1 + lead
    end

    local r = row + 1
    while r < #lines do
        local text = lines[r + 1]
        local pos = text:find('%}', 1, true)
        if pos then
            local head = text:sub(1, pos - 1)
            if not str.is_blank(head) then
                body[#body + 1] = head
            end
            return {
                lang = DEFAULT_LANG,
                source = table.concat(body, '\n'),
                file = nil,
                post = post,
                offset = { row = first_row, col = first_col },
            }, r + 1
        end
        body[#body + 1] = text
        r = r + 1
    end

    -- Unterminated fence: consume the rest of the buffer, the caller reports it.
    return nil, #lines
end

--- Parse the script handler starting at `row` (0-based index into `lines`).
--- Returns Script|nil, next_row where next_row is the first row after the handler.
function M.parse_fence(lines, row)
    if type(lines) ~= 'table' or type(row) ~= 'number' then
        return nil, row
    end
    local line = lines[row + 1]
    if type(line) ~= 'string' then
        return nil, row + 1
    end
    local _, rest = line:match('^%s*([<>])%s*(.-)%s*$')
    local shape, post = M.classify(line)
    if not shape then
        return nil, row + 1
    end

    if shape == 'fence' then
        local open_col = line:find('{%', 1, true)
        return parse_block(lines, row, open_col, post)
    end

    local path_col = line:find(rest, 1, true)
    return {
        lang = DEFAULT_LANG,
        source = '',
        file = rest,
        post = post,
        offset = { row = row, col = path_col - 1 },
    }, row + 1
end

return M
