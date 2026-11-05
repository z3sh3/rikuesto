-- Built-in dynamic variables (`{{$uuid}}`, `{{$timestamp -1 d}}`, `{{$random.*}}`).
-- Pure Lua; time from os.date/os.time, randomness from math.random seeded once (DESIGN §6.3).
local M = {}

local SEEDED = false

local function seed()
  if SEEDED then
    return
  end
  SEEDED = true
  local nanos = 0
  if vim.uv and vim.uv.hrtime then
    nanos = vim.uv.hrtime() % 1000000000
  end
  math.randomseed(os.time() * 1000 + math.floor(nanos / 1000000))
end

local function random_int(min, max)
  seed()
  return math.random(min, max)
end

local function random_float()
  seed()
  return math.random()
end

local HEX = '0123456789abcdef'
local ALPHA = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local ALNUM = ALPHA .. '0123456789'

local function random_chars(count, alphabet)
  seed()
  local out = {}
  for i = 1, count do
    local index = random_int(1, #alphabet)
    out[i] = alphabet:sub(index, index)
  end
  return table.concat(out)
end

--- RFC 4122 version 4 UUID.
function M.uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return (template:gsub('[xy]', function(kind)
    local value = random_int(0, 15)
    if kind == 'y' then
      value = (value % 4) + 8
    end
    return HEX:sub(value + 1, value + 1)
  end))
end

--- Split an argument string ("-1 d", "(1,5)", "NAME") into tokens.
local function tokenize(args)
  local text
  if type(args) == 'table' then
    local parts = {}
    for index, value in ipairs(args) do
      parts[index] = tostring(value)
    end
    text = table.concat(parts, ' ')
  elseif args == nil then
    text = ''
  else
    text = tostring(args)
  end
  local out = {}
  for token in text:gmatch('[^%s,%(%)]+') do
    out[#out + 1] = token
  end
  return out
end

local UNIT_SECONDS = { s = 1, m = 60, h = 3600, d = 86400, w = 604800 }

--- Shift a unix timestamp by `offset` `unit` (y/Q/M need calendar arithmetic).
local function shift(base, offset, unit)
  if UNIT_SECONDS[unit] then
    return base + offset * UNIT_SECONDS[unit]
  end
  if unit ~= 'M' and unit ~= 'Q' and unit ~= 'y' and unit ~= 'Y' then
    return nil
  end
  local parts = os.date('*t', base)
  if unit == 'M' then
    parts.month = parts.month + offset
  elseif unit == 'Q' then
    parts.month = parts.month + offset * 3
  else
    parts.year = parts.year + offset
  end
  parts.isdst = nil
  return os.time(parts)
end

--- Apply every `<offset> <unit>` pair starting at `from`.
local function apply_offsets(base, tokens, from)
  local result = base
  local index = from
  while index + 1 <= #tokens do
    local offset = tonumber(tokens[index])
    if not offset then
      break
    end
    local shifted = shift(result, offset, tokens[index + 1])
    if not shifted then
      break
    end
    result = shifted
    index = index + 2
  end
  return result
end

local function now_seconds()
  if vim.uv and vim.uv.gettimeofday then
    local sec, usec = vim.uv.gettimeofday()
    if sec then
      return sec, usec or 0
    end
  end
  return os.time(), 0
end

local DATETIME_FORMATS = {
  rfc1123 = '%a, %d %b %Y %H:%M:%S GMT',
  iso8601 = '%Y-%m-%dT%H:%M:%SZ',
  iso = '%Y-%m-%dT%H:%M:%SZ',
  utc = '%Y-%m-%dT%H:%M:%SZ',
  rfc3339 = '%Y-%m-%dT%H:%M:%SZ',
}

local function datetime(tokens)
  local spec = tokens[1]
  local pattern, from
  if spec and DATETIME_FORMATS[spec:lower()] then
    pattern = DATETIME_FORMATS[spec:lower()]
    from = 2
  elseif spec and tonumber(spec) == nil and spec:find('%a') then
    -- explicit strftime subset, e.g. {{$datetime %Y%m%d}}
    pattern = spec
    from = 2
  else
    pattern = DATETIME_FORMATS.rfc1123
    from = 1
  end
  return os.date('!' .. pattern, apply_offsets(os.time(), tokens, from))
end

local function iso_timestamp()
  local sec, usec = now_seconds()
  local millis = math.floor((usec or 0) / 1000)
  return ('%s.%03dZ'):format(os.date('!%Y-%m-%dT%H:%M:%S', sec), millis)
end

local function env_lookup(name)
  if type(name) ~= 'string' or name == '' then
    return nil
  end
  local value = vim.env[name]
  if value == nil then
    return ''
  end
  return value
end

local function int_range(tokens, default_min, default_max)
  local min = tonumber(tokens[1])
  local max = tonumber(tokens[2])
  min = min or default_min
  max = max or default_max
  if min > max then
    min, max = max, min
  end
  return random_int(min, max)
end

--- Expand one dynamic variable. Returns a string, or nil when `name` is unknown.
--- `args` is the raw text after the name ("1 5", "-1 d", "(0,10)") or a token list.
function M.expand(name, args)
  if type(name) ~= 'string' or name == '' then
    return nil
  end
  local key = name:lower()
  local tokens = tokenize(args)

  if key == '$uuid' or key == '$guid' then
    return M.uuid()
  end
  if key == '$timestamp' then
    return tostring(apply_offsets(os.time(), tokens, 1))
  end
  if key == '$isotimestamp' then
    return iso_timestamp()
  end
  if key == '$datetime' then
    return datetime(tokens)
  end
  if key == '$randomint' then
    return tostring(int_range(tokens, 0, 1000))
  end
  if key == '$random.integer' then
    return tostring(int_range(tokens, 0, 1000))
  end
  if key == '$random.float' then
    local min = tonumber(tokens[1]) or 0
    local max = tonumber(tokens[2]) or 1000
    if min > max then
      min, max = max, min
    end
    return string.format('%.6f', min + random_float() * (max - min))
  end
  if key == '$random.alphabetic' then
    return random_chars(tonumber(tokens[1]) or 10, ALPHA)
  end
  if key == '$random.alphanumeric' then
    return random_chars(tonumber(tokens[1]) or 10, ALNUM)
  end
  if key == '$random.hexadecimal' then
    return random_chars(tonumber(tokens[1]) or 10, HEX)
  end
  if key == '$random.email' then
    return ('%s@%s.com'):format(random_chars(8, ALPHA):lower(), random_chars(6, ALPHA):lower())
  end
  if key == '$processenv' or key == '$env' then
    return env_lookup(tokens[1])
  end
  if key:sub(1, 5) == '$env.' then
    return env_lookup(name:sub(6))
  end
  if key == '$projectroot' then
    return vim.fn.getcwd()
  end
  return nil
end

--- Names understood by M.expand (for docs, completion and `:Rikuesto vars`).
function M.names()
  return {
    '$uuid',
    '$guid',
    '$timestamp',
    '$isoTimestamp',
    '$datetime',
    '$randomInt',
    '$random.integer',
    '$random.float',
    '$random.alphabetic',
    '$random.alphanumeric',
    '$random.hexadecimal',
    '$random.email',
    '$processEnv',
    '$env',
    '$env.NAME',
    '$projectRoot',
  }
end

return M
