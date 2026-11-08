-- Buffer-local defaults for .http / .rest files.
vim.bo.commentstring = '### %s'
vim.bo.omnifunc = 'v:lua.rikuesto_omnifunc'
vim.bo.suffixesadd = '.http,.rest'

if vim.g.rikuesto_loaded == 1 then
  pcall(function()
    require('rikuesto.keymaps').attach(vim.api.nvim_get_current_buf())
  end)
end

-- Syntax highlighting is deliberately NOT started here: tree-sitter is display-only and the parser
-- manager configured by the user owns `vim.treesitter.start()`. See AGENTS.md §3.2.
