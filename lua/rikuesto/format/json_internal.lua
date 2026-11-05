-- Order-preserving JSON pretty printer (fallback when `jq` is absent, DESIGN appendix C).
-- It re-indents whitespace only: string contents and number literals are copied byte for
-- byte, so `1.0` stays `1.0`, big integers never become doubles and `\u` escapes are kept.
local M = {}

--- `indent` is a number of spaces or a literal string; default 2 spaces.
local function indent_unit(indent)
    if type(indent) == 'number' then
        return string.rep(' ', math.max(0, indent))
    end
    if type(indent) == 'string' and indent ~= '' then
        return indent
    end
    return '  '
end

--- First non-whitespace character, or nil for blank input.
local function first_significant(text)
    return text:match('^%s*(.)')
end

--- Pretty-print `text` keeping key order and every literal untouched.
--- Returns `text` unchanged when it is not a balanced object/array.
function M.pretty(text, indent)
    if type(text) ~= 'string' or text == '' then
        return text
    end
    local head = first_significant(text)
    if head ~= '{' and head ~= '[' then
        return text -- scalars and non-JSON payloads are never rewritten
    end

    local unit = indent_unit(indent)
    local out = {}
    local stack = {} -- each entry = { closer = '}'|']', multiline = boolean }
    local in_string = false
    local escaped = false
    local trailing = false -- non-whitespace after the outermost closer
    local index = 1
    local length = #text

    local function emit(piece)
        out[#out + 1] = piece
    end

    local function break_line()
        emit('\n')
        local depth = #stack
        if depth > 0 then
            emit(string.rep(unit, depth))
        end
    end

    while index <= length do
        local ch = text:sub(index, index)
        if in_string then
            emit(ch)
            if escaped then
                escaped = false
            elseif ch == '\\' then
                escaped = true
            elseif ch == '"' then
                in_string = false
            end
            index = index + 1
        elseif ch == '"' then
            in_string = true
            emit(ch)
            index = index + 1
        elseif ch == '{' or ch == '[' then
            local closer = (ch == '{') and '}' or ']'
            local lookahead = index + 1
            while lookahead <= length and text:sub(lookahead, lookahead):match('^%s$') do
                lookahead = lookahead + 1
            end
            local multiline = text:sub(lookahead, lookahead) ~= closer
            emit(ch)
            stack[#stack + 1] = { closer = closer, multiline = multiline }
            if multiline then
                break_line()
            end
            index = index + 1
        elseif ch == '}' or ch == ']' then
            local top = stack[#stack]
            if not top or top.closer ~= ch then
                return text -- mismatched nesting: leave the payload alone
            end
            stack[#stack] = nil
            if top.multiline then
                break_line()
            end
            emit(ch)
            index = index + 1
        elseif ch == ',' then
            emit(ch)
            if #stack > 0 then
                break_line()
            end
            index = index + 1
        elseif ch == ':' then
            emit(': ')
            index = index + 1
        elseif ch:match('^%s$') then
            index = index + 1 -- all whitespace outside strings is re-generated
        else
            if #stack == 0 then
                trailing = true -- e.g. `{"a":1}x`: not a single JSON value
            end
            emit(ch)
            index = index + 1
        end
    end

    if in_string or escaped or #stack > 0 or trailing then
        return text
    end
    return table.concat(out)
end

return M
