-- Ring-buffer logger. Async curl/JS side effects are impossible to debug without it.
local M = {}

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }
local LEVEL_INDEX = { 10, 20, 30, 40 }

local entries = {}
local seq = 0

local function current_level()
  local ok, config = pcall(function()
    return require('rikuesto.config').get()
  end)
  if not ok or not config then
    return LEVELS.warn
  end
  return LEVELS[(config.log and config.log.level) or 'warn'] or LEVELS.warn
end

local function keep()
  local ok, config = pcall(function()
    return require('rikuesto.config').get()
  end)
  if not ok or not config then
    return 500
  end
  return (config.log and config.log.keep) or 500
end

function M.add(level, fmt, ...)
  level = level or 'info'
  local payload = fmt
  if select('#', ...) > 0 then
    local args = { ... }
    local ok, formatted = pcall(string.format, fmt, unpack(args))
    payload = ok and formatted or tostring(fmt)
  end
  if type(payload) ~= 'string' then
    payload = vim.inspect(payload)
  end
  seq = seq + 1
  local millis = math.floor((vim.uv and vim.uv.hrtime() or 0) / 1e6) % 1000
  local entry = {
    seq = seq,
    level = level,
    time = os.date('%H:%M:%S') .. string.format('.%03d', millis),
    message = payload,
  }
  entries[#entries + 1] = entry
  local limit = keep()
  while #entries > limit do
    table.remove(entries, 1)
  end
  if (LEVELS[level] or 20) >= current_level() and level ~= 'debug' then
    vim.schedule(function()
      vim.notify('[rikuesto] ' .. payload, LEVELS[level] == LEVELS.error and vim.log.levels.ERROR
        or (LEVELS[level] == LEVELS.warn and vim.log.levels.WARN or vim.log.levels.INFO))
    end)
  end
  return entry
end

function M.debug(fmt, ...)
  return M.add('debug', fmt, ...)
end

function M.info(fmt, ...)
  return M.add('info', fmt, ...)
end

function M.warn(fmt, ...)
  return M.add('warn', fmt, ...)
end

function M.error(fmt, ...)
  return M.add('error', fmt, ...)
end

--- Silent variant: buffer only (used for expected/noisy conditions).
function M.record(level, fmt, ...)
  local saved = entries
  local before = #saved
  local entry = M.add(level, fmt, ...)
  entries = saved
  if #entries > before then
    entries[#entries] = entry
  end
  return entry
end

function M.entries()
  local copy = {}
  for i, entry in ipairs(entries) do
    copy[i] = entry
  end
  return copy
end

function M.clear()
  entries = {}
  seq = 0
end

function M.dump()
  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = string.format('%s %-5s %s', entry.time, entry.level:upper(), entry.message)
  end
  return table.concat(out, '\n')
end

function M.levels()
  return LEVEL_INDEX, LEVELS
end

return M
