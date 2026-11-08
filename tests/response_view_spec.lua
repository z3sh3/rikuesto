-- Response views: the four blocks the response buffer can show and the order J/K walk.
-- Pure assertions (no window is opened, the builder never touches a buffer).
local t = require('tests.helper')
local config = require('rikuesto.config')
local view = require('rikuesto.ui.response_view')

local function response(overrides)
    local resp = {
        status = 200,
        reason = 'OK',
        http_version = '1.1',
        duration_ms = 123,
        size = 45,
        headers = { { name = 'Content-Type', value = 'application/json' } },
        body = '{"a":1}',
        json = { a = 1 },
        script_logs = { 'hello from js' },
        script_tests = { { name = 'status is 200', pass = true } },
        script_errors = { { message = 'boom' } },
        assertions = { { raw = 'status == 200', pass = true } },
    }
    for key, value in pairs(overrides or {}) do
        resp[key] = value
    end
    return resp
end

local ctx = { request = { method = 'GET', url = 'https://api.example.com/x' } }

local function joined(lines)
    return table.concat(lines, '\n')
end

t.module('ui.response_view')

-- View names: canonical, single letter, case-insensitive; anything else is rejected.
do
    t.eq(view.normalize('header'), 'header', 'canonical name')
    t.eq(view.normalize('H'), 'header', 'H is the header view')
    t.eq(view.normalize('b'), 'body', 'lowercase b is the body view')
    t.eq(view.normalize('Script'), 'script', 'names are case-insensitive')
    t.eq(view.normalize('all'), 'all', 'all is a view')
    t.eq(view.normalize('nope'), nil, 'unknown view is rejected')
    t.eq(view.normalize(''), nil, 'empty view is rejected')
    t.eq(view.normalize(nil), nil, 'nil view is rejected')
    t.eq(view.normalize('s'), 'script', 's resolves to script, not to a prefix clash')
    t.same(view.ORDER, { 'header', 'body', 'script', 'all' }, 'reading order is H, B, S, A')
    t.eq(view.DEFAULT, 'all', 'default view is all')
end

-- J/K walk the H -> B -> S -> A order and wrap around at both ends.
do
    t.eq(view.step('header'), 'body', 'J from header goes to body')
    t.eq(view.step('body'), 'script', 'J from body goes to script')
    t.eq(view.step('script'), 'all', 'J from script goes to all')
    t.eq(view.step('all'), 'header', 'J wraps from all back to header')
    t.eq(view.step('all', -1), 'script', 'K from all goes to script')
    t.eq(view.step('header', -1), 'all', 'K wraps from header to all')
    t.eq(view.step(nil), 'header', 'an unknown current view behaves like the default (all)')
end

-- The configured default comes from ui.response.view, with `all` as the fallback.
do
    t.eq(view.configured(), 'all', 'default configuration shows all')
    config.setup({ ui = { response = { view = 'body' } } })
    t.eq(view.configured(), 'body', 'ui.response.view seeds the first view')
    config.setup({ ui = { response = { view = 'nonsense' } } })
    t.eq(view.configured(), 'all', 'an unknown configured view falls back to all')
    config.setup({})
end

-- header: status line + headers, and no body.
do
    local text = joined(view.lines(response(), ctx, 'header'))
    t.eq(text:find('HTTP/1.1 200 OK', 1, true) ~= nil, true, 'header view keeps the status line')
    t.eq(text:find('--- headers (1) ---', 1, true) ~= nil, true, 'header view lists the headers')
    t.eq(text:find('Content-Type: application/json', 1, true) ~= nil, true, 'header view shows every header')
    t.eq(text:find('--- body', 1, true), nil, 'header view has no body block')
    t.eq(text:find('hello from js', 1, true), nil, 'header view has no script output')
end

-- body: the pretty body only, with no section title (the body is the whole view).
do
    local text = joined(view.lines(response(), ctx, 'body'))
    t.eq(text:find('--- body', 1, true), nil, 'body view has no `--- body ---` title')
    t.eq(text:find('"a": 1', 1, true) ~= nil, true, 'body view pretty-prints JSON')
    t.eq(text:sub(1, 1), '{', 'body view starts with the body itself')
    t.eq(text:find('--- headers', 1, true), nil, 'body view has no headers')
    t.eq(text:find('hello from js', 1, true), nil, 'body view has no script output')
    local truncated = joined(view.lines(response({ truncated = true }), ctx, 'body'))
    t.eq(truncated:sub(1, #'(truncated)'), '(truncated)', 'a truncated body view still says so')
    t.eq(truncated:find('--- body', 1, true), nil, 'the truncation note is not a section title')
end

-- script: console output, client.test results and script errors.
do
    local text = joined(view.lines(response(), ctx, 'script'))
    t.eq(text:find('--- script output (1) ---', 1, true) ~= nil, true, 'script view counts its log lines')
    t.eq(text:find('hello from js', 1, true) ~= nil, true, 'script view shows console output')
    t.eq(text:find('[pass]  status is 200', 1, true) ~= nil, true, 'script view shows client.test results')
    t.eq(text:find('boom', 1, true) ~= nil, true, 'script view shows script errors')
    t.eq(text:find('--- headers', 1, true), nil, 'script view has no headers')
    t.eq(text:find('"a": 1', 1, true), nil, 'script view has no body')

    local quiet = joined(view.lines(response({ script_logs = {}, script_tests = {}, script_errors = {} }), ctx,
        'script'))
    t.eq(quiet:find('--- script output (0) ---', 1, true) ~= nil, true, 'a script-less request still labels the view')
    t.eq(quiet:find('(no output)', 1, true) ~= nil, true, 'a script-less request says so explicitly')
end

-- all: headers + body + assertions, and never any script output.
do
    local text = joined(view.lines(response(), ctx, 'all'))
    t.eq(text:find('--- headers (1) ---', 1, true) ~= nil, true, 'all view includes the headers')
    t.eq(text:find('--- body ---', 1, true) ~= nil, true, 'all view includes the body')
    t.eq(text:find('--- assertions ---', 1, true) ~= nil, true, 'all view includes the assertions')
    t.eq(text:find('status == 200', 1, true) ~= nil, true, 'assertions are rendered')
    t.eq(text:find('--- script', 1, true), nil, 'all view excludes script output')
    t.eq(text:find('hello from js', 1, true), nil, 'all view excludes script logs')
    t.eq(text:find('status is 200', 1, true), nil, 'all view excludes script tests')
    t.eq(text:find('boom', 1, true), nil, 'all view excludes script errors')
    t.eq(text:find('HTTP/1.1 200 OK', 1, true) ~= nil, true, 'all view starts with the status line')
end

-- A transport error must be visible in every view, otherwise the buffer just looks empty.
do
    for _, name in ipairs(view.ORDER) do
        local text = joined(view.lines(response({ error = { kind = 'curl', message = 'connection refused' } }),
            ctx, name))
        t.eq(text:find('FAILED  curl  connection refused', 1, true) ~= nil, true,
            name .. ' view reports the transport error')
    end
    local cancelled = joined(view.lines(response({ error = { kind = 'cancelled', message = 'aborted' } }), ctx, 'all'))
    t.eq(cancelled:find('CANCELLED', 1, true) ~= nil, true, 'a cancelled request is labelled CANCELLED')
end

-- An unknown view renders the default instead of an empty buffer.
do
    local text = joined(view.lines(response(), ctx, 'nonsense'))
    t.eq(text:find('--- headers', 1, true) ~= nil, true, 'unknown view falls back to all')
end

t.finish()
