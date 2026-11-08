-- Renders an argv for "copy as curl" (DESIGN §7.6). `to_string` never masks — the user
-- asked for their own request back. `command_line` is the log form and masks secrets
-- (DESIGN §7.5, `cfg.mask_patterns`).
-- `export_argv` turns the run argv into a command a human can paste back into a shell:
-- no temp-file plumbing, no file references, every value inlined.
local platform = require('rikuesto.util.platform')
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

-- Characters that never need quoting in each dialect. Everything else is quoted: an
-- unquoted `{`, `,`, `$`, `&`, `|`, `*`, `?` or backtick is either a syntax error or a
-- silently changed value. `"` and `^` are excluded everywhere because quoting them is
-- the only way to keep them literal; `%` is excluded for cmd, where `%NAME%` expands even
-- inside double quotes.
local SAFE_CHARS = {
    sh = '-._/:@%%+,=',
    pwsh = '-._/:%%+,=',
    cmd = '-._/:@+,=',
}

local function needs_quote(arg, dialect)
    if arg == '' then
        return true
    end
    local safe = SAFE_CHARS[dialect]
    if not safe then
        return true
    end
    local charset = '[%w' .. safe:gsub('([%%%]%-%^%]])', '%%%1') .. ']'
    return arg:find('^' .. charset .. '+$') == nil
end

--- The plugin runs the resolved binary path, but a pasted command should start with the
--- command word a shell can look up (that is what every other HTTP client exports).
--- `curl.EXE` → `curl.exe` on Windows, `curl` elsewhere; an override that is not named
--- curl keeps its full path.
local function command_word(bin)
    local text = tostr(bin)
    local name = text:gsub('\\', '/'):match('([^/]+)$') or text
    if name:lower():match('^curl%.[%w]+$') then
        name = 'curl.' .. name:match('%.([%w]+)$'):lower()
        return name
    end
    if name:lower() == 'curl' then
        return name
    end
    return text
end

--- `auto` means "the shell this platform ships", because a copy that cannot be pasted back
--- and executed is not a copy.
local AUTO_DIALECT = platform.is_windows and 'pwsh' or 'sh'

--- Silence is only useful for the plugin, which reads its own response files. `to_string`
--- must not leave `-sS` in a copied command: a human pasting it wants the error output.
local SILENT_FLAGS = { ['-sS'] = true, ['--no-progress-meter'] = true }
--- Response-capture flags write files (`-D`/`-o`) or replace the response with plugin
--- metadata (`-w '%{json}'`). Dropped only when the value is the one `curl.build`
--- generated, so a user-supplied `curl.extra_args` is still exported verbatim.
local CAPTURE_FLAGS = { ['-D'] = 'path', ['--dump-header'] = 'path', ['-o'] = 'path', ['--output'] = 'path',
    ['-w'] = 'json', ['--write-out'] = 'json' }

--- Dialect actually used for a copy; `auto`/nil/'' resolve to the platform shell.
--- Unknown names pass through and `to_string` falls back to the native listing.
function M.resolve_dialect(name)
    if type(name) ~= 'string' or name == '' or name == 'auto' then
        return AUTO_DIALECT
    end
    return name
end

--- `native`: one argument per line, no quoting — the only form that survives every
--- body/header byte unchanged. It is not executable; pick it only as a reference listing.
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
        local text = tostr(arg)
        if needs_quote(text, dialect) then
            -- PowerShell treats a quoted word as a string expression, not as a command:
            -- `'C:\path\curl.exe' --version` is a ParserError. `&` is the call operator.
            if dialect == 'pwsh' and index == 1 then
                out[#out + 1] = '&'
            end
            out[#out + 1] = quote(text)
        else
            out[#out + 1] = text
        end
    end
    return table.concat(out, ' ')
end

local function read_text_file(path)
    if type(path) ~= 'string' or path == '' then
        return nil
    end
    return platform.read_file(path)
end

--- Converting the run argv into a pasteable command (DESIGN §7.6).
--- Drops the response-capture plumbing, inlines every payload (temp file or `< ./body`
--- file reference) as literal `--data-raw` text, and reports anything that cannot be
--- reproduced byte-exactly as a note for the caller to surface.
--- @param spec table result of `curl.build`
--- @return string[] argv, string[] notes
function M.export_argv(spec)
    spec = spec or {}
    local argv = spec.argv or {}
    local notes = {}
    local by_path = {}
    for _, file in ipairs(spec.temp_files or {}) do
        if type(file.path) == 'string' then
            by_path[file.path] = file
        end
    end
    local out = {}
    local index = 1
    local function push(value)
        -- argv[1] is the resolved binary path; the copy gets a command word instead.
        if #out == 0 then
            out[1] = command_word(value)
            return
        end
        out[#out + 1] = tostr(value)
    end
    while index <= #argv do
        local arg = tostr(argv[index])
        local value = argv[index + 1] and tostr(argv[index + 1]) or nil
        local capture = CAPTURE_FLAGS[arg]
        if SILENT_FLAGS[arg] then
            index = index + 1
        elseif capture == 'json' and value == '%{json}' then
            index = index + 2
        elseif capture == 'path' and value and by_path[value] then
            index = index + 2
        elseif (arg == '--data-binary' or arg == '-d' or arg == '--data' or arg == '--data-ascii')
            and value and value:sub(1, 1) == '@' then
            local path = value:sub(2)
            local stored = by_path[path]
            local text = stored and stored.text or read_text_file(path)
            if text == nil then
                -- Nothing to inline: keep the command honest instead of inventing a body.
                notes[#notes + 1] = ('body file could not be read, request body omitted: %s'):format(path)
            elseif text:find('\0', 1, true) then
                notes[#notes + 1] = ('body file contains NUL bytes; inlined body is not byte-exact: %s')
                    :format(path)
                push('--data-raw')
                push((text:gsub('%z', '')))
            else
                push('--data-raw')
                push(text)
                if stored == nil then
                    notes[#notes + 1] = ('body inlined from file: %s'):format(path)
                end
            end
            index = index + 2
        else
            if arg == '-F' or arg == '--form' then
                if value and value:find('=@', 1, true) then
                    notes[#notes + 1] = ('form field still uploads a file: %s'):format(value)
                end
            end
            push(arg)
            index = index + 1
        end
    end
    return out, notes
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
