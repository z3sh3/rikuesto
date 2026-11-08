-- Integration test: real requests against the API used by test.http (network required).
-- Run explicitly:  nvim --headless -l tests/integration/run_http.lua
-- Optional:        RIKUESTO_TEST_PROXY=http://localhost:7897
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h:h')

package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  root .. '/?.lua',
  package.path,
}, ';')
vim.opt.runtimepath:append(root)

local config = require('rikuesto.config')
config.setup({
  log = { level = 'error', keep = 2000 },
  ui = { response = { open = 'never' }, extmark = { enabled = false } },
  curl = { proxy = (vim.env.RIKUESTO_TEST_PROXY and vim.env.RIKUESTO_TEST_PROXY ~= '')
      and vim.env.RIKUESTO_TEST_PROXY or nil },
})

local exec = require('rikuesto.exec')
local block = require('rikuesto.parse.block')
local exporter = require('rikuesto.http.exporter')

-- Expected outcome per request, in file order. `status` may be a list (server-dependent).
local EXPECT = {
  { method = 'GET', url = '/posts', status = 200, body = 'json_array' },
  { method = 'GET', url = '/posts?userId=1', status = 200, body = 'json_array' },
  { method = 'GET', url = '/posts/1', status = 200, body = 'json_object' },
  { method = 'GET', url = '/posts/1/comments', status = 200, body = 'json_array' },
  { method = 'GET', url = '/albums/1/photos', status = 200, body = 'json_array' },
  { method = 'GET', url = '/todos?userId=1', status = 200, body = 'json_array' },
  { method = 'POST', url = '/posts', status = 201, body = 'json_object' },
  { method = 'POST', url = '/users', status = 201, body = 'json_object' },
  { method = 'PUT', url = '/posts/1', status = 200, body = 'json_object' },
  { method = 'PUT', url = '/todos/1', status = 200, body = 'json_object' },
  { method = 'PATCH', url = '/posts/1', status = 200, body = 'json_object' },
  { method = 'PATCH', url = '/comments/1', status = 200, body = 'json_object' },
  { method = 'DELETE', url = '/posts/1', status = 200, body = 'any' },
  { method = 'DELETE', url = '/albums/1', status = 200, body = 'any' },
  { method = 'HEAD', url = '/posts/1', status = 200, body = 'empty' },
  { method = 'OPTIONS', url = '/posts', status = { 200, 204 }, body = 'any' },
  { method = 'GET', url = '/posts/999', status = 404, body = 'any' },
  { method = 'POST', url = '/invalid-resource', status = 404, body = 'any' },
}

local function status_ok(response, expected)
  if type(expected) == 'table' then
    for _, code in ipairs(expected) do
      if response.status == code then
        return true
      end
    end
    return false
  end
  return response.status == expected
end

local function body_kind_ok(response, kind)
  if kind == 'any' then
    return true
  end
  if kind == 'empty' then
    return (response.body or '') == ''
  end
  if kind == 'json_array' then
    return type(response.json) == 'table' and (response.json[1] ~= nil or next(response.json) == nil)
  end
  if kind == 'json_object' then
    return type(response.json) == 'table'
  end
  return true
end

local path = root .. '/test.http'
local lines = vim.fn.readfile(path)
if #lines == 0 then
  print('FAILED: cannot read ' .. path)
  os.exit(1)
end

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.bo[bufnr].filetype = 'http'

