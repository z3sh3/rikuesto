-- Buffer-local keymaps for .http buffers.
--
-- Defaults are OFF (`config.keymaps = false`): the plugin installs no shortcuts unless you ask for
-- them. `<Plug>(rikuesto-*)` mappings are always defined so users can bind their own keys, and
-- `<C-c>` is installed only while a request is in flight (see install_cancel/remove_cancel).
local M = {}

local config = require('rikuesto.config')

local DEFAULTS = {
  rr = { '<Plug>(rikuesto-run)', 'run request under cursor' },
  ra = { '<Plug>(rikuesto-run-all)', 'run all requests' },
  rc = { '<Plug>(rikuesto-copy-curl)', 'copy as curl' },
  rf = { '<Plug>(rikuesto-format)', 'format buffer' },
  re = { '<Plug>(rikuesto-env)', 'switch env profile' },
  rl = { '<Plug>(rikuesto-list)', 'list requests' },
  rx = { '<Plug>(rikuesto-cancel)', 'cancel request' },
  rv = { '<Plug>(rikuesto-vars)', 'show resolved variables' },
}

--- Buffers that currently carry the temporary cancel mapping.
local cancel_installed = {}

local function plug(name, rhs)
  vim.keymap.set('n', '<Plug>(rikuesto-' .. name .. ')', rhs, { silent = true, desc = 'rikuesto: ' .. name })
end

function M.define_plugs()
  plug('run', function()
    require('rikuesto.commands').dispatch({ args = 'run' })
  end)
  plug('run-all', function()
    require('rikuesto.commands').dispatch({ args = 'run all' })
  end)
  plug('copy-curl', function()
    require('rikuesto.commands').dispatch({ args = 'copy', bang = true })
  end)
  plug('format', function()
    require('rikuesto.commands').dispatch({ args = 'format' })
  end)
  plug('env', function()
    require('rikuesto.commands').dispatch({ args = 'env' })
  end)
  plug('list', function()
    require('rikuesto.commands').dispatch({ args = 'list' })
  end)
  plug('cancel', function()
    require('rikuesto.commands').dispatch({ args = 'cancel' })
  end)
  plug('vars', function()
    require('rikuesto.commands').dispatch({ args = 'vars' })
  end)
end

local function leader()
  return vim.g.maplocalleader or vim.g.mapleader or '\\'
end

local function set_buffer_map(bufnr, lhs, rhs, desc)
  vim.keymap.set('n', lhs, rhs, {
    buffer = bufnr,
    silent = true,
    remap = true,
    desc = 'rikuesto: ' .. desc,
  })
end

--- Attach buffer-local keymaps according to `config.keymaps`:
---   false          -> nothing (the default)
---   true           -> the full default set, prefixed with the local leader
---   { key = lhs }  -> only the listed keys, on the given lhs (alias `false` removes a stale one)
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local setting = config.get().keymaps
  M.define_plugs()

  if setting == false or setting == nil then
    return
  end

  if setting == true then
    for key, spec in pairs(DEFAULTS) do
      set_buffer_map(bufnr, leader() .. key, spec[1], spec[2])
    end
    return
  end

  if type(setting) ~= 'table' then
    return
  end

  -- Explicit table: map exactly what the user listed, nothing else.
  for key, spec in pairs(DEFAULTS) do
    local lhs = setting[key]
    local default_lhs = leader() .. key
    if type(lhs) == 'string' and lhs ~= '' then
      -- drop a stale default mapping when the custom lhs differs from it
      if lhs ~= default_lhs then
        pcall(vim.keymap.del, 'n', default_lhs, { buffer = bufnr })
      end
      set_buffer_map(bufnr, lhs, spec[1], spec[2])
    else
      pcall(vim.keymap.del, 'n', default_lhs, { buffer = bufnr })
    end
  end
end

--- Install the temporary `<C-c>` cancel mapping while a request is in flight.
--- Returns true when the mapping was installed (or already present).
function M.install_cancel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local key = config.get().cancel_key
  if type(key) ~= 'string' or key == '' then
    return false
  end
  if cancel_installed[bufnr] then
    return true
  end
  -- never shadow a mapping the user already owns
  if vim.api.nvim_get_current_buf() == bufnr and vim.fn.maparg(key, 'n') ~= '' then
    return false
  end
  vim.keymap.set('n', key, function()
    require('rikuesto.commands').dispatch({ args = 'cancel' })
  end, { buffer = bufnr, silent = true, desc = 'rikuesto: cancel request' })
  cancel_installed[bufnr] = true
  return true
end

--- Remove the temporary cancel mapping once the request finished.
function M.remove_cancel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not cancel_installed[bufnr] then
    return false
  end
  cancel_installed[bufnr] = nil
  local key = config.get().cancel_key
  if type(key) == 'string' and key ~= '' then
    pcall(vim.keymap.del, 'n', key, { buffer = bufnr })
  end
  return true
end

function M.is_cancel_installed(bufnr)
  return cancel_installed[bufnr or vim.api.nvim_get_current_buf()] == true
end

function M.defaults()
  return DEFAULTS
end

return M
