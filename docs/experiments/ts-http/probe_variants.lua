-- Probe: (a) `> ./file.js` in several shapes, (b) json_body `[{\[]\s+` requirement
local cases = {
  {
    name = 'A: response-path right after request line',
    text = { 'GET https://e.com/1', '> ./handler.js' },
  },
  {
    name = 'B: response-path after blank line',
    text = { 'GET https://e.com/1', '', '> ./handler.js' },
  },
  {
    name = 'C: response-path after headers+body',
    text = { 'POST https://e.com/1', 'Content-Type: application/json', '', '{"a":1}', '> ./handler.js' },
  },
  {
    name = 'D: inline json body without space (json_body?)',
    text = { 'POST https://e.com/1', 'Content-Type: application/json', '', '{"a":1}' },
  },
  {
    name = 'E: json body with newline after brace',
    text = { 'POST https://e.com/1', 'Content-Type: application/json', '', '{', '  "a": 1', '}' },
  },
  {
    name = 'F: script response handler after body',
    text = { 'POST https://e.com/1', 'Content-Type: application/json', '', '{"a":1}', '', '> {%', '  client.log(1);', '%}' },
  },
}

for _, c in ipairs(cases) do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, c.text)
  vim.bo[buf].filetype = 'http'
  local parser = vim.treesitter.get_parser(buf, 'http')
  parser:parse(true)
  local root = parser:parse()[1]:root()
  local parts = {}
  local function walk(n)
    local t = n:type()
    if t == 'request' or t == 'res_handler_script' or t == 'pre_request_script'
      or t == 'json_body' or t == 'raw_body' or t == 'external_body' or t == 'ERROR' or t == 'path'
      or t == 'script' or t == 'target_url' or t == 'header' or t == 'section' then
      local txt = vim.treesitter.get_node_text(n, buf, {}):gsub('\n', '\\n'):sub(1, 40)
      parts[#parts + 1] = string.format('%s(%q)', t, txt)
    end
    for ch in n:iter_children() do walk(ch) end
  end
  walk(root)
  print(c.name .. '\n   ' .. table.concat(parts, ' '))
end

-- vim.json key order round trip
local src = '{"z":1,"a":2,"m":3}'
local dec = vim.json.decode(src)
local enc = vim.json.encode(dec)
print('vim.json roundtrip: ' .. src .. ' -> ' .. enc)
