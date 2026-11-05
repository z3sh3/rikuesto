-- Targeted probe: answer specific structural questions about tree-sitter-http.
local path = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/fixture.http'
local lines = vim.fn.readfile(path)
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].filetype = 'http'

local parser = vim.treesitter.get_parser(buf, 'http')
parser:parse(true)
local root = parser:parse()[1]:root()

local out = {}
local function say(s) out[#out + 1] = s end

local top = {}
for child in root:iter_children() do
  local sr, _, er, _ = child:range()
  local txt = vim.treesitter.get_node_text(child, buf, {}):gsub('\n', '\\n')
  if #txt > 70 then txt = txt:sub(1, 70) .. '…' end
  top[#top + 1] = string.format('%-24s rows %2d-%-2d  %s', child:type(), sr, er, txt)
end
say('TOP-LEVEL CHILDREN (' .. #top .. ')')
for _, l in ipairs(top) do say('  ' .. l) end

-- helpers
local function find_all(t, typ, acc)
  acc = acc or {}
  if t:type() == typ then acc[#acc + 1] = t end
  for c in t:iter_children() do find_all(c, typ, acc) end
  return acc
end
local function txt(n)
  if type(n) == 'table' and n.range == nil then n = n[1] end
  if n == nil then return 'nil' end
  local ok, res = pcall(vim.treesitter.get_node_text, n, buf, {})
  if not ok then return '<err:' .. tostring(res):sub(1, 40) .. '>' end
  return (res:gsub('\n', '\\n'))
end

say('')
say('Q1 multi-line URL continuation:')
for _, n in ipairs(find_all(root, 'target_url')) do say('  target_url = ' .. txt(n):sub(1, 200)) end
for _, n in ipairs(find_all(root, 'url')) do say('  url = ' .. txt(n):sub(1, 200)) end

say('')
say('Q2 multi-line header value:')
for _, n in ipairs(find_all(root, 'header')) do
  local name = n:field('name')
  local val = n:field('value')
  say(string.format('  header name=%q value=%q', name and txt(name) or 'nil', val and txt(val):sub(1, 80) or 'nil'))
end

say('')
say('Q3 urlencoded body / Q4 external body / Q6 external script:')
for _, typ in ipairs({ 'raw_body', 'external_body', 'json_body', 'xml_body', 'graphql_data', 'script', 'response', 'body' }) do
  local ns = find_all(root, typ)
  if #ns > 0 then
    for _, n in ipairs(ns) do
      local sr, _, er, _ = n:range()
      say(string.format('  %-16s rows %2d-%-2d %q', typ, sr, er, txt(n):sub(1, 60)))
    end
  else
    say(string.format('  %-16s <none>', typ))
  end
end

say('')
say('Q5 script fields (pre-request / response):')
for _, n in ipairs(find_all(root, 'script')) do
  local kind = n:field('name') or n:field('kind')
  local body = n:field('body') or n:field('value')
  say(string.format('  script parent=%s kind=%s body=%q', n:parent():type(),
    kind and txt(kind) or 'nil', body and txt(body):sub(1, 50) or 'nil'))
end

say('')
say('Q7 metadata comments:')
for _, n in ipairs(find_all(root, 'comment')) do
  local nm = n:field('name')
  say(string.format('  comment name=%q value=%q raw=%q', nm and txt(nm) or 'nil',
    (n:field('value') and txt(n:field('value')) or 'nil'), txt(n):sub(1, 50)))
end

say('')
say('Q8 request count / Q9 := declaration / Q10 implicit GET:')
say('  request nodes = ' .. #find_all(root, 'request'))
for _, n in ipairs(find_all(root, 'variable_declaration')) do
  say('  variable_declaration: ' .. txt(n))
end
for _, n in ipairs(find_all(root, 'request')) do
  local m = n:field('method')
  say(string.format('  request rows %d-%d method=%s', n:range(), select(3, n:range()), m and txt(m) or 'nil'))
end
for _, n in ipairs(find_all(root, 'ERROR')) do
  say('  ERROR node: ' .. txt(n):sub(1, 60))
end
for _, n in ipairs(find_all(root, 'MISSING')) do
  say('  MISSING node: ' .. txt(n):sub(1, 60))
end

print(table.concat(out, '\n'))
