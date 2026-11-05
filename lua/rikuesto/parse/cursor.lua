-- Cursor helpers so UI code can stay independent of block.lua internals.
local block = require('rikuesto.parse.block')

local M = {}

--- Request under the cursor (0-based `row`), or nil outside a request block.
function M.request_at(result, row)
    return block.request_at(result, row)
end

return M
