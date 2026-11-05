-- Thin notification wrapper: de-duplicates identical messages in a short window.
local M = {}

local last_message, last_time = nil, 0
local WINDOW_MS = 3000

local function now_ms()
  if vim.uv and vim.uv.hrtime then
    return math.floor(vim.uv.hrtime() / 1e6)
  end
  return 0
end

function M.notify(message, level, opts)
  opts = opts or {}
  local stamp = now_ms()
  if not opts.force and message == last_message and (stamp - last_time) < WINDOW_MS then
    return
  end
  last_message, last_time = message, stamp
  local text = opts.prefix == false and message or ('[rikuesto] ' .. message)
  vim.notify(text, level or vim.log.levels.INFO, { title = 'rikuesto' })
end

function M.info(message, opts)
  M.notify(message, vim.log.levels.INFO, opts)
end

function M.warn(message, opts)
  M.notify(message, vim.log.levels.WARN, opts)
end

function M.error(message, opts)
  M.notify(message, vim.log.levels.ERROR, opts)
end

function M.reset()
  last_message, last_time = nil, 0
end

return M
