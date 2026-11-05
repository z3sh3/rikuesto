-- `{{ ... }}` substitution engine: single pass, recursive expansion, cycle detection (DESIGN §6.1–6.2).
local M = {}

local chain = require('rikuesto.resolve.chain')
local dynamic = require('rikuesto.resolve.dynamic')
local pencode = require('rikuesto.resolve.pyencode')
local str = require('rikuesto.util.str')

local MAX_DEPTH = 10

local function report(scope, kind, info)
  if type(scope) == 'table' and type(scope.report) == 'function' then
    pcall(scope.report, kind, info)
  end
end

local function remember(used, name)
  for _, existing in ipairs(used) do
    if existing == name then
      return
    end
  end
  used[#used + 1] = name
end

--- Walk a dotted path into a nested table value (`{{cfg.host}}`, DESIGN §10.2).
local function walk(value, path)
  local cursor = value
  local rest = path
  while type(cursor) == 'table' do
    local key, more = rest:match('^([^%.]+)%.?(.*)$')
    if not key then
      return nil
    end
    cursor = cursor[key]
    if cursor == nil or more == '' then
      return cursor
    end
    rest = more
  end
  return nil
end

local function from_layer(layer, name)
  if type(layer) ~= 'table' then
    return nil
  end
  local value = layer[name]
  if value ~= nil then
    return value
  end
  local head, more = name:match('^([^%.]+)%.(.+)$')
  if head then
    return walk(layer[head], more)
  end
  return nil
end

--- Highest-priority scope layer defining `name` (request > chain > block > file > env).
local function lookup(scope, name)
  local value = from_layer(scope.request, name)
  if value ~= nil then
    return value
  end
  if type(scope.chain) == 'table' and name:find('.', 1, true) then
    local chained = chain.lookup(name, scope.chain)
    if chained ~= nil then
      return chained
    end
  end
  for _, key in ipairs({ 'block', 'file', 'env' }) do
    value = from_layer(scope[key], name)
    if value ~= nil then
      return value
    end
  end
  return nil
end

local substitute

--- Resolve one placeholder body (`inner`) into its replacement text.
local function expand_placeholder(inner, placeholder, scope, visited, depth, used)
  local name = str.trim(inner)
  if name == '' then
    return placeholder
  end
  local encode = name:sub(1, 1) == '%'
  if encode then
    name = str.trim(name:sub(2))
    if name == '' then
      return placeholder
    end
  end
  if depth >= MAX_DEPTH then
    report(scope, 'cycle', { name = name, depth = depth })
    return placeholder
  end

  if name:sub(1, 1) == '$' then
    local head, args = name:match('^(%$[%w%._]+)%s*(.-)$')
    local value = scope.dynamic and head and dynamic.expand(head, args) or nil
    if value == nil then
      report(scope, 'unknown', { name = name })
      return placeholder
    end
    remember(used, name)
    return encode and pencode.encode(value) or value
  end

  if visited[name] then
    report(scope, 'cycle', { name = name, depth = depth })
    return placeholder
  end

  local value = lookup(scope, name)
  if value == nil or type(value) == 'table' then
    report(scope, 'unknown', { name = name })
    return placeholder
  end
  remember(used, name)

  local text = tostring(value)
  if text:find('{{', 1, true) then
    visited[name] = true
    text = substitute(text, scope, visited, depth + 1, used)
    visited[name] = nil
  end
  if encode then
    return pencode.encode(text)
  end
  return text
end

substitute = function(text, scope, visited, depth, used)
  local out = {}
  local pos = 1
  while true do
    local open = text:find('{{', pos, true)
    if not open then
      out[#out + 1] = text:sub(pos)
      break
    end
    local close = text:find('}}', open + 2, true)
    if not close then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, open - 1)
    out[#out + 1] = expand_placeholder(text:sub(open + 2, close - 1), text:sub(open, close + 1), scope, visited,
      depth, used)
    pos = close + 2
  end
  return table.concat(out)
end

--- Replace every `{{...}}` in `text`. -> new_text, used_names[]
--- scope: { env, file, block, request, chain, dynamic, report } (all optional).
function M.substitute(text, scope)
  if type(text) ~= 'string' or text == '' then
    return text, {}
  end
  scope = type(scope) == 'table' and scope or {}
  local used = {}
  return substitute(text, scope, {}, 0, used), used
end

return M
