-- UI/command smoke test for the wired plugin (network used for exactly one request).
-- Run: nvim --headless -l tests/smoke/run_ui.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h:h')

package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  root .. '/?.lua',
  package.path,
}, ';')
vim.opt.runtimepath:append(root)

local checks, failures = 0, {}
local function check(condition, label)
  checks = checks + 1
  if not condition then
    failures[#failures + 1] = label
    print('FAIL  ' .. label)
  else
    print('pass  ' .. label)
  end
end

-- 1. plugin entry: filetype detection + command registration
vim.cmd('runtime! plugin/rikuesto.lua')
check(vim.fn.exists(':Rikuesto') == 2, 'plugin/rikuesto.lua registers :Rikuesto')
check(vim.filetype.match({ filename = 'a.http' }) == 'http', '.http detected as http filetype')

-- 2. setup() wires config, keymaps and autocmds
local rikuesto = require('rikuesto')
rikuesto.setup({
  log = { level = 'error' },
  curl = { proxy = (vim.env.RIKUESTO_TEST_PROXY and vim.env.RIKUESTO_TEST_PROXY ~= '')
      and vim.env.RIKUESTO_TEST_PROXY or nil },
})
check(vim.fn.exists(':Rikuesto') == 2, 'setup() keeps a single :Rikuesto command')

-- 3. edit test.http for real (filetype detection must be on, as it is in a normal session)
vim.cmd('filetype plugin indent on')
vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/test.http'))
local bufnr = vim.api.nvim_get_current_buf()
check(vim.bo[bufnr].filetype == 'http', 'test.http buffer has filetype=http')
check(vim.bo[bufnr].commentstring == '### %s', 'ftplugin sets commentstring')
check(vim.bo[bufnr].omnifunc == 'v:lua.rikuesto_omnifunc', 'ftplugin sets omnifunc')

local parsed = require('rikuesto.parse.block').parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
check(#parsed.requests == 18, ('parser sees 18 requests (got %d)'):format(#parsed.requests))

-- 4. keymaps
local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
local function has_map(rhs)
  for _, map in ipairs(maps) do
    if map.rhs == rhs then
      return true
    end
  end
  return false
end
check(has_map('<Plug>(rikuesto-run)'), 'default <localleader>rr maps to the run plug')
check(has_map('<Plug>(rikuesto-copy-curl)'), 'default <localleader>rc maps to copy-curl')

-- 5. omnifunc completion inside {{ }}
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { '@host = api.example.com' })
do
  local complete = require('rikuesto.ui.omnifunc').complete
  local items = complete(0, '')
  local has_base = false
  for _, item in ipairs(items) do
    if item.word == 'base' then
      has_base = true
    end
  end
  check(has_base, 'omnifunc offers the file variable @base')
  local dynamic = complete(0, '$')
  check(#dynamic > 0 and dynamic[1].word:sub(1, 1) == '$', 'omnifunc offers $dynamic variables')
end

-- 6. :Rikuesto curl (export path, no network)
do
  vim.api.nvim_win_set_cursor(0, { 12, 0 }) -- first request line in test.http
  require('rikuesto.commands').dispatch({ args = 'curl', bang = true })
  local exported = vim.fn.getreg('+')
  check(exported:find('jsonplaceholder%.typicode%.com') ~= nil, 'copy-curl resolves @base')
  check(exported:find('{{', 1, true) == nil, 'copy-curl has no unresolved placeholders')
end

-- 7. :Rikuesto run (one real request) -> response window + extmark + state
do
  vim.api.nvim_win_set_cursor(0, { 12, 0 })
  require('rikuesto.exec').run_request(parsed.requests[1], parsed, bufnr, { async = false })
  local resp_win = require('rikuesto.ui.response_win')
  check(resp_win.is_open(), 'response window opened')
  local last = require('rikuesto.state').last
  check(last and last.response and last.response.status == 200,
    ('state recorded status 200 (got %s)'):format(tostring(last and last.response and last.response.status)))
  check(last and type(last.response.json) == 'table', 'response body decoded as JSON')
  local summaries = require('rikuesto.state').results[bufnr]
  check(summaries and summaries[1] ~= nil, 'per-request summary stored for the extmark')
  resp_win.close()
  check(not resp_win.is_open(), 'response window closes')
end

-- 8. :Rikuesto format is idempotent on the real corpus
do
  local buf_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local formatter = require('rikuesto.format.formatter')
  local once = formatter.format_lines(vim.split(buf_text, '\n', { plain = true }),
    require('rikuesto.parse.block').parse(vim.split(buf_text, '\n', { plain = true })))
  local twice = formatter.format_lines(once.lines, require('rikuesto.parse.block').parse(once.lines))
  check(table.concat(once.lines, '\n') == table.concat(twice.lines, '\n'), 'format is idempotent')
  local reparsed = require('rikuesto.parse.block').parse(once.lines)
  check(#reparsed.requests == 18, 'formatting preserves all 18 requests')
  check(#(reparsed.diagnostics or {}) == 0, 'formatting introduces no diagnostics')
end

-- 9. :Rikuesto env / vars / log do not blow up
do
  require('rikuesto.commands').dispatch({ args = 'env list' })
  require('rikuesto.commands').dispatch({ args = 'vars' })
  require('rikuesto.commands').dispatch({ args = 'log' })
  check(true, 'env/vars/log subcommands run without error')
end

-- 10. keymap overrides: `false` disables, a string replaces the lhs
--     (regression: `overrides[key] or default` treated `false` as "use default")
do
    local keymaps = require('rikuesto.keymaps')
    require('rikuesto.config').setup({
        log = { level = 'error' },
        ui = { response = { open = 'never' } },
        keymaps = { rr = false, rc = ',rc' },
    })
    keymaps.attach(bufnr)
    local leader = vim.g.maplocalleader or vim.g.mapleader or '\\'
    local function rhs_of(lhs)
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
            if map.lhs == lhs then
                return map.rhs
            end
        end
        return nil
    end
    check(rhs_of(leader .. 'rr') == nil, 'keymaps.rr = false removes the default mapping')
    check(rhs_of(',rc') == '<Plug>(rikuesto-copy-curl)', 'keymaps.rc = ",rc" installs the custom lhs')
    check(rhs_of(leader .. 'rf') == '<Plug>(rikuesto-format)', 'non-overridden defaults stay in place')
end

-- 11. health module
do
  local ok, err = pcall(function()
    require('rikuesto.health').check()
  end)
  check(ok, 'checkhealth module runs: ' .. tostring(err))
end

print('')
print(('SMOKE: %d checks, %d failure(s)'):format(checks, #failures))
for _, failure in ipairs(failures) do
  print('  x ' .. failure)
end
os.exit(#failures == 0 and 0 or 1)
