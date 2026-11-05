-- Renders an argv for "copy as curl" (DESIGN §7.6). `to_string` never masks — the user
-- asked for their own request back. `command_line` is the log form and masks secrets
-- (DESIGN §7.5, `cfg.mask_patterns`).
local str = require('rikuesto.util.str')

local M = {}

local CREDENTIAL_FLAGS = { ['-u'] = true, ['--user'] = true, ['--proxy-user'] = true }

local function tostr(value)
    if type(value) == 'string' then
        return value
    end
    return tostring(value)
end

local function mask_patterns()
    local ok, cfg = pcall(function()
        return require('rikuesto.config').get()
    end)
    if ok and type(cfg) == 'table' and type(cfg.mask_patterns) == 'table' then
        return cfg.mask_patterns
    end
    return {}
end

local function matches_pattern(name, patterns)
    local lowered = string.lower(name)
    for _, pattern in ipairs(patterns) do
        if lowered:find(string.lower(pattern), 1, true) then
            return true
        end
    end
    return false
end

--- util/str.mask only matches lower-case header names, so header arguments are matched
--- case-insensitively here before handing the rest to it.
local function mask_argument(text, patterns)
    local name, value = text:match('^([%w%-_]+):%s*(.*)$')
    if name and value ~= '' and matches_pattern(name, patterns) then
        return name .. ': ***'
    end
    return str.mask(text, patterns)
end

local function quote_sh(arg)
    return "'" .. (arg:gsub("'", "'\\''")) .. "'"
end

local function quote_pwsh(arg)
    return "'" .. (arg:gsub("'", "''")) .. "'"
end

local function quote_cmd(arg)
    return '"' .. (arg:gsub('%^', '^^'):gsub('"', '\\"')) .. '"'
end

local QUOTERS = { sh = quote_sh, pwsh = quote_pwsh, cmd = quote_cmd }

--- `native`: one argument per line, no quoting — the only form that survives every
--- body/header byte unchanged, so it is the default dialect.
local function native(argv)
    local out = {}
    for index, arg in ipairs(argv) do
        out[index] = tostr(arg)
    end
    return table.concat(out, '\n')
end

function M.to_string(argv, dialect)
    local args = argv or {}
    local quote = QUOTERS[dialect or 'native']
    if not quote then
        return native(args)
    end
    local out = {}
    for index, arg in ipairs(args) do
        out[index] = quote(tostr(arg))
    end
    return table.concat(out, ' ')
end

--- Single-line form for logs. Each argument is masked on its own so that one secret
--- cannot swallow the rest of the line (URL included).
function M.command_line(argv)
    local patterns = mask_patterns()
    local out = {}
    local previous = nil
    for index, arg in ipairs(argv or {}) do
        local text = tostr(arg)
        if CREDENTIAL_FLAGS[previous] then
            text = '***'
        elseif #patterns > 0 then
            text = mask_argument(text, patterns)
        end
        out[index] = text
        previous = tostr(arg)
    end
    return table.concat(out, ' ')
end

return M
