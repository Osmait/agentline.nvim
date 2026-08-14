--- Talking to herdr.
---
--- Everything here is asynchronous. `herdr agent list` takes about fifty
--- milliseconds, which is not long until it happens on every keystroke of a
--- picker; blocking the editor for it would be felt.
---
--- One thing is worth knowing before reading further: herdr wraps its answers
--- in an envelope, and prints the *failure* envelope on stdout with a zero
--- exit status. A call that went wrong therefore looks exactly like one that
--- went right until the envelope is opened.

local M = {}

--- @class agent_send.Agent
--- @field kind string        `claude`, `pi`, … — what is running
--- @field status string      working | idle | blocked | done | unknown
--- @field cwd string         where it is working
--- @field pane string        the address herdr accepts; it does not take names
--- @field title string       usually a summary of the current task
--- @field refusal string|nil why it cannot be given something new to do

--- States in which an agent can be handed a new task.
---
--- Deliberately the same rule github-tui applies, so the two behave alike:
--- typing into a working agent loses its context, and one stopped on a
--- permission prompt would read the task as the answer to the prompt.
local FREE = { idle = true, done = true }

--- @param status string
--- @return string|nil
local function refusal_for(status)
  if FREE[status] then
    return nil
  end
  if status == "unknown" then
    return "state unknown — not knowing is not permission"
  end
  return status .. " — interrupting would lose its context"
end

--- Runs herdr and hands back the `result` of its envelope.
--- @param args string[]
--- @param on_done fun(result: table|nil, err: string|nil)
local function call(args, on_done)
  local cmd = vim.list_extend({ "herdr" }, args)

  vim.system(cmd, { text = true }, function(out)
    local function finish(result, err)
      vim.schedule(function()
        on_done(result, err)
      end)
    end

    if out.code ~= 0 then
      local msg = vim.trim(out.stderr or "")
      if msg == "" then
        msg = vim.trim(out.stdout or "")
      end
      if msg == "" then
        msg = "herdr exited " .. tostring(out.code)
      end
      return finish(nil, msg)
    end

    local ok, decoded = pcall(vim.json.decode, out.stdout)
    if not ok or type(decoded) ~= "table" then
      return finish(nil, "herdr said something that is not JSON")
    end
    -- the zero-exit failure, which is why nothing here trusts the exit status
    if decoded.error then
      return finish(nil, decoded.error.message or "herdr refused the call")
    end
    finish(decoded.result or {}, nil)
  end)
end

--- Is there a herdr binary at all?
--- @return boolean
function M.available()
  return vim.fn.executable("herdr") == 1
end

--- Every agent herdr is running, annotated with whether it can take work.
--- @param on_done fun(agents: agent_send.Agent[]|nil, err: string|nil)
function M.agents(on_done)
  call({ "agent", "list" }, function(result, err)
    if err then
      return on_done(nil, err)
    end

    local out = {}
    for _, a in ipairs(result.agents or {}) do
      local status = a.agent_status or "unknown"
      table.insert(out, {
        kind = a.agent or "?",
        status = status,
        -- `foreground_cwd` follows the process; `cwd` is where the pane was
        -- opened. The first is the truer answer to "where is it working".
        cwd = a.foreground_cwd or a.cwd or "",
        pane = a.pane_id,
        title = a.terminal_title_stripped or a.terminal_title or "",
        refusal = refusal_for(status),
      })
    end

    -- the ones that can take it first; the rest stay listed, with the reason
    table.sort(out, function(x, y)
      local xr, yr = x.refusal ~= nil, y.refusal ~= nil
      if xr ~= yr then
        return yr
      end
      return false
    end)
    on_done(out, nil)
  end)
end

--- Opens a workspace on `cwd` and hands back the pane herdr made for it.
---
--- `--no-focus` on purpose: asking a question should not throw your terminal
--- over to a new workspace while you are still reading the answer's subject.
--- @param cwd string
--- @param label string
--- @param on_done fun(pane: string|nil, err: string|nil)
function M.create_workspace(cwd, label, on_done)
  call({ "workspace", "create", "--cwd", cwd, "--label", label, "--no-focus" }, function(result, err)
    if err then
      return on_done(nil, err)
    end
    local pane = result and result.root_pane and result.root_pane.pane_id
    if type(pane) ~= "string" or pane == "" then
      return on_done(nil, "herdr made a workspace with no pane in it")
    end
    on_done(pane, nil)
  end)
end

--- Starts an interactive agent of `kind` in a pane that already exists.
--- @param pane string
--- @param kind string
--- @param on_done fun(err: string|nil)
function M.start_agent(pane, kind, on_done)
  call({ "agent", "start", kind, "--kind", kind, "--pane", pane }, function(_, err)
    on_done(err)
  end)
end

--- Closes a workspace. Undoes `create_workspace` and touches no files: the
--- directory it was opened on was already there and stays as it was.
--- @param pane string
--- @param on_done fun(err: string|nil)
function M.close_workspace(pane, on_done)
  local workspace = pane:match("^([^:]+)") or pane
  call({ "workspace", "close", workspace }, function(_, err)
    on_done(err)
  end)
end

--- Hands `text` to the agent in `pane`, without waiting for it to finish.
--- @param pane string
--- @param text string
--- @param on_done fun(err: string|nil)
function M.prompt(pane, text, on_done)
  call({ "agent", "prompt", pane, text }, function(_, err)
    on_done(err)
  end)
end

return M
