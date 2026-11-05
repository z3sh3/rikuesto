-- `# @key [value]` metadata comments (docs/DESIGN.md §5.7).
local M = {}

local str = require('rikuesto.util.str')

-- Keys that applied directly to `Request.meta` (or `preamble.meta`) by `apply()`.
-- `name` / `ref` are handled by the caller because they live on the Request itself.
M.known = {
    ['name'] = true,
    ['ref'] = true,
    ['no-redirect'] = true,
    ['no-cookie-jar'] = true,
    insecure = true,
    timeout = true,
    proxy = true,
    lang = true,
}

local PATTERN = '^%s*[#/]+%s*@([%w%-_%.]+)%s*(.*)$'

--- Empty metadata table; both request and preamble start from this shape.
function M.empty()
    return {
        no_redirect = false,
        no_cookie_jar = false,
        insecure = false,
        timeout_ms = nil,
        proxy = nil,
        lang = nil,
        raw = {},
    }
end

--- Parse one metadata comment line.
--- Returns { key = 'name', value = 'login' | nil } or nil.
function M.parse_line(line)
    if type(line) ~= 'string' then
        return nil
    end
    local key, value = line:match(PATTERN)
    if not key then
        return nil
    end
    value = str.trim(value)
    return { key = key:lower(), value = value ~= '' and value or nil }
end

--- Apply one parsed entry to `meta` in place.
--- Returns handled, diagnostic:
---   handled    = false -> unknown key, the caller keeps it in `meta.raw`
---   diagnostic = Diagnostic|nil (already resolved against the parsed entry)
function M.apply(meta, entry, row)
    local key, value = entry.key, entry.value
    if key == 'no-redirect' then
        meta.no_redirect = true
    elseif key == 'no-cookie-jar' then
        meta.no_cookie_jar = true
    elseif key == 'insecure' then
        meta.insecure = true
    elseif key == 'timeout' then
        local ms = tonumber(value)
        if not ms then
            return true, {
                row = row,
                col = 0,
                severity = 'warning',
                message = ('@timeout expects milliseconds, got %q'):format(tostring(value)),
                code = 'parse.invalid_timeout',
            }
        end
        meta.timeout_ms = math.floor(ms)
    elseif key == 'proxy' then
        meta.proxy = value
    elseif key == 'lang' then
        meta.lang = value and value:lower() or nil
    else
        return false
    end
    return true
end

--- Copy the entries of `source` that are set into `target` (used to fold a
--- request-less chunk's metadata into `preamble.meta`).
function M.merge(target, source)
    for _, field in ipairs({ 'no_redirect', 'no_cookie_jar', 'insecure', 'timeout_ms', 'proxy', 'lang' }) do
        if source[field] ~= nil and source[field] ~= false then
            target[field] = source[field]
        end
    end
    for key, value in pairs(source.raw or {}) do
        target.raw[key] = value
    end
    return target
end

return M
