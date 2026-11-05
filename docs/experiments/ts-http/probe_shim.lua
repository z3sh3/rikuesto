-- Probe: can vim.system exec Windows .cmd/.ps1 shims directly?
local cases = {
  { 'jq', { '--version' } },
  { 'oxfmt', { '--version' } },
  { 'oxfmt.CMD', { '--version' } },
  { 'jq.exe', { '--version' } },
}
for _, c in ipairs(cases) do
  local cmd = c[1]
  local exepath = vim.fn.exepath(cmd)
  local ok, res = pcall(function()
    return vim.system(vim.list_extend({ cmd }, c[2]), { text = true }):wait(10000)
  end)
  if not ok then
    print(string.format('%-10s exepath=%-60s SPAWN ERROR %s', cmd, tostring(exepath), tostring(res):sub(1, 60)))
  else
    local out = (res.stdout or ''):gsub('\n', ' '):sub(1, 40)
    print(string.format('%-10s exepath=%-60s code=%s out=%s err=%s', cmd, tostring(exepath), res.code,
      out, (res.stderr or ''):gsub('\n', ' '):sub(1, 40)))
  end
end
