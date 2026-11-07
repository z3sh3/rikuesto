-- Request orchestration: parse -> resolve -> (pre JS) -> curl -> response -> (post JS).
local M = {}

local config = require('rikuesto.config')
local log = require('rikuesto.util.log')
local state = require('rikuesto.state')
local platform = require('rikuesto.util.platform')
local notify = require('rikuesto.util.notify')

local function deep_copy(value)
  if type(value) ~= 'table' then
    return value
  end
  return vim.deepcopy(value)
end

--- Parse the buffer, returning the ParseResult plus the cursor request.
function M.context(bufnr, row)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local block = require('rikuesto.parse.block')
  local result = block.parse(lines)
  local cursor = require('rikuesto.parse.cursor')
  local request = cursor.request_at(result, row or vim.api.nvim_win_get_cursor(0)[1] - 1)
  return result, request, lines
end

--- Build the variable scope honouring the documented precedence.
function M.scope(result, request)
  local ok_env, env_api = pcall(require, 'rikuesto.env.api')
  local env_vars = {}
  if ok_env then
    local ok, vars = pcall(env_api.variables)
    if ok and type(vars) == 'table' then
      env_vars = vars
    end
  end
  return {
    env = env_vars,
    file = (result and result.file_variables) or {},
    block = (request and request.variables) or {},
    request = {},
    chain = state.named,
    dynamic = true,
    report = function(kind, info)
      log.debug('resolve %s: %s', kind, info and (info.name or '') or '')
    end,
  }
end

