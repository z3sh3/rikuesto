-- Minimal, dependency-free helpers shared by every rikuesto module.
local M = {}

function M.trim(s)
  if type(s) ~= 'string' then
    return s
  end
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.ltrim(s)
  return (s:gsub('^%s+', ''))
end

function M.rtrim(s)
  return (s:gsub('%s+$', ''))
end

function M.is_blank(s)
  return s == nil or s:match('^%s*$') ~= nil
end

function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.ends_with(s, suffix)
  return suffix == '' or s:sub(-#suffix) == suffix
end

function M.has_leading_ws(s)
  return s:match('^[ \t]') ~= nil
end

--- Width of the leading whitespace, tab = 2 columns (matches .http convention).
function M.indent_width(s)
  local ws = s:match('^[ \t]*') or ''
  local width = 0
  for i = 1, #ws do
    width = width + (ws:sub(i, i) == '\t' and 2 or 1)
  end
  return width, ws
end

--- RFC 3986 percent-encoding for query/path segments (keeps unreserved + typical URL chars).
function M.percent_encode(s)
  if type(s) ~= 'string' then
    return s
  end
  return (s:gsub('[^%w%-%._~:/%?#%[%]@!%$&\'%(%)%*%+,;=]', function(ch)
    return string.format('%%%02X', ch:byte())
  end))
end

--- Split text into lines, tolerating CRLF and a missing trailing newline.
function M.lines(text)
  if type(text) ~= 'string' or text == '' then
    return {}
  end
  local out = {}
  local normalized = text:gsub('\r\n', '\n')
  for line in (normalized .. '\n'):gmatch('(.-)\n') do
    out[#out + 1] = line
  end
  -- drop the artificial empty line produced by the trailing newline
  if out[#out] == '' and normalized:sub(-1) == '\n' then
    out[#out] = nil
  end
  return out
end

function M.join(list, sep)
  return table.concat(list, sep or '')
end

function M.split(s, sep)
  local out = {}
  if s == '' then
    return out
  end
  local pattern = '([^' .. sep .. ']+)'
  for piece in s:gmatch(pattern) do
    out[#out + 1] = piece
  end
  return out
end

function M.rep(s, n)
  return string.rep(s, math.max(0, n))
end

--- Replace secrets for logs / exported curl commands.
function M.mask(text, patterns)
  if type(text) ~= 'string' then
    return text
  end
  local masked = text
  for _, pattern in ipairs(patterns or {}) do
    local quoted = pattern:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')
    -- header style:  Authorization: Bearer xxx
    masked = masked:gsub('([Mm]?[%w%-_]*' .. quoted .. '[%w%-_]*%s*:%s*)[^\r\n]+', '%1***')
    -- flag style:   -H "X-Api-Key: xxx" / --token xxx
    masked = masked:gsub('([' .. quoted .. '][%w%-_]*=)[^&%s]+', '%1***')
  end
  return masked
end

function M.short(text, max)
  max = max or 60
  text = tostring(text or ''):gsub('\r', ''):gsub('\n', '\\n')
  if #text <= max then
    return text
  end
  return text:sub(1, max) .. '…'
end

return M
