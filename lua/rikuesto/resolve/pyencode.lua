-- Percent-encoding for `{{%name}}` placeholders (DESIGN §6.2).
-- Unreserved characters (RFC 3986) stay as-is, existing `%XX` escapes are kept
-- verbatim so an already-encoded value is never double-encoded.
local M = {}

local function is_unreserved(ch)
  return ch:match('^[%w%-%._~]$') ~= nil
end

function M.encode(value)
  if value == nil then
    return ''
  end
  local text = tostring(value)
  local out = {}
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)
    if ch == '%' and text:sub(i + 1, i + 2):match('^%x%x$') then
      out[#out + 1] = text:sub(i, i + 2)
      i = i + 3
    elseif is_unreserved(ch) then
      out[#out + 1] = ch
      i = i + 1
    else
      out[#out + 1] = string.format('%%%02X', ch:byte())
      i = i + 1
    end
  end
  return table.concat(out)
end

return M
