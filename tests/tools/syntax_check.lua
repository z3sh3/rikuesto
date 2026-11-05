-- Syntax-only check: loadfile() every plugin Lua file (no execution, no side effects).
-- Run: nvim --headless -l tests/tools/syntax_check.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h:h')

local files = {}
local function scan(dir)
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok then
    return
  end
  for _, name in ipairs(entries) do
    local path = dir .. '/' .. name
    if vim.fn.isdirectory(path) == 1 then
      scan(path)
    elseif name:match('%.lua$') then
      files[#files + 1] = path
    end
  end
end
for _, dir in ipairs({ '/lua', '/plugin', '/ftplugin' }) do
  scan(root .. dir)
end
table.sort(files)

local bad = 0
for _, path in ipairs(files) do
  local chunk, err = loadfile(path)
  if not chunk then
    bad = bad + 1
    print(('SYNTAX FAIL %s\n  %s'):format(path:gsub(root .. '/', ''), err))
  end
end
print(('checked %d file(s), %d syntax error(s)'):format(#files, bad))
os.exit(bad == 0 and 0 or 1)
