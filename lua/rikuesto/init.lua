-- Public plugin entry point.
local M = {}

local config = require('rikuesto.config')

--- @param opts table|nil
function M.setup(opts)
  config.setup(opts)
  require('rikuesto.commands').register()
  require('rikuesto.keymaps').define_plugs()

  local group = vim.api.nvim_create_augroup('rikuesto', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'http', 'rest' },
    callback = function(event)
      vim.bo[event.buf].commentstring = '### %s'
      vim.bo[event.buf].omnifunc = 'v:lua.rikuesto_omnifunc'
      require('rikuesto.keymaps').attach(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'TextChanged' }, {
    group = group,
    pattern = { '*.http', '*.rest' },
    callback = function()
      require('rikuesto.ui.omnifunc').invalidate()
    end,
  })

  return M
end

--- Run the request under the cursor (or by name).
function M.run(name)
  require('rikuesto.commands').dispatch({ args = name and ('run ' .. name) or 'run' })
end

function M.run_all()
  require('rikuesto.commands').dispatch({ args = 'run all' })
end

--- Render the curl command for the cursor request (DESIGN §7.6): a pasteable, executable
--- command with every payload inlined.
function M.curl(dialect)
  local exec = require('rikuesto.exec')
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local result, request = exec.context(0, row)
  return (require('rikuesto.commands').curl_string(request, result, dialect))
end

function M.copy_curl()
  require('rikuesto.commands').dispatch({ args = 'copy', bang = true })
end

function M.format()
  require('rikuesto.commands').dispatch({ args = 'format' })
end

function M.env()
  return require('rikuesto.env.api')
end

function M.state()
  return require('rikuesto.state')
end

return M
