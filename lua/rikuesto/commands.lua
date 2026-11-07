-- `:Rikuesto` command surface. Everything user visible lives here.
local M = {}

local config = require('rikuesto.config')
local exec = require('rikuesto.exec')
local log = require('rikuesto.util.log')
local notify = require('rikuesto.util.notify')
local state = require('rikuesto.state')

local SUBCOMMANDS = {
  'run', 'run all', 'cancel', 'repeat', 'curl', 'copy', 'format', 'list',
  'env', 'vars', 'log', 'js', 'response', 'help',
}

local function cursor_row()
  return vim.api.nvim_win_get_cursor(0)[1] - 1
end

local function current_context()
  local result, request = exec.context(0, cursor_row())
  if not request then
    notify.warn('no request under the cursor')
    return nil, nil
  end
  return result, request
end

local function run_one(request, result)
  notify.info(('running %s %s'):format(request.method, request.url or ''))
  exec.run_request(request, result, 0, { async = true })
end

local function cmd_curl(opts)
  local result, request = current_context()
  if not request then
    return
  end
  local spec = exec.prepare(request, result, 0)
  local exporter = require('rikuesto.http.exporter')
  local dialect = opts.args or config.get().curl_export.dialect or 'native'
  local command = exporter.to_string(spec.argv, dialect)
  if config.get().curl_export.mask_secrets then
    command = require('rikuesto.util.str').mask(command, config.get().mask_patterns)
  end
  if opts.bang then
    local register = config.get().curl_export.register or '+'
    vim.fn.setreg(register, command)
    notify.info(('curl command copied to register %s'):format(register))
  else
    vim.api.nvim_echo(vim.split(command, '\n', { plain = true }), false, {})
  end
end

