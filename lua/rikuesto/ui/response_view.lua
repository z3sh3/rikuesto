-- Response views: `header`, `body`, `script` and `all` (DESIGN §11.2).
--
-- Pure rendering: nothing here touches a window or a buffer, so `tests/response_view_spec.lua`
-- can assert the content of every view without opening anything. `ui/response_win.lua` owns the
-- window, the buffer and the buffer-local keys that switch between these views.
local config = require('rikuesto.config')

local M = {}

--- The order is both the reading order and the J/K navigation order.
M.ORDER = { 'header', 'body', 'script', 'all' }
M.DEFAULT = 'all'

--- @param view string|nil e.g. 'header', 'H', 'all'
--- @return string|nil canonical view name, nil when unknown
function M.normalize(view)
    if type(view) ~= 'string' or view == '' then
        return nil
    end
    local lowered = string.lower(view)
    for _, name in ipairs(M.ORDER) do
        if lowered == name or lowered == name:sub(1, 1) then
            return name
        end
    end
    return nil
end

--- Configured default view (`ui.response.view`), falling back to `all`.
function M.configured()
    return M.normalize(config.get().ui.response.view) or M.DEFAULT
end

local function index_of(view)
    for index, name in ipairs(M.ORDER) do
        if name == view then
            return index
        end
    end
    return nil
end

--- Adjacent view, wrapping around (`all` + 1 -> `header`).
--- @param view string|nil current view
--- @param delta number|nil default 1 (J); -1 walks backwards (K)
function M.step(view, delta)
    local index = index_of(M.normalize(view) or M.DEFAULT) or #M.ORDER
    index = (index - 1 + (delta or 1)) % #M.ORDER + 1
    return M.ORDER[index]
end

local function reason_line(response, ctx)
    local http_version = response.http_version or '1.1'
    local status = response.status or 0
    local reason = response.reason or ''
    local parts = { ('HTTP/%s %d %s'):format(http_version, status, reason) }
    if response.duration_ms then
        parts[#parts + 1] = ('%d ms'):format(math.floor(response.duration_ms + 0.5))
    end
    if response.size then
        parts[#parts + 1] = ('%d B'):format(response.size)
    end
    if response.redirects and response.redirects > 0 then
        parts[#parts + 1] = ('%d redirect(s)'):format(response.redirects)
    end
    if ctx and ctx.request then
        parts[#parts + 1] = ('%s %s'):format(ctx.request.method or 'GET',
            response.url_effective or ctx.request.url or '')
    end
    return table.concat(parts, '  ·  ')
end

--- A transport error is context for every view: without it `header`/`body` merely look empty.
local function error_lines(response, into)
    local error = response.error
    if not error then
        return into
    end
    local label = (error.kind == 'cancelled') and 'CANCELLED' or 'FAILED'
    into[#into + 1] = ('%s  %s  %s'):format(label, error.kind or 'error', error.message or '')
    return into
end

local function header_lines(response, into)
    local headers = response.headers or {}
    into[#into + 1] = ('--- headers (%d) ---'):format(#headers)
    for _, header in ipairs(headers) do
        into[#into + 1] = ('%s: %s'):format(header.name, header.value)
    end
    return into
end

--- `with_title` is false for the dedicated `body` view: when the body is the only thing on
--- screen its title is pure noise. `all` keeps it, because there it separates body from headers.
local function body_lines(response, into, with_title)
    if with_title then
        into[#into + 1] = ('--- body%s ---'):format(response.truncated and ' (truncated)' or '')
    elseif response.truncated then
        into[#into + 1] = '(truncated)'
    end
    local body = response.body or ''
    local pretty = require('rikuesto.format.json_internal').pretty(body, config.get().format.indent or 2)
    for _, line in ipairs(vim.split(pretty or '', '\n', { plain = true })) do
        into[#into + 1] = line
    end
    return into
end

local function assertion_lines(response, into)
    local assertions = response.assertions or {}
    if #assertions == 0 then
        return into
    end
    into[#into + 1] = ''
    into[#into + 1] = '--- assertions ---'
    for _, assertion in ipairs(assertions) do
        into[#into + 1] = ('%s  %s'):format(assertion.pass and '[pass]' or '[FAIL]', assertion.raw or '')
    end
    return into
end

--- Everything the JS scripts produced: `console.log` output, `client.test` results and errors.
local function script_lines(response, into)
    local logs = response.script_logs or {}
    local tests = response.script_tests or {}
    local errors = response.script_errors or {}
    into[#into + 1] = ('--- script output (%d) ---'):format(#logs)
    if #logs == 0 then
        into[#into + 1] = '(no output)'
    end
    for _, line in ipairs(logs) do
        into[#into + 1] = tostring(line)
    end
    if #tests > 0 then
        into[#into + 1] = ''
        into[#into + 1] = '--- script tests ---'
        for _, test in ipairs(tests) do
            into[#into + 1] = ('%s  %s%s'):format(test.pass and '[pass]' or '[FAIL]', test.name or '?',
                test.message and ('  ' .. test.message) or '')
        end
    end
    if #errors > 0 then
        into[#into + 1] = ''
        into[#into + 1] = '--- script errors ---'
        for _, script_error in ipairs(errors) do
            into[#into + 1] = tostring(script_error.message or script_error)
        end
    end
    return into
end

--- Render one view. `all` is the response without any script output, by definition.
--- @return string[] lines
function M.lines(response, ctx, view)
    response = response or {}
    view = M.normalize(view) or M.DEFAULT
    local lines = error_lines(response, {})
    if view == 'header' then
        lines[#lines + 1] = reason_line(response, ctx)
        lines[#lines + 1] = ''
        return header_lines(response, lines)
    end
    if view == 'body' then
        return body_lines(response, lines, false)
    end
    if view == 'script' then
        return script_lines(response, lines)
    end
    lines[#lines + 1] = reason_line(response, ctx)
    lines[#lines + 1] = ''
    header_lines(response, lines)
    lines[#lines + 1] = ''
    body_lines(response, lines, true)
    return assertion_lines(response, lines)
end

return M