local parsed = block.parse(lines)
print(('test.http: %d lines -> %d requests, %d diagnostics'):format(#lines, #parsed.requests,
  #(parsed.diagnostics or {})))
for _, diagnostic in ipairs(parsed.diagnostics or {}) do
  print(('  diagnostic [%s] row %d: %s'):format(diagnostic.severity or '?', (diagnostic.row or 0) + 1,
    diagnostic.message or ''))
end
print(('file variables: %s'):format(vim.inspect(parsed.file_variables)))

local failures = {}
local report = {}
local function fail(index, message)
  failures[#failures + 1] = ('#%02d %s'):format(index, message)
end

if #parsed.requests ~= #EXPECT then
  fail(0, ('request count %d does not match expectation %d'):format(#parsed.requests, #EXPECT))
end

local started = vim.uv.hrtime()
for index, request in ipairs(parsed.requests) do
  local expected = EXPECT[index]
  local response, spec = exec.run_request(request, parsed, bufnr, { async = false, quiet = true })
  local resolved_url = (spec and spec.meta and spec.meta.request and spec.meta.request.url) or request.url
  local label = ('#%02d %-7s %s'):format(index, request.method, resolved_url)
  local elapsed_ms = response and response.duration_ms or 0
  local size = response and response.size or 0

  if not response then
    fail(index, 'no response (timeout waiting for the callback)')
  else
    local problems = {}
    if expected then
      if expected.method ~= request.method then
        problems[#problems + 1] = ('method %s != %s'):format(request.method, expected.method)
      end
      if not status_ok(response, expected.status) then
        problems[#problems + 1] = ('status %s, expected %s'):format(tostring(response.status),
          vim.inspect(expected.status))
      end
      if not body_kind_ok(response, expected.body) then
        problems[#problems + 1] = ('body kind %s not satisfied'):format(expected.body)
      end
    end
    if resolved_url:find('{{', 1, true) then
      problems[#problems + 1] = 'unresolved {{ }} left in the resolved url'
    end
    if not resolved_url:find('jsonplaceholder%.typicode%.com', 1) then
      problems[#problems + 1] = 'file variable @base was not substituted'
    end
    if response.error then
      problems[#problems + 1] = ('transport error %s: %s'):format(response.error.kind or '?',
        response.error.message or '')
    end
    if not response.duration_ms or response.duration_ms <= 0 then
      problems[#problems + 1] = 'no timing metadata'
    end

    print(('%s %s  -> %s %s  %6.0fms  %6dB'):format(#problems == 0 and 'PASS' or 'FAIL', label,
      tostring(response.status), (response.reason or ''):sub(1, 12), elapsed_ms, size))
    for _, problem in ipairs(problems) do
      fail(index, problem)
    end
    report[#report + 1] = {
      index = index,
      method = request.method,
      url = resolved_url,
      status = response.status,
      duration_ms = elapsed_ms,
      size = size,
      problems = problems,
    }
  end
end

-- Copy as curl must produce a usable, resolved, executable command for the first request.
do
  local first = parsed.requests[1]
  local spec = exec.prepare(first, parsed, bufnr)
  local argv, notes = exporter.export_argv(spec)
  local dialect = exporter.resolve_dialect(nil)
  local command = exporter.to_string(argv, dialect)
  print('')
  print(('curl export (%s) for #01:'):format(dialect))
  print('  ' .. command)
  for _, note in ipairs(notes) do
    print('  note: ' .. note)
  end
  if command:find('{{', 1, true) then
    fail(0, 'exported curl still contains unresolved variables')
  end
  if not command:find('jsonplaceholder%.typicode%.com') then
    fail(0, 'exported curl is missing the resolved base url')
  end
  for _, forbidden in ipairs({ 'headers.txt', 'body.bin', 'writeout.json', '%{json}', '-sS' }) do
    if command:find(forbidden, 1, true) then
      fail(0, ('exported curl keeps the response-capture plumbing: %s'):format(forbidden))
    end
  end
end

local total_ms = (vim.uv.hrtime() - started) / 1e6
print('')
print(('TOTAL: %d requests in %.0fms, %d failure(s)'):format(#parsed.requests, total_ms, #failures))
for _, failure in ipairs(failures) do
  print('  x ' .. failure)
end

-- Durable report for reviewers.
do
  local out = { '# Integration run: test.http', '' }
  out[#out + 1] = ('- nvim %s, curl %s'):format(vim.version().major .. '.' .. vim.version().minor,
    require('rikuesto.util.platform').tool_version({ config.get().tools.curl
        or require('rikuesto.util.platform').resolve_tool('curl'), '--version' }) or '?')
  out[#out + 1] = ('- %d requests, %d failure(s), %.0fms total'):format(#parsed.requests, #failures, total_ms)
  out[#out + 1] = ''
  out[#out + 1] = '| # | method | url | status | time (ms) | size (B) | verdict |'
  out[#out + 1] = '|---|---|---|---|---|---|---|'
  for _, row in ipairs(report) do
    out[#out + 1] = ('| %d | %s | `%s` | %s | %.0f | %d | %s |'):format(row.index, row.method, row.url,
      tostring(row.status), row.duration_ms, row.size, #row.problems == 0 and 'PASS' or ('FAIL: ' .. table.concat(row.problems, '; ')))
  end
  if #failures > 0 then
    out[#out + 1] = ''
    out[#out + 1] = '## Failures'
    for _, failure in ipairs(failures) do
      out[#out + 1] = '- ' .. failure
    end
  end
  local report_path = root .. '/docs/reports/integration.md'
  vim.fn.mkdir(root .. '/docs/reports', 'p')
  vim.fn.writefile(out, report_path)
  print('report written: docs/reports/integration.md')
end

os.exit(#failures == 0 and 0 or 1)
