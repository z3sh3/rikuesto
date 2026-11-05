-- Buffer-local keymaps for .http buffers. `<Plug>` mappings are always defined.
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

--- Attach default keymaps to a buffer (respects `setup({ keymaps = ... })`).
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local setting = config.get().keymaps
  if setting == false then
    return
  end
  local leader = vim.g.maplocalleader or vim.g.mapleader or '\\'
  local overrides = type(setting) == 'table' and setting or {}
  M.define_plugs()
  for key, spec in pairs(DEFAULTS) do
    -- `false` disables the mapping; a string replaces the default lhs.
    local override = overrides[key]
    local lhs
    if override == false then
      -- also remove a mapping installed by an earlier attach (e.g. before setup() ran)
      pcall(vim.keymap.del, 'n', leader .. key, { buffer = bufnr })
      lhs = nil
    elseif type(override) == 'string' and override ~= '' then
      lhs = override
    else
      lhs = leader .. key
    end
    if lhs then
      vim.keymap.set('n', lhs, spec[1], {
        buffer = bufnr,
        silent = true,
        remap = true,
        desc = 'rikuesto: ' .. spec[2],
      })
    end
  end
end

return M
