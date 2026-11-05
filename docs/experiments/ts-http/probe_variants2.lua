local cases = {
  { name = 'G: > {% %} right after request line (no blank)', text = { 'GET https://e.com/1', '> {%', '  client.log(1);', '%}' } },
  { name = 'H: > {% %} right after headers (no blank)', text = { 'GET https://e.com/1', 'Accept: */*', '> {%', '  client.log(1);', '%}' } },
  { name = 'I: < {% %} right before request (no blank)', text = { '< {%', '  request.variables.set("a",1);', '%}', 'GET https://e.com/1' } },
  { name = 'J: < {% %} + blank line', text = { '< {%', '  request.variables.set("a",1);', '%}', '', 'GET https://e.com/1' } },
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
    if t == 'request' or t == 'res_handler_script' or t == 'pre_request_script' or t == 'script'
      or t == 'ERROR' or t == 'target_url' or t == 'MISSING' then
      parts[#parts + 1] = string.format('%s(%q)', t, (vim.treesitter.get_node_text(n, buf, {}):gsub('\n', '\n'):sub(1, 32)))
    end
    for ch in n:iter_children() do walk(ch) end
  end
  walk(root)
  print(c.name .. '\n   ' .. table.concat(parts, ' '))
end
