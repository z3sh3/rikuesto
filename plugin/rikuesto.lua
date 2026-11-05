-- Loaded once at startup: filetype detection + lazy command registration (cheap, no module soup).
if vim.g.rikuesto_loaded == 1 then
  return
end
vim.g.rikuesto_loaded = 1

vim.filetype.add({
  extension = {
    http = 'http',
    rest = 'http',
  },
})

-- omnifunc entry point (called as v:lua.rikuesto_omnifunc)
_G.rikuesto_omnifunc = function(findstart, base)
  return require('rikuesto.ui.omnifunc').complete(findstart, base)
end

if vim.fn.exists(':Rikuesto') == 0 then
  vim.api.nvim_create_user_command('Rikuesto', function(opts)
    require('rikuesto.commands').dispatch(opts)
  end, {
    nargs = '*',
    bang = true,
    desc = 'rikuesto HTTP client',
    complete = function(arg_lead)
      return require('rikuesto.commands').complete(arg_lead)
    end,
  })
end