--- Resolve url/headers/body of a request; returns a resolved copy (never mutates the input).
function M.resolve_request(request, scope)
  local vars = require('rikuesto.resolve.vars')
  local resolved = deep_copy(request) or {}
  resolved.url = (vars.substitute(request.url or '', scope))
  resolved.headers = {}
  for _, header in ipairs(request.headers or {}) do
    local value = (vars.substitute(header.value or '', scope))
    resolved.headers[#resolved.headers + 1] = { name = header.name, value = value, row = header.row }
  end
  if request.body and request.body.kind ~= 'external' then
    resolved.body = deep_copy(request.body)
    resolved.body.text = (vars.substitute(request.body.text or '', scope))
  end
  resolved.meta = request.meta or {}
  return resolved
end

--- Read a script's source (inline or `> ./file.js`).
function M.script_source(script, bufnr)
  if script.file and script.file ~= '' then
    local base = vim.api.nvim_buf_get_name(bufnr or 0)
    local dir = base ~= '' and vim.fn.fnamemodify(base, ':h') or vim.fn.getcwd()
    local path = script.file
    if not path:match('^%a:[/\\]') and not path:match('^[/\\]') then
      path = platform.joinpath(dir, path)
    end
    local text = platform.read_file(path)
    if not text then
      log.warn('cannot read script file: %s', path)
      return nil
    end
    return text
  end
  return script.source
end

local function js_payload(phase, script, request, scope, response, bufnr)
  local bridge = require('rikuesto.js.bridge')
  local headers = {}
  for _, header in ipairs(request.headers or {}) do
    headers[#headers + 1] = { header.name, header.value }
  end
  local payload = {
    phase = phase,
    script = script,
    meta = {},
    request = {
      method = request.method,
      url = request.url,
      headers = headers,
      body = (request.body and request.body.text) or '',
    },
    vars = {},
    globals = state.globals,
    limits = { timeoutMs = config.get().js.timeout_ms },
  }
  for key, value in pairs(scope.request or {}) do
    payload.vars[key] = value
  end
  if response then
    local response_headers = {}
    for _, header in ipairs(response.headers or {}) do
      response_headers[#response_headers + 1] = { header.name, header.value }
    end
    local source = M.script_source(script, bufnr)
    payload.script = source or script.source
    payload.response = {
      status = response.status,
      headers = response_headers,
      bodyBase64 = bridge.base64_encode(response.body or ''),
      contentType = response.content_type or {},
      durationMs = response.duration_ms,
    }
  else
    payload.script = M.script_source(script, bufnr) or script.source
  end
  return payload
end

--- Execute pre/post JS scripts. Returns aggregated { vars, globals, logs, tests, errors }.
function M.run_scripts(request, scope, response, bufnr)
  local aggregate = { vars = {}, globals = {}, logs = {}, tests = {}, errors = {} }
  local cfg = config.get()
  local phase = response and 'post' or 'pre'
  local scripts = (request.scripts and request.scripts[phase]) or {}
  if #scripts == 0 then
    return aggregate
  end
  if phase == 'post' and not cfg.js.response_handlers then
    return aggregate
  end
  if phase == 'pre' and not cfg.js.pre_request_scripts then
    return aggregate
  end
  local runtime = require('rikuesto.js.runtime')
  if not runtime.available() then
    notify.warn('JS runtime not found (node/deno); scripts were skipped')
    return aggregate
  end
  for _, script in ipairs(scripts) do
    local payload = js_payload(phase, script, request, scope, response, bufnr)
    local result, err = runtime.run(payload, { timeout_ms = cfg.js.timeout_ms })
    if not result then
      aggregate.errors[#aggregate.errors + 1] = { message = tostring(err) }
      log.warn('js %s script failed: %s', phase, tostring(err))
    else
      for key, value in pairs(result.vars or {}) do
        aggregate.vars[key] = value
        if phase == 'pre' then
          scope.request[key] = tostring(value)
        end
      end
      for key, value in pairs(result.globals or {}) do
        aggregate.globals[key] = value
        state.set_global(key, tostring(value))
      end
      for _, line in ipairs(result.logs or {}) do
        aggregate.logs[#aggregate.logs + 1] = line
        log.debug('js log: %s', tostring(line))
      end
      for _, test in ipairs(result.tests or {}) do
        aggregate.tests[#aggregate.tests + 1] = test
      end
      for _, script_error in ipairs(result.errors or {}) do
        aggregate.errors[#aggregate.errors + 1] = script_error
      end
    end
  end
  return aggregate
end

--- Build the curl context from config + request metadata.
function M.curl_context(request)
  local cfg = config.get()
  local meta = (request and request.meta) or {}
  return {
    curl_bin = cfg.tools.curl or platform.resolve_tool('curl') or 'curl',
    follow_redirects = cfg.curl.follow_redirects,
    max_time_ms = meta.timeout_ms or cfg.curl.max_time_ms,
    insecure = cfg.curl.insecure,
    proxy = meta.proxy or cfg.curl.proxy,
    extra_args = cfg.curl.extra_args,
    inline_body_max = cfg.curl.inline_body_max,
    keep_temp_on_error = cfg.curl.keep_temp_on_error,
  }
end

--- Full preparation (no side effects): returns the curl spec + resolved request.
function M.prepare(request, result, bufnr)
  local scope = M.scope(result, request)
  local pre = M.run_scripts(request, scope, nil, bufnr)
  local resolved = M.resolve_request(request, scope)
  local ctx = M.curl_context(request)
  local spec = require('rikuesto.http.curl').build(resolved, ctx)
  spec.meta = spec.meta or {}
  spec.meta.request = resolved
  spec.meta.scripts = pre
  spec.meta.ctx = ctx
  spec.meta.scope = scope
  return spec, resolved
end

--- Minimal `??` assertion evaluation (DESIGN §9.6). Returns a list of results.
function M.eval_assertions(response, assertions)
  local out = {}
  local chain = require('rikuesto.resolve.chain')
  local function compare(left, op, right)
    if op == '==' or op == '=' then
      return tostring(left) == tostring(right)
    elseif op == '!=' then
      return tostring(left) ~= tostring(right)
    end
    local a, b = tonumber(left), tonumber(right)
    if not a or not b then
      if op == 'includes' or op == 'contains' then
        return tostring(left):find(tostring(right), 1, true) ~= nil
      elseif op == 'startsWith' then
        return tostring(left):sub(1, #tostring(right)) == tostring(right)
      elseif op == 'endsWith' then
        return tostring(left):sub(-#tostring(right)) == tostring(right)
      elseif op == 'matches' then
        local ok, found = pcall(string.find, tostring(left), tostring(right))
        return ok and found ~= nil
      elseif op == 'exists' then
        return left ~= nil
      end
      return false
    end
    if op == '>' then
      return a > b
    elseif op == '>=' then
      return a >= b
    elseif op == '<' then
      return a < b
    elseif op == '<=' then
      return a <= b
    end
    return false
  end

  for _, assertion in ipairs(assertions or {}) do
    local raw = (assertion.raw or ''):gsub('^%?%?%s*', '')
    local subject, op, expected = raw:match('^(%S+)%s+([%w_]+)%s+(.+)$')
    local pass, actual = false, nil
    if subject == 'status' then
      actual = response and response.status
      pass = compare(actual, op, expected)
    elseif subject == 'duration' then
      actual = response and response.duration_ms
      pass = compare(actual, op, expected)
    elseif subject == 'header' then
      local name, header_op, header_expected = raw:match('^header%s+(%S+)%s+([%w_]+)%s+(.+)$')
      local value
      for _, header in ipairs((response and response.headers) or {}) do
        if header.name:lower() == (name or ''):lower() then
          value = header.value
          break
        end
      end
      actual = value
      pass = compare(value, header_op or op, header_expected or expected)
    elseif subject == 'body' then
      local path, body_op, body_expected = raw:match('^body%s+(%S+)%s+([%w_]+)%s+(.+)$')
      local value = path and chain.lookup('response.body.' .. path, { response = response })
      actual = value
      pass = compare(value, body_op or op, body_expected or expected)
    end
    out[#out + 1] = { raw = assertion.raw, pass = pass, actual = actual, expected = expected }
  end
  return out
end

--- Run one request. opts.async = false makes it synchronous (used by the integration test).
function M.run_request(request, result, bufnr, opts)
  opts = opts or {}
  -- 0 means "current buffer" for the nvim API, but state/extmark are keyed by real buffer numbers.
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local spec = M.prepare(request, result, bufnr)
  local notifications = {}
  local finished, response_out = false, nil

  state.job = require('rikuesto.http.runner').run(spec, spec.meta.ctx, function(response, err)
    finished = true
    require('rikuesto.keymaps').remove_cancel(bufnr)
    if not response then
      response = { ok = false, status = 0, headers = {}, body = '', error = { kind = 'curl', message = tostring(err) } }
    end
    response_out = response
    local scope = spec.meta.scope
    local post = M.run_scripts(spec.meta.request, scope, response, bufnr)
    response.script_tests = post.tests
    response.script_errors = post.errors
    response.script_logs = post.logs
    response.assertions = M.eval_assertions(response, request.assertions)
    state.record_result(bufnr, request, response)
    state.remember_request(request.name, response)
    if not opts.quiet then
      require('rikuesto.ui.extmark').set_result(bufnr, request, response)
      local cfg = config.get()
      if cfg.ui.response.open ~= 'never' or opts.force_window then
        require('rikuesto.ui.response_win').open(response, {
          request = request,
          method = spec.meta.request.method,
          url = spec.meta.request.url,
        })
      end
      if response.error then
        notifications[#notifications + 1] = ('%s %s -> %s'):format(request.method, response.url_effective or '',
          response.error.message or response.error.kind)
      end
    end
  end)

  -- `<C-c>` cancels the in-flight request; the mapping only exists while it runs, so the plugin
  -- still installs no permanent default shortcuts.
  require('rikuesto.keymaps').install_cancel(bufnr)

  if opts.async == false then
    local guard = 0
    while not finished and guard < (spec.meta.ctx.max_time_ms + 15000) do
      vim.wait(50, function()
        return finished
      end)
      guard = guard + 50
    end
    return response_out, spec
  end
  return nil, spec
end

--- Run every request of a buffer sequentially.
function M.run_all(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or 0
  local result = select(1, M.context(bufnr, 0))
  local index = 0
  local function step()
    index = index + 1
    local request = result.requests[index]
    if not request then
      return
    end
    M.run_request(request, result, bufnr, {
      quiet = opts.quiet,
      force_window = false,
      async = false,
    })
    step()
  end
  step()
  return result
end

return M
