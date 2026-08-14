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

-- --- where it can go ---

test("a fresh agent is offered for every configured kind", function()
  send.setup({ agents = { "claude", "codex" }, new_agent_dir = function()
    return "/tmp/somewhere"
  end })
  local dests = send.destinations({})

  eq(#dests, 2, "one per kind, and nothing else when nothing is running")
  eq(dests[1].fresh, true)
  eq(dests[1].cwd, "/tmp/somewhere", "opened where the editor is")
  eq(dests[1].pane, nil, "it does not exist yet, so it has no address")
end)

test("the ones that already exist are offered before the ones that do not", function()
  send.setup({ agents = { "claude" } })
  local dests = send.destinations({
    { kind = "pi", pane = "w1:p1", cwd = "/a", title = "", refusal = nil },
  })
  eq(dests[1].fresh, false, "talking to a running agent costs less than starting one")
  eq(dests[2].fresh, true)
end)

test("a fresh agent is offered even when every running one is busy", function()
  send.setup({ agents = { "claude" } })
  local dests = send.destinations({
    { kind = "pi", pane = "w1:p1", cwd = "/a", title = "", refusal = "working — …" },
  })
  local free = vim.tbl_filter(function(d)
    return d.refusal == nil
  end, dests)
  eq(#free, 1, "\"everything is busy\" should not mean \"nowhere to go\"")
  eq(free[1].fresh, true)
end)

test("the directory is asked for each time, not captured once", function()
  local where = "/first"
  send.setup({ agents = { "claude" }, new_agent_dir = function()
    return where
  end })
  eq(send.destinations({})[1].cwd, "/first")
  where = "/second"
  eq(send.destinations({})[1].cwd, "/second", "nvim's directory changes while it runs")
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

-- --- the chain that starts a fresh agent, and undoes itself ---
--
-- Run against the real server, and deliberately made to fail at the middle
-- link: it proves the workspace is created and then cleaned up without
-- starting an agent that would cost anything.

if herdr.available() then
  local pane, werr, done = nil, nil, false
  herdr.create_workspace(vim.fn.getcwd(), "agent-send test probe", function(p, e)
    pane, werr, done = p, e, true
  end)
  vim.wait(10000, function()
    return done
  end)

  test("a workspace opens on a directory and hands back a pane", function()
    if werr then
      error("herdr said: " .. werr)
    end
    if not pane or not pane:match("^%w+:") then
      error("no usable pane came back: " .. tostring(pane))
    end
  end)

  if pane then
    local aerr, adone = nil, false
    herdr.start_agent(pane, "nosuchagent", function(e)
      aerr, adone = e, true
    end)
    vim.wait(10000, function()
      return adone
    end)

    test("an agent that cannot start is reported, not swallowed", function()
      if not aerr then
        error("herdr accepted an agent kind that does not exist")
      end
    end)

    local cerr, cdone = nil, false
    herdr.close_workspace(pane, function(e)
      cerr, cdone = e, true
    end)
    vim.wait(10000, function()
      return cdone
    end)

    test("and the workspace is closed again, leaving nothing behind", function()
      if cerr then
        error("the cleanup failed, which would leave a window nobody asked for: " .. cerr)
      end
    end)
  end
end

io.write(("\n%d run, %d failed\n\n"):format(ran, failures))
vim.cmd(failures == 0 and "qall!" or "cquit!")
