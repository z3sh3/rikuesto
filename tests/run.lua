-- Test runner: nvim --headless -l tests/run.lua [filter]
-- Discovers tests/**/*_spec.lua, runs each in isolation, prints a summary.
local helper = require('tests.helper')
local root = helper.root()

local filter = _G.arg and _G.arg[1] or nil

package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  root .. '/?.lua',
  package.path,
}, ';')
vim.opt.runtimepath:append(root)

local specs = {}
local function scan(dir)
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok then
    return
  end
  for _, name in ipairs(entries) do
    local path = dir .. '/' .. name
    if vim.fn.isdirectory(path) == 1 then
      if name ~= 'fixtures' and name ~= 'golden' then
        scan(path)
      end
    elseif name:match('_spec%.lua$') then
      if not filter or path:find(filter, 1, true) then
        specs[#specs + 1] = path
      end
    end
  end
end
scan(root .. '/tests')
table.sort(specs)

print(('rikuesto test run: %d spec file(s)%s'):format(#specs, filter and (' filter=' .. filter) or ''))
print(('nvim %s  lua %s'):format(vim.version().major .. '.' .. vim.version().minor .. '.' .. vim.version().patch,
  _VERSION))

local crashed = 0
for _, spec in ipairs(specs) do
  local chunk, load_err = loadfile(spec)
  if not chunk then
    crashed = crashed + 1
    print(('LOAD FAIL %s\n      %s'):format(spec:gsub(root .. '/', ''), load_err))
  else
    local ok, err = pcall(chunk)
    if not ok then
      crashed = crashed + 1
      print(('CRASH   %s\n      %s'):format(spec:gsub(root .. '/', ''), tostring(err)))
    end
  end
end

local cases, failures, per_module = helper.summary()
print('')
print(('TOTAL: %d assertions, %d failure(s), %d crashed spec file(s)'):format(cases, failures, crashed))
if failures > 0 then
  local names = vim.tbl_keys(per_module)
  table.sort(names)
  for _, name in ipairs(names) do
    print(('  %-28s %d failure(s)'):format(name, per_module[name]))
  end
end

if failures > 0 or crashed > 0 then
  os.exit(1)
end
os.exit(0)
