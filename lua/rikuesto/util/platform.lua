-- Process/platform helpers. Everything here must work when nvim runs headless.
local M = {}

M.is_windows = jit and jit.os == 'Windows' or vim.fn.has('win32') == 1

--- vim.fn.exepath() augmented with PATHEXT guessing (Windows only).
function M.exepath(name)
  if type(name) ~= 'string' or name == '' then
    return nil
  end
  local found = vim.fn.exepath(name)
  if found ~= '' then
    return found
  end
  if M.is_windows and not name:match('%.%w+$') then
    for _, ext in ipairs({ '.exe', '.cmd', '.bat' }) do
      found = vim.fn.exepath(name .. ext)
      if found ~= '' then
        return found
      end
    end
  end
  return nil
end

--- Resolve a tool honouring config overrides, then PATH.
--- kind: 'curl' | 'jq' | 'oxfmt' | 'node' | 'deno'
function M.resolve_tool(kind)
  local ok, config = pcall(function()
    return require('rikuesto.config').get()
  end)
  if ok and config and config.tools and config.tools[kind] then
    return config.tools[kind]
  end
  return M.exepath(kind)
end

function M.tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

function M.joinpath(...)
  local parts = { ... }
  local out = table.concat(parts, '/')
  out = out:gsub('/+', '/')
  if M.is_windows then
    out = out:gsub('^/(%a):', '%1:')
  end
  return out
end

function M.read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path, 'b')
  if not ok or not lines then
    return nil
  end
  return table.concat(lines, '\n')
end

--- First line of `<tool> --version`, or nil.
function M.tool_version(argv)
  local ok, result = pcall(function()
    return vim.system(argv, { text = true }):wait(4000)
  end)
  if not ok or not result or result.code ~= 0 then
    return nil
  end
  local first = (result.stdout or ''):match('([^\r\n]+)')
  return first
end

return M
