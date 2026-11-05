-- Buffer-local defaults for .http / .rest files.
vim.bo.commentstring = '### %s'
vim.bo.omnifunc = 'v:lua.rikuesto_omnifunc'
vim.bo.suffixesadd = '.http,.rest'

if vim.g.rikuesto_loaded == 1 then
  pcall(function()
    require('rikuesto.keymaps').attach(vim.api.nvim_get_current_buf())
  end)
end
