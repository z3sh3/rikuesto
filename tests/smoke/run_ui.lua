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

-- 3b. Highlighting is owned by the user's parser manager: the plugin must not start tree-sitter.
check(not _G.rikuesto_treesitter_started_hook, 'plugin exposes no treesitter start hook')
check(require('rikuesto.config').get().treesitter == nil,
  'no treesitter option: highlighting is not the plugin\'s job')

local parsed = require('rikuesto.parse.block').parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
check(#parsed.requests == 18, ('parser sees 18 requests (got %d)'):format(#parsed.requests))

-- 4. keymaps: defaults are OFF — the plugin must not install shortcuts on its own
local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
local function count_plug_maps()
  local count = 0
  for _, map in ipairs(maps) do
    if type(map.rhs) == 'string' and map.rhs:find('<Plug>(rikuesto-', 1, true) then
      count = count + 1
    end
  end
  return count
end
check(count_plug_maps() == 0, 'no keymaps are installed by default (keymaps = false)')

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
  -- Copy as curl must be runnable: no response-capture plumbing, no file references.
  for _, forbidden in ipairs({ 'headers.txt', 'body.bin', 'writeout.json', '%{json}', '-sS' }) do
    check(exported:find(forbidden, 1, true) == nil, 'copy-curl has no ' .. forbidden)
  end
  check(exported:sub(1, 1) ~= "'", 'copy-curl does not start with a quoted command word')
  vim.api.nvim_win_set_cursor(0, { 46, 0 }) -- the JSON POST request
  require('rikuesto.commands').dispatch({ args = 'curl', bang = true })
  local posted = vim.fn.getreg('+')
  check(posted:find('--data%-raw') ~= nil, 'copy-curl inlines the body with --data-raw')
  check(posted:find('@', 1, true) == nil or posted:find('--data%-raw') ~= nil,
    'copy-curl does not reference a body file')

  -- The command must actually be executable, which a string comparison cannot prove:
  -- paste it into the real shell unchanged, with `--version` appended (curl prints its
  -- version and exits without touching the network). No `&`, no extra quoting: a copied
  -- command that needs fixing up before it runs is the bug this guards against.
  local pwsh = vim.fn.exepath('pwsh')
  if pwsh ~= '' then
    local result = vim.system({ pwsh, '-NoProfile', '-Command', posted .. ' --version' }):wait(20000)
    check(result.code == 0, ('copy-curl runs in pwsh unchanged (exit %s)'):format(tostring(result.code)))
    check(((result.stdout or ''):lower()):find('curl', 1, true) ~= nil,
      'copy-curl reaches curl with the parsed arguments')
  end
  local sh = vim.fn.exepath('sh')
  if sh ~= '' then
    local result = vim.system({ sh, '-c', posted .. ' --version' }):wait(20000)
    check(result.code == 0, ('copy-curl runs in sh unchanged (exit %s)'):format(tostring(result.code)))
  end
end

-- 7. `:Rikuesto run` through the real command dispatcher -> response window + extmark + state
--    (regression: the handler received the opts table but read it as a string, so `run` fell
--     through to the named-request branch and the command did nothing)
do
  vim.api.nvim_win_set_cursor(0, { 12, 0 })
  local origin_win = vim.api.nvim_get_current_win()
  require('rikuesto.commands').dispatch({ args = 'run', bang = false })
  local finished = vim.wait(30000, function()
    local last = require('rikuesto.state').last
    return last ~= nil and last.response ~= nil
  end, 100)
  check(finished, ':Rikuesto run triggers a request and records a response')
  local resp_win = require('rikuesto.ui.response_win')
  check(resp_win.is_open(), 'response window opened')
  local last = require('rikuesto.state').last
  check(last and last.response and last.response.status == 200,
    ('state recorded status 200 (got %s)'):format(tostring(last and last.response and last.response.status)))
  check(last and type(last.response.json) == 'table', 'response body decoded as JSON')
  local summaries = require('rikuesto.state').results[bufnr]
  check(summaries and summaries[1] ~= nil, 'per-request summary stored for the extmark')

  -- default layout: a vertical split on the right, not a top/bottom split
  check(vim.api.nvim_get_current_win() ~= origin_win, 'response opened in its own window')
  local opos = vim.api.nvim_win_get_position(origin_win)
  local rpos = vim.api.nvim_win_get_position(vim.api.nvim_get_current_win())
  check(rpos[1] == opos[1] and rpos[2] > opos[2],
    ('default layout places the response on the right (row %d/%d, col %d/%d)')
      :format(rpos[1], opos[1], rpos[2], opos[2]))

  -- unknown name must warn instead of running something random
  local before = require('rikuesto.state').last
  require('rikuesto.commands').dispatch({ args = 'run no-such-request', bang = false })
  check(require('rikuesto.state').last == before, ':Rikuesto run <unknown> runs nothing')
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

-- 10. keymap opt-in model (defaults off) + temporary <C-c> cancel mapping
do
    local keymaps = require('rikuesto.keymaps')
    local config_mod = require('rikuesto.config')

    local function plug_maps()
        local set = {}
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
            if type(map.rhs) == 'string' and map.rhs:find('<Plug>(rikuesto-', 1, true) then
                set[map.rhs] = (set[map.rhs] or 0) + 1
            end
        end
        return set
    end

    config_mod.setup({ log = { level = 'error' }, ui = { response = { open = 'never' } }, keymaps = true })
    keymaps.attach(bufnr)
    local all = plug_maps()
    check(all['<Plug>(rikuesto-run)'] == 1, 'keymaps = true maps run')
    check(all['<Plug>(rikuesto-run-all)'] == 1, 'keymaps = true maps run all')
    check(all['<Plug>(rikuesto-format)'] == 1, 'keymaps = true maps format')

    -- exactly the three bindings a user would write for <Space>r / <Space>c / <Space>e
    config_mod.setup({ keymaps = { rr = '<Space>r', rc = '<Space>c', re = '<Space>e' } })
    keymaps.attach(bufnr)
    local custom = plug_maps()
    check(custom['<Plug>(rikuesto-run)'] == 1, 'explicit table maps run')
    check(custom['<Plug>(rikuesto-copy-curl)'] == 1, 'explicit table maps copy-curl')
    check(custom['<Plug>(rikuesto-env)'] == 1, 'explicit table maps env')
    check(custom['<Plug>(rikuesto-run-all)'] == nil, 'explicit table leaves unlisted actions unmapped')
    check(custom['<Plug>(rikuesto-format)'] == nil, 'explicit table leaves format unmapped')
    local lhs_seen = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
        if type(map.rhs) == 'string' and map.rhs:find('<Plug>(rikuesto-', 1, true) then
            lhs_seen[vim.fn.keytrans(map.lhs)] = true
        end
    end
    check(lhs_seen['<Space>r'] == true, 'run is bound to <Space>r')
    check(lhs_seen['<Space>c'] == true, 'copy-curl is bound to <Space>c')
    check(lhs_seen['<Space>e'] == true, 'env is bound to <Space>e')

    -- <C-c> exists only while a request is in flight
    config_mod.setup({ keymaps = false, cancel_key = '<C-c>' })
    check(keymaps.install_cancel(bufnr), 'install_cancel installs a temporary mapping')
    check(keymaps.is_cancel_installed(bufnr), 'cancel mapping is tracked per buffer')
    local found_cancel = false
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
        if (map.desc or ''):find('cancel request', 1, true) then
            found_cancel = true
        end
    end
    check(found_cancel, '<C-c> is mapped to cancel while a request runs')
    check(keymaps.remove_cancel(bufnr), 'remove_cancel cleans up afterwards')
    check(not keymaps.is_cancel_installed(bufnr), 'no cancel mapping left behind')

    config_mod.setup({ cancel_key = false })
    check(keymaps.install_cancel(bufnr) == false, 'cancel_key = false disables the mapping')
    config_mod.setup({})
end

-- 11. response window layout is configurable (no network: renders a fake response)
do
    local mod = require('rikuesto.ui.response_win')
    local config_mod = require('rikuesto.config')

    local fake = { status = 200, reason = 'OK', headers = {}, body = '{}', ok = true }

    local function place(layout)
        local opts = { log = { level = 'error' }, ui = { response = { open = 'never' } } }
        if layout then
            opts.ui.response.layout = layout
        end
        config_mod.setup(opts)
        mod.reset()
        vim.cmd('silent! only')
        local scratch = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { 'GET https://example.com', '', '###' })
        vim.api.nvim_win_set_buf(0, scratch)
        local origin = vim.api.nvim_get_current_win()
        mod.open(fake, {})
        local rwin = vim.api.nvim_get_current_win()
        local opos = vim.api.nvim_win_get_position(origin)
        local rpos = vim.api.nvim_win_get_position(rwin)
        mod.close()
        vim.api.nvim_buf_delete(scratch, { force = true })
        return opos, rpos
    end

    local opos, rpos = place(nil)
    check(rpos[1] == opos[1] and rpos[2] > opos[2], 'default layout is a vertical split on the right')
    opos, rpos = place('bottom')
    check(rpos[1] > opos[1] and rpos[2] == opos[2], 'layout = bottom opens below')
    opos, rpos = place('vsplit')
    check(rpos[1] == opos[1] and rpos[2] > opos[2], 'legacy vsplit alias means right')
    opos, rpos = place('nonsense')
    check(rpos[1] == opos[1] and rpos[2] > opos[2], 'unknown layout falls back to right')
    config_mod.setup({})
