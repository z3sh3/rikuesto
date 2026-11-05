-- JS fence body formatter. A fence fragment (`< {% return x %}`) is not a complete module,
-- so it is wrapped in `(async function(){ ... })`, run through oxfmt, then unwrapped and
-- re-indented. When both attempts fail the caller keeps the source verbatim (DESIGN 9.3.5).
local M = {}

local tools = require('rikuesto.format.tools')
local util_str = require('rikuesto.util.str')
local log = require('rikuesto.util.log')

local WRAPPER_OPEN = '(async function(){'
local WRAPPER_CLOSE = '})'

local function leading_whitespace(line)
    return line:match('^[ \t]*') or ''
end

--- Width of the common leading indentation of `lines` (blank lines ignored).
local function common_indent(lines)
    local smallest
    for _, line in ipairs(lines) do
        if not util_str.is_blank(line) then
            local width = #leading_whitespace(line)
            if smallest == nil or width < smallest then
                smallest = width
            end
        end
    end
    return smallest or 0
end

local function strip_indent(line, width)
    local removed = 0
    local index = 1
    while index <= #line and removed < width do
        local ch = line:sub(index, index)
        if ch ~= ' ' and ch ~= '\t' then
            break
        end
        removed = removed + 1
        index = index + 1
    end
    return line:sub(index)
end

local function drop_trailing_blank(lines)
    while #lines > 0 and util_str.is_blank(lines[#lines]) do
        lines[#lines] = nil
    end
    return lines
end

--- Remove the `(async function(){` / `})` wrapper oxfmt produced around our fragment.
local function unwrap(output)
    local lines = util_str.lines(output)
    if #lines < 3 then
        return nil
    end
    local first = util_str.trim(lines[1])
    local last = util_str.trim(lines[#lines])
    if not first:match('^%(async function') then
        return nil
    end
    if not last:match('^%}%)+;?$') then
        return nil
    end
    local inner = {}
    for index = 2, #lines - 1 do
        inner[#inner + 1] = lines[index]
    end
    return drop_trailing_blank(inner)
end

--- Prefix every non-blank line with `indent` after removing the fragment's own base indent.
local function reindent(lines, indent)
    local base = common_indent(lines)
    local out = {}
    for index, line in ipairs(lines) do
        if util_str.is_blank(line) then
            out[index] = ''
        else
            out[index] = indent .. strip_indent(line, base)
        end
    end
    return out
end

--- Format the inside of a script fence.
--- opts.indent: string prefix applied to every emitted line.
--- Returns the formatted source (no fence lines), or `nil, err`.
function M.format(source, opts)
    opts = opts or {}
    local indent = opts.indent or ''
    local filetype = opts.filetype or 'javascript'
    if type(source) ~= 'string' or util_str.is_blank(source) then
        return nil, 'empty script'
    end

    local lines = drop_trailing_blank(util_str.lines(source))
    if #lines == 0 then
        return nil, 'empty script'
    end
    local base = common_indent(lines)
    local dedented = {}
    for index, line in ipairs(lines) do
        dedented[index] = util_str.is_blank(line) and '' or strip_indent(line, base)
    end

    local payload = table.concat(dedented, '\n')
    local attempts = {
        { text = WRAPPER_OPEN .. '\n' .. payload .. '\n' .. WRAPPER_CLOSE, wrapped = true },
        { text = payload, wrapped = false },
    }

    local last_err
    for _, attempt in ipairs(attempts) do
        local output, err = tools.oxfmt(attempt.text, filetype)
        if output then
            local inner = attempt.wrapped and unwrap(output) or drop_trailing_blank(util_str.lines(output))
            if inner and #inner > 0 then
                return table.concat(reindent(inner, indent), '\n')
            end
        end
        last_err = err or last_err
    end

    log.debug('format.js_block: oxfmt failed (%s)', tostring(last_err))
    return nil, last_err or 'oxfmt failed'
end

return M
