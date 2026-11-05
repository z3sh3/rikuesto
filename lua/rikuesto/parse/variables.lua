-- `@name = value` / `@name := value` declarations (file level and request level).
local M = {}

-- Name charset follows http-files.org: word characters plus `-` and `.`.
local PATTERN = '^@([%w_%-%.]+)%s*(:?=)%s*(.*)$'

--- Parse one declaration line.
--- Returns { name = 'x', value = 'v', lazy = false } or nil when the line is not
--- a declaration. `lazy` is true for `:=`, i.e. "evaluate when used".
function M.parse_line(line)
    if type(line) ~= 'string' then
        return nil
    end
    local text = line:gsub('^%s+', '')
    local name, operator, value = text:match(PATTERN)
    if not name then
        return nil
    end
    return {
        name = name,
        value = (value:gsub('%s+$', '')),
        lazy = operator == ':=',
    }
end

return M