end

-- 11b. response views: H/B/S/A jump, J/K walk the order, and the keys stay buffer-local
--      (regression: the response buffer used to be one flat block with no way to split it up)
do
  local rw = require('rikuesto.ui.response_win')
  local config_mod = require('rikuesto.config')
  local fake = {
    status = 200,
    reason = 'OK',
    headers = { { name = 'Content-Type', value = 'application/json' } },
    body = '{"a":1}',
    json = { a = 1 },
    ok = true,
    script_logs = { 'log line from js' },
    script_tests = { { name = 'has a body', pass = true } },
    assertions = { { raw = 'status == 200', pass = true } },
  }
  local http_buf = vim.api.nvim_get_current_buf()
  config_mod.setup({ log = { level = 'error' }, ui = { response = { open = 'never' } } })
  rw.reset()
  rw.open(fake, { request = { method = 'GET', url = 'https://example.com' } })
  local resp_buf = vim.api.nvim_get_current_buf()
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(resp_buf, 0, -1, false), '\n')
  end
  local function press(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'x', false)
  end
  local function mapped(target)
    local keys = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(target, 'n')) do
      keys[map.lhs] = true
    end
    return keys
  end

  check(rw.view() == 'all', 'a fresh response opens in the all view')
  check(text():find('--- headers', 1, true) ~= nil and text():find('--- body', 1, true) ~= nil,
    'the all view holds headers and body')
  check(text():find('log line from js', 1, true) == nil, 'the all view excludes script output')
  local resp_keys = mapped(resp_buf)
  for _, key in ipairs({ 'H', 'B', 'S', 'A', 'J', 'K' }) do
    check(resp_keys[key] == true, 'the response buffer maps ' .. key)
  end
  local http_keys = mapped(http_buf)
  check(http_keys.H == nil and http_keys.B == nil and http_keys.S == nil and http_keys.A == nil
    and http_keys.J == nil and http_keys.K == nil, 'no view keys leak into the .http buffer')

  press('H')
  check(rw.view() == 'header', 'H shows the header view')
  check(text():find('Content-Type: application/json', 1, true) ~= nil, 'the header view lists the headers')
  check(text():find('--- body', 1, true) == nil, 'the header view has no body')
  press('S')
  check(rw.view() == 'script' and text():find('log line from js', 1, true) ~= nil, 'S shows the script view')
  press('B')
  check(rw.view() == 'body' and text():find('--- headers', 1, true) == nil, 'B shows the body view')
  check(text():find('--- body', 1, true) == nil, 'the body view has no `--- body ---` title line')
  check(text():sub(1, 1) == '{', 'the body view starts with the body itself')
  press('A')
  check(rw.view() == 'all', 'A returns to the all view')

  press('J')
  check(rw.view() == 'header', 'J from all wraps to header')
  press('J')
  check(rw.view() == 'body', 'J walks header -> body')
  press('K')
  check(rw.view() == 'header', 'K walks back to header')
  press('K')
  check(rw.view() == 'all', 'K from header wraps to all')

  -- `ui.response.view` seeds the first window of a session
  rw.close()
  config_mod.setup({ log = { level = 'error' }, ui = { response = { open = 'never', view = 'body' } } })
  rw.reset()
  rw.open(fake, { request = { method = 'GET', url = 'https://example.com' } })
  check(rw.view() == 'body', 'ui.response.view seeds the opening view')
  rw.close()
  config_mod.setup({})
end

-- 11c. `:Rikuesto response <view>` reaches the same views by command
do
  local rw = require('rikuesto.ui.response_win')
  local state = require('rikuesto.state')
  rw.reset()
  state.last = {
    request = { method = 'GET', url = 'https://example.com' },
    response = { status = 200, reason = 'OK', headers = {}, body = '{}', ok = true },
  }
  require('rikuesto.commands').dispatch({ args = 'response header', bang = false })
  check(rw.is_open() and rw.view() == 'header', ':Rikuesto response header opens the header view')
  require('rikuesto.commands').dispatch({ args = 'response script', bang = false })
  check(rw.view() == 'script', ':Rikuesto response script switches the open window')
  require('rikuesto.commands').dispatch({ args = 'response nonsense', bang = false })
  check(rw.view() == 'script', 'an unknown view name changes nothing')
  rw.close()
  require('rikuesto.commands').dispatch({ args = 'response', bang = false })
  check(rw.is_open() and rw.view() == 'script', 'the selected view sticks across close/reopen')
  rw.close()
end

-- 12. health module
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
