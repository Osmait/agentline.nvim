-- Run with:  nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/run.lua"
--
-- No test framework: this plugin is small enough that one would be more code
-- than the thing it tests, and a bare assert prints a usable message anyway.

local failures = 0
local ran = 0

--- @param name string
--- @param fn fun()
local function test(name, fn)
  ran = ran + 1
  local ok, err = pcall(fn)
  if ok then
    io.write("  ok    " .. name .. "\n")
  else
    failures = failures + 1
    io.write("  FAIL  " .. name .. "\n        " .. tostring(err) .. "\n")
  end
end

local function eq(got, want, what)
  if got ~= want then
    error(("%s\n        got:  %s\n        want: %s"):format(what or "mismatch", vim.inspect(got), vim.inspect(want)), 2)
  end
end

local function contains(haystack, needle, what)
  if not haystack:find(needle, 1, true) then
    error(("%s\n        %q not in:\n%s"):format(what or "missing", needle, haystack), 2)
  end
end

--- A scratch buffer holding `lines`, made current.
local function buffer(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

local send = require("agent-send")

io.write("\nagent-send\n")

test("a selection travels with its path, its range and its text", function()
  buffer({ "one", "two", "three", "four" }, "rust")
  local msg, range = send.compose(2, 3, "why does this break?")

  eq(range, "2-3", "the range is inclusive on both ends")
  contains(msg, "why does this break?", "the question leads")
  contains(msg, "two\nthree", "the selected lines are there")
  contains(msg, "```rust", "and they arrive tagged as code")
  if msg:find("one", 1, true) or msg:find("four", 1, true) then
    error("lines outside the selection came along")
  end
end)

test("a single line reads as one number, not a range", function()
  buffer({ "alpha", "beta" })
  local _, range = send.compose(2, 2, "?")
  eq(range, "2")
end)

test("percent signs in the code survive intact", function()
  -- The bug this exists for: Lua reads `%1` inside a gsub replacement, and
  -- source code is full of `%`. A format string would come out mangled.
  buffer({ 'printf("%d%% of %s\\n", n, name)' })
  local msg = send.compose(1, 1, "explain")
  contains(msg, '%d%% of %s', "the line arrived as written")
end)

test("percent signs in the question survive too", function()
  buffer({ "x" })
  local msg = send.compose(1, 1, "why 100%? and %s?")
  contains(msg, "why 100%? and %s?")
end)

test("a buffer with no name still says where it is not", function()
  buffer({ "scratch" })
  local msg = send.compose(1, 1, "?")
  contains(msg, "[unsaved buffer]", "an unnamed buffer is still worth sending")
end)

test("a buffer with no filetype opens an untagged fence", function()
  buffer({ "plain" })
  local msg = send.compose(1, 1, "?")
  contains(msg, "```\nplain")
end)

test("a long selection is cut and says so", function()
  local lines = {}
  for i = 1, 900 do
    lines[i] = "line " .. i
  end
  buffer(lines)

  send.setup({ max_lines = 50 })
  local msg, _, cut = send.compose(1, 900, "?")
  eq(cut, true, "it reports having cut")
  contains(msg, "… 50 of 900 lines", "and says so in the message itself")
  if msg:find("line 60", 1, true) then
    error("the cut did not hold")
  end
  send.setup({ max_lines = 400 })
end)

test("a configured template decides the shape", function()
  buffer({ "code here" }, "lua")
  send.setup({ template = "{filetype} at {range}: {prompt}" })
  local msg = send.compose(1, 1, "look")
  eq(msg, "lua at 1: look")
  send.setup({
    template = table.concat({ "{prompt}", "", "{path}:{range}", "", "```{filetype}", "{text}", "```" }, "\n"),
  })
end)

test("an unknown placeholder is left as itself", function()
  buffer({ "x" })
  send.setup({ template = "{prompt} {nope}" })
  local msg = send.compose(1, 1, "hi")
  eq(msg, "hi {nope}", "a typo should look like a typo, not vanish")
  send.setup({
    template = table.concat({ "{prompt}", "", "{path}:{range}", "", "```{filetype}", "{text}", "```" }, "\n"),
  })
end)

-- --- the herdr layer, against whatever is actually running ---

local herdr = require("agent-send.herdr")

test("herdr is reachable", function()
  if not herdr.available() then
    error("herdr is not on the PATH; the rest of these cannot run")
  end
end)

if herdr.available() then
  local done, agents, err = false, nil, nil
  herdr.agents(function(a, e)
    agents, err, done = a, e, true
  end)
  vim.wait(5000, function()
    return done
  end)

  test("the agent list comes back parsed", function()
    if err then
      error("herdr said: " .. err)
    end
    if not agents then
      error("no answer within five seconds")
    end
    for _, a in ipairs(agents) do
      if type(a.pane) ~= "string" or a.pane == "" then
        error("an agent with no pane cannot be addressed: " .. vim.inspect(a))
      end
    end
    io.write(("        (%d agent(s) running)\n"):format(#agents))
  end)

  test("the ones that can take work are offered first", function()
    local seen_refused = false
    for _, a in ipairs(agents or {}) do
      if a.refusal then
        seen_refused = true
      elseif seen_refused then
        error("a free agent came after a refused one")
      end
    end
  end)

  test("a refused agent carries its reason", function()
    for _, a in ipairs(agents or {}) do
      if a.refusal and vim.trim(a.refusal) == "" then
        error("refused with no reason given")
      end
    end
  end)
end

io.write(("\n%d run, %d failed\n\n"):format(ran, failures))
vim.cmd(failures == 0 and "qall!" or "cquit!")
