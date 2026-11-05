-- Normalisation of one env.json section into the flat variable table the resolver consumes.
-- Schema reference: DESIGN §10.2 (`{ global = { env, var, defaults }, <profile> = { ... } }`).
local M = {}

--- Convert a JSON scalar into the string form variables are expected to have.
--- Returns nil for tables and for types JSON cannot produce.
function M.stringify(value)
  local kind = type(value)
  if kind == 'string' then
    return value
  end
  if kind == 'number' then
    if value == math.floor(value) then
      return string.format('%d', value)
    end
    return string.format('%.14g', value)
  end
  if kind == 'boolean' then
    return value and 'true' or 'false'
  end
  return nil
end

--- True when `value` is a decoded JSON object (tables decoded from arrays are excluded).
function M.is_object(value)
  if type(value) ~= 'table' then
    return false
  end
  return next(value) == nil or value[1] == nil
end

--- Copy `section` (name -> JSON value) into a variable table.
--- Scalars are stringified; nested objects are kept as tables so `{{cfg.host}}` still works.
function M.normalize(section, diagnostics, code)
  local out = {}
  if type(section) ~= 'table' then
    return out
  end
  for name, value in pairs(section) do
    if type(name) == 'string' then
      local scalar = M.stringify(value)
      if scalar ~= nil then
        out[name] = scalar
      elseif M.is_object(value) then
        out[name] = value
      elseif diagnostics then
        diagnostics[#diagnostics + 1] = {
          row = 0,
          col = 0,
          severity = 'warning',
          code = code or 'env.value',
          message = ('variable %q has an unsupported value type (%s), ignored'):format(name, type(value)),
        }
      end
    end
  end
  return out
end

--- Shallow merge: `override` wins over `base`. Always returns a new table.
function M.merge(base, override)
  local out = {}
  for name, value in pairs(base or {}) do
    out[name] = value
  end
  for name, value in pairs(override or {}) do
    out[name] = value
  end
  return out
end

--- Profile names of a loaded document, sorted alphabetically.
function M.names(profiles)
  local out = {}
  for name in pairs(profiles or {}) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

return M
