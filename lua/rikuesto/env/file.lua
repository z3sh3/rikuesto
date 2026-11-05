-- Locates, reads and parses env.json; caches by mtime (DESIGN §10.1, §10.3).
-- A broken file never throws: it yields `ok = false` plus diagnostics.
local M = {}

local profile = require('rikuesto.env.profile')
local platform = require('rikuesto.util.platform')
local log = require('rikuesto.util.log')

local cache = nil --- @type { path: string, mtime: string, data: table }|nil

local function config_env()
  local ok, config = pcall(require, 'rikuesto.config')
  if not ok then
    return {}
  end
  local cfg = config.get()
  return (cfg and cfg.env) or {}
end

--- Expand `~`/`$VAR` but never normalise the separators of an already concrete path.
local function expanded(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end
  local resolved = path
  if resolved:find('~', 1, true) or resolved:find('$', 1, true) then
    resolved = vim.fn.expand(resolved)
  end
  if resolved == '' then
    return nil
  end
  return resolved
end

--- Effective env.json path: config override > $RIKUESTO_ENV > platform default.
function M.resolve_path(override)
  local explicit = expanded(override) or expanded(config_env().path)
  if explicit then
    return explicit
  end
  local from_var = expanded(vim.env.RIKUESTO_ENV)
  if from_var then
    return from_var
  end
  local base
  if platform.is_windows then
    base = expanded(vim.env.LOCALAPPDATA)
  end
  if not base then
    base = expanded(vim.env.XDG_CONFIG_HOME)
  end
  if not base then
    base = vim.fs.joinpath(vim.fn.expand('~'), '.config')
  end
  return vim.fs.joinpath(base, 'nvim', 'rikuesto', 'env.json')
end

local function stat(path)
  local ok, result = pcall(vim.uv.fs_stat, path)
  if not ok or not result or not result.mtime then
    return nil
  end
  return string.format('%d.%d', result.mtime.sec or 0, result.mtime.nsec or 0)
end

--- 0-based row/col for a 1-based byte offset inside `text`.
local function position_at(text, offset)
  local stop = math.min(math.max(tonumber(offset) or 1, 1), #text + 1)
  local row, line_start = 0, 1
  for i = 1, stop - 1 do
    if text:sub(i, i) == '\n' then
      row = row + 1
      line_start = i + 1
    end
  end
  return row, stop - line_start
end

--- vim.json.decode wrapper that normalises both failure shapes into a message.
local function decode(text)
  local ok, decoded, err = pcall(vim.json.decode, text)
  if not ok then
    return nil, tostring(decoded)
  end
  if decoded == nil then
    return nil, tostring(err or 'empty JSON document')
  end
  return decoded
end

local function empty_document(path)
  return {
    path = path,
    profiles = {},
    active = nil,
    global_var = {},
    defaults = {},
    diagnostics = {},
    ok = true,
  }
end

local function count_errors(diagnostics)
  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.severity == 'error' then
      return true
    end
  end
  return false
end

--- Parse the raw env.json text into the documented document shape.
function M.parse(text, path)
  local data = empty_document(path)
  text = (text or ''):gsub('^\239\187\191', '')
  local decoded, err = decode(text)
  if decoded == nil then
    data.ok = false
    local row, col = position_at(text, (err or ''):match('character (%d+)'))
    data.diagnostics[#data.diagnostics + 1] = {
      row = row,
      col = col,
      severity = 'error',
      code = 'env.json',
      message = ('cannot parse env file: %s'):format(err),
    }
    return data
  end
  if type(decoded) ~= 'table' or not profile.is_object(decoded) then
    data.ok = false
    data.diagnostics[#data.diagnostics + 1] = {
      row = 0,
      col = 0,
      severity = 'error',
      code = 'env.schema',
      message = 'env file must contain a JSON object at the top level',
    }
    return data
  end

  local global = decoded.global
  if global ~= nil then
    if profile.is_object(global) then
      data.global_var = profile.normalize(global.var, data.diagnostics, 'env.var')
      if profile.is_object(global.defaults) then
        data.defaults = vim.deepcopy(global.defaults)
      elseif global.defaults ~= nil then
        data.diagnostics[#data.diagnostics + 1] = {
          row = 0,
          col = 0,
          severity = 'warning',
          code = 'env.schema',
          message = 'global.defaults must be an object, ignored',
        }
      end
      if type(global.env) == 'string' and global.env ~= '' then
        data.default_active = global.env
      end
    else
      data.diagnostics[#data.diagnostics + 1] = {
        row = 0,
        col = 0,
        severity = 'warning',
        code = 'env.schema',
        message = 'global must be an object, ignored',
      }
    end
  end

  for name, section in pairs(decoded) do
    if name ~= 'global' then
      if profile.is_object(section) then
        data.profiles[name] = profile.normalize(section, data.diagnostics, 'env.profile')
      else
        data.diagnostics[#data.diagnostics + 1] = {
          row = 0,
          col = 0,
          severity = 'warning',
          code = 'env.schema',
          message = ('profile %q must be an object, ignored'):format(tostring(name)),
        }
      end
    end
  end

  data.active = expanded(config_env().profile) or data.default_active
  if data.active and data.profiles[data.active] == nil then
    data.diagnostics[#data.diagnostics + 1] = {
      row = 0,
      col = 0,
      severity = 'warning',
      code = 'env.profile',
      message = ('configured profile %q is not defined in %s'):format(data.active, path),
    }
  end
  data.ok = not count_errors(data.diagnostics)
  return data
end

--- Load env.json. `path_opt` skips the usual path resolution (used by tests and `env check`).
--- Results are cached until the file's mtime changes; use M.invalidate() to force a re-read.
function M.load(path_opt)
  local path = M.resolve_path(path_opt)
  local mtime = stat(path)
  if cache and cache.path == path and mtime ~= nil and cache.mtime == mtime then
    return cache.data
  end

  local text = platform.read_file(path)
  local data
  if text == nil then
    data = empty_document(path)
    data.ok = false
    data.diagnostics[1] = {
      row = 0,
      col = 0,
      severity = 'info',
      code = 'env.missing',
      message = ('no env file at %s'):format(path),
    }
  else
    data = M.parse(text, path)
  end

  if mtime ~= nil then
    cache = { path = path, mtime = mtime, data = data }
  else
    cache = nil
  end
  log.debug('env file %s loaded (ok=%s, profiles=%d)', path, tostring(data.ok), #profile.names(data.profiles))
  return data
end

--- Drop the cached document so the next M.load() re-reads the file.
function M.invalidate()
  cache = nil
end

return M