local function cmd_env(opts)
  local env_api = require('rikuesto.env.api')
  local action = opts.args or ''
  if action == '' then
    local items = {}
    for _, name in ipairs(env_api.list()) do
      items[#items + 1] = (name == env_api.active()) and (name .. '  (active)') or name
    end
    if #items == 0 then
      notify.warn(('no profiles found in %s'):format(env_api.path() or '(unset)'))
      return
    end
    vim.ui.select(items, { prompt = 'rikuesto env' }, function(choice)
      if not choice then
        return
      end
      local name = choice:gsub('%s+%(active%)$', '')
      local ok, err = env_api.switch(name)
      if ok then
        notify.info(('env profile: %s'):format(name))
      else
        notify.error(('env switch failed: %s'):format(tostring(err)))
      end
    end)
  elseif action == 'list' then
    notify.info(('profiles: %s (active: %s)'):format(table.concat(env_api.list(), ', '),
      tostring(env_api.active())))
  elseif action == 'reload' then
    env_api.reload()
    notify.info('env reloaded')
  elseif action == 'check' then
    local ok, err = pcall(env_api.reload)
    if ok then
      local count = 0
      for _ in pairs(env_api.variables()) do
        count = count + 1
      end
      notify.info(('env ok: %s (%d variables, profile %s)'):format(env_api.path() or '?', count,
        tostring(env_api.active())))
    else
      notify.error(('env error: %s'):format(tostring(err)))
    end
  elseif action == 'edit' then
    local path = env_api.path()
    if not path then
      notify.error('env path not configured')
      return
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  elseif action:match('^set%s+(.+)$') then
    local name = action:match('^set%s+(.+)$')
    local ok, err = env_api.switch(name)
    if ok then
      notify.info(('env profile: %s'):format(name))
    else
      notify.error(('env switch failed: %s'):format(tostring(err)))
    end
  else
    notify.error('usage: :Rikuesto env [list|reload|check|edit|set <profile>]')
  end
end

local function cmd_vars()
  local result, request = current_context()
  if not request then
    return
  end
  local scope = exec.scope(result, request)
  local lines = { '# resolved variables', '' }
  local names = {}
  local function collect(source, tag)
    for name, value in pairs(source or {}) do
      names[#names + 1] = { name = name, value = value, tag = tag }
    end
  end
  collect(scope.env, 'env')
  collect(scope.file, 'file')
  collect(scope.block, 'block')
  table.sort(names, function(a, b)
    return a.name < b.name
  end)
  if #names == 0 then
    return
  end
  local mask_patterns = config.get().mask_patterns
  local str = require('rikuesto.util.str')
  for _, entry in ipairs(names) do
    local value = tostring(entry.value)
    for _, pattern in ipairs(mask_patterns) do
      if entry.name:lower():find(pattern, 1, true) then
        value = '***'
        break
      end
    end
    lines[#lines + 1] = ('%-24s %-8s %s'):format(entry.name, entry.tag, str.short(value, 80))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.cmd('botright sbuffer ' .. buf)
end

local function cmd_response(action)
  local win = require('rikuesto.ui.response_win')
  if action == 'close' then
    win.close()
  elseif action == 'last' then
    if not win.reopen() then
      notify.warn('no response yet')
    end
  else
    if not win.reopen() then
      notify.warn('no response yet')
    end
  end
end

local handlers = {}

-- `dispatch()` hands every handler the parsed command opts table, so `run` must read
-- `opts.args`; taking a bare string here made `:Rikuesto run` fall into the named-request branch.
handlers.run = function(opts)
  local args = (opts and opts.args) or ''
  if args == 'all' then
    notify.info('running all requests…')
    exec.run_all(0, { quiet = false })
    return
  end
  if args ~= '' then
    local result = exec.context(0, 0)
    for _, request in ipairs(result.requests) do
      if request.name == args then
        run_one(request, result)
        return
      end
    end
    notify.warn(('named request not found: %s'):format(args))
    return
  end
  local result, request = current_context()
  if request then
    run_one(request, result)
  end
end

function handlers.cancel()
  if state.job and state.job.cancel then
    state.job:cancel()
    notify.info('request cancelled')
  else
    notify.warn('nothing to cancel')
  end
end

-- `repeat` is a Lua keyword, so it must be assigned rather than declared with function syntax.
handlers['repeat'] = function()
  local last = state.last
  if not last or not last.request then
    notify.warn('no previous request')
    return
  end
  local result = exec.context(last.bufnr and vim.api.nvim_buf_is_valid(last.bufnr) and last.bufnr or 0, 0)
  run_one(last.request, result)
end

function handlers.curl(opts)
  cmd_curl(opts)
end

function handlers.copy(opts)
  opts.bang = true
  cmd_curl(opts)
end

function handlers.format()
  local ok, changed = require('rikuesto.format.formatter').format_buffer(0)
  if not ok then
    notify.error('format failed')
  elseif changed then
    notify.info('formatted')
  else
    notify.info('already formatted')
  end
end

function handlers.list()
  local result = exec.context(0, 0)
  require('rikuesto.ui.picker').list(result.requests, function(request)
    vim.api.nvim_win_set_cursor(0, { (request.url_line or 0) + 1, 0 })
    run_one(request, result)
  end)
end

function handlers.env(opts)
  cmd_env(opts)
end

function handlers.vars()
  cmd_vars()
end

function handlers.log(opts)
  if opts.args == 'clear' then
    log.clear()
    notify.info('log cleared')
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(log.dump(), '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { '(log is empty)' })
  vim.bo[buf].filetype = 'log'
  vim.cmd('botright sbuffer ' .. buf)
end

function handlers.js(opts)
  local runtime = require('rikuesto.js.runtime')
  local cfg = config.get()
  if opts.args ~= '' then
    cfg.js.runtime = opts.args
  end
  local info = runtime.describe()
  notify.info(('js runtime: %s%s'):format(tostring(info.runtime or 'none'),
    info.version and (' (' .. info.version .. ')') or ''))
end

function handlers.response(opts)
  cmd_response(opts.args)
end

function handlers.help()
  local lines = {
    ':Rikuesto run            run the request under the cursor',
    ':Rikuesto run all        run every request in the buffer',
    ':Rikuesto run <name>     run a request by its # @name',
    ':Rikuesto cancel         cancel the in-flight request',
    ':Rikuesto repeat         run the previous request again',
    ':Rikuesto curl [dialect] print the curl command (native|pwsh|sh|cmd)',
    ':Rikuesto curl!          copy the curl command to the export register',
    ':Rikuesto copy           alias of :Rikuesto curl!',
    ':Rikuesto format         format the buffer',
    ':Rikuesto list           pick a request from a list',
    ':Rikuesto env [...]      list|reload|check|edit|set <profile>',
    ':Rikuesto vars           show resolved variables for the cursor request',
    ':Rikuesto log [clear]    open the log buffer',
    ':Rikuesto js [runtime]   show or set the JS runtime (auto|node|deno|none)',
    ':Rikuesto response [open|close|last]',
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'markdown'
  vim.cmd('botright sbuffer ' .. buf)
end

--- Entry point for `:Rikuesto`.
function M.dispatch(opts)
  local args = opts.args or ''
  local head, rest = args:match('^(%S*)%s*(.*)$')
  head = (head or ''):lower()

  if head == '' then
    handlers.help()
    return
  end
  if head == 'copy' then
    opts.bang = true
    return handlers.copy({ args = rest, bang = true })
  end

  local handler = handlers[head]
  if not handler then
    notify.error(('unknown subcommand: %s (try :Rikuesto help)'):format(head))
    return
  end
  local sub = vim.deepcopy(opts)
  sub.args = rest
  return handler(sub)
end

function M.complete(arg_lead)
  local out = {}
  for _, name in ipairs(SUBCOMMANDS) do
    if name:sub(1, #arg_lead) == arg_lead then
      out[#out + 1] = name
    end
  end
  return out
end

function M.register()
  if vim.fn.exists(':Rikuesto') == 2 then
    return
  end
  vim.api.nvim_create_user_command('Rikuesto', function(opts)
    M.dispatch(opts)
  end, {
    nargs = '*',
    bang = true,
    complete = function(arg_lead)
      return M.complete(arg_lead)
    end,
    desc = 'rikuesto HTTP client',
  })
end

return M
