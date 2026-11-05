-- Public env API: active profile, merged variables, in-memory switching (INTERFACES §3).
local M = {}

local file = require('rikuesto.env.file')
local profile = require('rikuesto.env.profile')
local log = require('rikuesto.util.log')

local switched = nil --- @type string|nil  profile chosen with M.switch() for this session
local switched_path = nil --- @type string|nil  env file the switch was made against

--- Loaded document, dropping an in-memory profile that no longer applies.
local function document()
  local data = file.load()
  if switched and (switched_path ~= data.path or data.profiles[switched] == nil) then
    log.warn('env profile %q no longer available, falling back to %s', switched, tostring(data.active))
    switched = nil
    switched_path = nil
  end
  return data
end

local function current_profile(data)
  return switched or data.active
end

--- Effective env.json path (not necessarily existing).
function M.path()
  return file.resolve_path()
end

--- Re-read env.json now. A profile picked with M.switch() survives as long as the file still defines it.
function M.reload()
  file.invalidate()
  local data = document()
  log.debug('env reloaded from %s (active=%s)', data.path, tostring(M.active()))
  return data
end

--- Active profile name, or nil when the file defines none.
function M.active()
  return current_profile(document())
end

--- Sorted profile names.
function M.list()
  return profile.names(document().profiles)
end

--- Environment variables: global.var overridden by the active profile's keys.
function M.variables()
  local data = document()
  local name = current_profile(data)
  local section = name and data.profiles[name] or nil
  return profile.merge(data.global_var, section)
end

--- Single variable in its string form, or nil.
function M.get(name)
  if type(name) ~= 'string' or name == '' then
    return nil
  end
  local value = M.variables()[name]
  if type(value) ~= 'string' then
    return nil
  end
  return value
end

--- Switch the active profile in memory. -> ok(boolean), err(string)
function M.switch(name)
  if type(name) ~= 'string' or name == '' then
    return nil, 'env profile name required'
  end
  local data = document()
  if data.profiles[name] == nil then
    local available = table.concat(profile.names(data.profiles), ', ')
    return nil, ('unknown env profile %q (available: %s)'):format(name, available ~= '' and available or 'none')
  end
  switched = name
  switched_path = data.path
  log.debug('env profile switched to %s', name)
  return true
end

--- `global.defaults` — the lowest-priority layer below `setup()` (DESIGN §10.2).
function M.defaults()
  return vim.deepcopy(document().defaults)
end

return M
