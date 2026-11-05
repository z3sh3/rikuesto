-- lualine component (and a plain string getter for the builtin statusline).
local M = {}

local state = require('rikuesto.state')

function M.status()
  local last = state.last
  if not last or not last.response then
    return 'rikuesto: idle'
  end
  local response = last.response
  if response.error then
    return ('rikuesto: %s'):format(response.error.kind or 'error')
  end
  return ('rikuesto: %s %dms'):format(tostring(response.status or '?'),
    math.floor((response.duration_ms or 0) + 0.5))
end

--- lualine entry point.
function M.component()
  return M.status()
end

function M.setup()
  -- opt-in: users can put `require('rikuesto.ui.statusline').component` into lualine.
  return M
end

return M
