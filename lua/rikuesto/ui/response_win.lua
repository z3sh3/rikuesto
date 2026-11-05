-- Rendered response viewer (status line + headers + pretty body) in a scratch buffer.
local M = {}

local config = require('rikuesto.config')
local state = require('rikuesto.state')

local win = nil
local buf = nil

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
    parts[#parts + 1] = ('%s %s'):format(ctx.request.method or 'GET', response.url_effective or ctx.request.url or '')
  end
  return table.concat(parts, '  ·  ')
end

local function body_lines(response)
  local body = response.body or ''
  local json_internal = require('rikuesto.format.json_internal')
  local pretty = json_internal.pretty(body, config.get().format.indent or 2)
  return vim.split(pretty ~= '' and pretty or '', '\n', { plain = true })
end

local function release()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  buf = nil
end

local function ensure_window()
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'rikuesto-response'
  end
  local layout = config.get().ui.response.layout
  if layout == 'float' then
    local width = math.max(40, math.floor(vim.o.columns * 0.8))
    local height = math.max(10, math.floor(vim.o.lines * 0.7))
    win = vim.api.nvim_open_win(buf, false, {
      relative = 'editor',
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = 'minimal',
      border = 'rounded',
      title = ' rikuesto ',
    })
  else
    local size = math.max(8, math.floor(vim.o.lines * (config.get().ui.response.size or 0.4)))
    vim.cmd(layout == 'botright' and ('botright sbuffer ' .. buf) or ('sbuffer ' .. buf))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(win, size)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].wrap = false
  end
  vim.wo[win].cursorline = false
  vim.wo[win].conceallevel = 0
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', {
    noremap = true,
    silent = true,
    callback = function()
      M.close()
    end,
  })
  return win
end

--- Render a response into the response buffer.
function M.open(response, ctx)
  ctx = ctx or {}
  local error = response.error
  local lines = {}
  if error then
    lines[#lines + 1] = ('FAILED  %s  %s'):format(error.kind or 'error', error.message or '')
  end
  lines[#lines + 1] = reason_line(response, ctx)
  lines[#lines + 1] = ''
  lines[#lines + 1] = ('--- headers (%d) ---'):format(#(response.headers or {}))
  for _, header in ipairs(response.headers or {}) do
    lines[#lines + 1] = ('%s: %s'):format(header.name, header.value)
  end
  local body = body_lines(response)
  lines[#lines + 1] = ''
  lines[#lines + 1] = ('--- body%s ---'):format(response.truncated and ' (truncated)' or '')
  for _, line in ipairs(body) do
    lines[#lines + 1] = line
  end

  if response.script_tests and #response.script_tests > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '--- script tests ---'
    for _, test in ipairs(response.script_tests) do
      lines[#lines + 1] = ('%s  %s%s'):format(test.pass and '[pass]' or '[FAIL]', test.name or '?',
        test.message and ('  ' .. test.message) or '')
    end
  end
  if response.assertions and #response.assertions > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '--- assertions ---'
    for _, assertion in ipairs(response.assertions) do
      lines[#lines + 1] = ('%s  %s'):format(assertion.pass and '[pass]' or '[FAIL]', assertion.raw or '')
    end
  end
  if response.script_errors and #response.script_errors > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '--- script errors ---'
    for _, script_error in ipairs(response.script_errors) do
      lines[#lines + 1] = tostring(script_error.message or script_error)
    end
  end

  local target = ensure_window()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = (response.json and 'json' or 'rikuesto-response')
  return target
end

function M.close()
  release()
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Show the last response again (used by :Rikuesto response last).
function M.reopen()
  local last = state.last
  if not last or not last.response then
    return false
  end
  M.open(last.response, { request = last.request })
  return true
end

function M.reset()
  win, buf = nil, nil
end

return M
