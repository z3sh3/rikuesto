-- Rendered response viewer in a scratch buffer. The buffer carries one of four views
-- (`header` / `body` / `script` / `all`, see `ui/response_view.lua`) and switches between them with
-- buffer-local keys only, so no shortcut leaks into `.http` buffers.
local M = {}

local config = require('rikuesto.config')
local state = require('rikuesto.state')

local win = nil
local buf = nil
--- What is currently rendered: { response = ..., ctx = ..., view = 'all' }.
local current = nil
--- Last view the user selected; survives closing the window so the next response keeps it.
local sticky_view = nil

--- Keys are buffer-local and fixed: they only exist inside the response buffer.
local VIEW_KEYS = { H = 'header', B = 'body', S = 'script', A = 'all' }

local function views()
  return require('rikuesto.ui.response_view')
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

-- Layout aliases: historical names stay valid, but each maps to one concrete placement.
--   bottom | split | botright -> horizontal split below the request window (default)
--   right  | vsplit          -> vertical split to the right
--   top                      -> horizontal split above
--   left                     -> vertical split to the left
--   float                    -> floating window
local LAYOUT_ALIASES = {
  split = 'bottom',
  botright = 'bottom',
  vsplit = 'right',
}

local function resolve_layout(layout)
  layout = LAYOUT_ALIASES[layout] or layout or 'right'
  if layout ~= 'bottom' and layout ~= 'right' and layout ~= 'top' and layout ~= 'left' and layout ~= 'float' then
    return 'right'
  end
  return layout
end

--- Split the current window and show the response buffer in the new one.
--- `:vsbuffer` is not an Ex command, so the split and the buffer switch are two separate steps.
local function open_split(layout)
  local vertical = (layout == 'right' or layout == 'left')
  local placement = (layout == 'top' or layout == 'left') and 'topleft' or 'belowright'
  vim.cmd(('silent %s %s'):format(placement, vertical and 'vsplit' or 'split'))
  local new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_win, buf)
  local size = config.get().ui.response.size or 0.5
  if vertical then
    vim.api.nvim_win_set_width(new_win, math.max(30, math.floor(vim.o.columns * size)))
  else
    vim.api.nvim_win_set_height(new_win, math.max(6, math.floor(vim.o.lines * size)))
  end
  return new_win
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
  local layout = resolve_layout(config.get().ui.response.layout)
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
    win = open_split(layout)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].wrap = false
  end
  vim.wo[win].cursorline = false
  vim.wo[win].conceallevel = 0
  -- `q` closes; H/B/S/A jump to a view and J/K walk the H→B→S→A order. Buffer-local on
  -- purpose: the response buffer is the only place these keys exist.
  vim.keymap.set('n', 'q', function()
    M.close()
  end, { buffer = buf, nowait = true, silent = true, desc = 'rikuesto: close response' })
  for key, name in pairs(VIEW_KEYS) do
    vim.keymap.set('n', key, function()
      M.set_view(name)
    end, { buffer = buf, silent = true, desc = 'rikuesto: response ' .. name })
  end
  vim.keymap.set('n', 'J', function()
    M.set_view(views().step(M.view(), 1))
  end, { buffer = buf, silent = true, desc = 'rikuesto: next response view' })
  vim.keymap.set('n', 'K', function()
    M.set_view(views().step(M.view(), -1))
  end, { buffer = buf, silent = true, desc = 'rikuesto: previous response view' })
  return win
end

--- Redraw the buffer for the current view and mirror the view in the buffer name, so the
--- status line always says which block you are looking at.
local function render()
  if not current or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = views().lines(current.response, current.ctx, current.view)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = (current.response.json and current.view ~= 'header') and 'json' or 'rikuesto-response'
  pcall(vim.api.nvim_buf_set_name, buf, ('rikuesto://response/%s'):format(current.view))
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end
end

--- Render a response into the response buffer.
--- The selected view is sticky for the session: the configured `ui.response.view` seeds the first
--- window, and whatever the user pressed last applies to the next response.
function M.open(response, ctx)
  current = {
    response = response or {},
    ctx = ctx or {},
    view = sticky_view or views().configured(),
  }
  local target = ensure_window()
  render()
  return target
end

--- Current view name.
function M.view()
  return current and current.view or views().configured()
end

--- Switch the open response buffer to another view.
--- @return string|nil the view actually shown, nil when nothing is rendered or the name is unknown
function M.set_view(view)
  local name = views().normalize(view)
  if not current or not name then
    return nil
  end
  current.view = name
  sticky_view = name
  render()
  return name
end

function M.close()
  release()
  current = nil
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Show the last response again (used by :Rikuesto response last and by view switching after
--- the window was closed). An explicit `view` overrides the sticky one.
function M.reopen(view)
  local last = state.last
  if not last or not last.response then
    return false
  end
  M.open(last.response, { request = last.request })
  local name = views().normalize(view)
  if name then
    M.set_view(name)
  end
  return true
end

function M.reset()
  win, buf, current, sticky_view = nil, nil, nil, nil
end

return M
