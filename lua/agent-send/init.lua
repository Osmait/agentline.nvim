--- Send the lines you are looking at to a coding agent, with a question.
---
--- The buffer is the source of truth, not the file on disk. What you have on
--- screen is what you are asking about, and it is routinely a few keystrokes
--- ahead of what has been written out — sending the saved copy would answer a
--- question nobody asked.
---
--- The path travels absolute, and the lines travel with it. An agent working
--- in a worktree or another checkout cannot resolve `src/foo.rs` the way this
--- editor does, so it gets both the location and the text itself.

local herdr = require("agent-send.herdr")

local M = {}

--- @class agent_send.Config
--- @field template string    how a message is put together
--- @field remember_target boolean  reuse the last agent instead of asking again
--- @field max_lines integer  how much of a selection to send

--- @type agent_send.Config
local config = {
  --- Placeholders: {prompt} {path} {range} {filetype} {text}
  ---
  --- The question comes first because it is what the agent reads first, and
  --- the code goes in a fence tagged with the filetype so it arrives as code.
  template = table.concat({
    "{prompt}",
    "",
    "{path}:{range}",
    "",
    "```{filetype}",
    "{text}",
    "```",
  }, "\n"),
  remember_target = true,
  max_lines = 400,
  --- Agents offered for a fresh one. herdr decides what it can actually
  --- start, so an unsupported name comes back as herdr's own refusal rather
  --- than a guess at one.
  agents = { "claude", "codex", "opencode", "pi" },
  --- Where a fresh agent is opened. Neovim's own directory by default: it is
  --- where you are, and on a project opened the usual way it is the project.
  --- @type fun():string
  new_agent_dir = function()
    return vim.fn.getcwd()
  end,
}

--- The pane last sent to, so a second question does not ask again.
--- @type string|nil
local last_pane = nil

--- @param opts agent_send.Config|nil
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

--- The lines under the cursor or the selection, read out of the buffer.
--- @param from integer 1-based, inclusive
--- @param to integer 1-based, inclusive
--- @return string text, string range, boolean cut
local function read_lines(from, to)
  local lines = vim.api.nvim_buf_get_lines(0, from - 1, to, false)
  local cut = false
  if #lines > config.max_lines then
    lines = vim.list_slice(lines, 1, config.max_lines)
    table.insert(lines, ("… %d of %d lines"):format(config.max_lines, to - from + 1))
    cut = true
  end
  local range = from == to and tostring(from) or ("%d-%d"):format(from, to)
  return table.concat(lines, "\n"), range, cut
end

--- Where the buffer lives. Unnamed buffers have nowhere, which is still an
--- answer worth sending: the text stands on its own.
--- @return string
local function buffer_path()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return "[unsaved buffer]"
  end
  return vim.fn.fnamemodify(name, ":p")
end

--- @class agent_send.Dest
--- @field kind string        the agent's name
--- @field pane string|nil    where to send it; nil for one that does not exist yet
--- @field cwd string         where it works, or would
--- @field title string
--- @field refusal string|nil
--- @field fresh boolean      true when it has to be started first

--- @param d agent_send.Dest
--- @return string
local function describe(d)
  local where = vim.fn.fnamemodify(d.cwd, ":t")
  if d.fresh then
    return ("+ new %s in %s"):format(d.kind, where)
  end
  local head = ("%s · %s"):format(d.kind, where)
  if d.refusal then
    return ("%s   (%s)"):format(head, d.refusal)
  end
  if d.title ~= "" then
    return ("%s   %s"):format(head, d.title)
  end
  return head
end

--- Everywhere the text could go: the agents that exist, then the ones that
--- would have to be started.
---
--- The fresh ones come last because starting an agent costs more than talking
--- to one that is already sitting there — and because an idle agent in the
--- right directory is almost always the better answer.
--- @param agents agent_send.Agent[]
--- @return agent_send.Dest[]
function M.destinations(agents)
  local out = {}
  for _, a in ipairs(agents) do
    table.insert(out, {
      kind = a.kind,
      pane = a.pane,
      cwd = a.cwd,
      title = a.title,
      refusal = a.refusal,
      fresh = false,
    })
  end

  local dir = config.new_agent_dir()
  for _, kind in ipairs(config.agents) do
    table.insert(out, { kind = kind, pane = nil, cwd = dir, title = "", refusal = nil, fresh = true })
  end
  return out
end

--- Asks where it should go, unless there is an obvious answer.
--- @param dests agent_send.Dest[]
--- @param on_pick fun(dest: agent_send.Dest|nil)
local function choose(dests, on_pick)
  local free = vim.tbl_filter(function(d)
    return d.refusal == nil
  end, dests)

  -- A refused agent is left out of the list but its reason is kept, so
  -- "everything that exists is busy" can still be said while a fresh one is
  -- offered underneath.
  local busy = {}
  for _, d in ipairs(dests) do
    if d.refusal then
      table.insert(busy, ("  %s · %s — %s"):format(d.kind, vim.fn.fnamemodify(d.cwd, ":t"), d.refusal))
    end
  end
  if #busy > 0 then
    vim.notify("agent-send: busy —\n" .. table.concat(busy, "\n"), vim.log.levels.INFO)
  end

  if config.remember_target and last_pane then
    for _, d in ipairs(free) do
      if d.pane == last_pane then
        return on_pick(d)
      end
    end
  end

  vim.ui.select(free, { prompt = "Send to:", format_item = describe }, on_pick)
end

--- Builds the message that would be sent, without sending it.
---
--- Public because it is the part worth checking, and because yanking the
--- message instead of sending it is a reasonable thing to want.
--- @param from integer
--- @param to integer
--- @param prompt string
--- @return string message, string range, boolean cut
function M.compose(from, to, prompt)
  local text, range, cut = read_lines(from, to)
  local path = buffer_path()
  local filetype = vim.bo.filetype ~= "" and vim.bo.filetype or ""

  -- Substituted through functions rather than replacement strings: Lua reads
  -- `%1` and friends inside a replacement, and source code is full of `%`.
  -- The function form hands the value back verbatim.
  local fields = {
    ["{prompt}"] = prompt,
    ["{path}"] = path,
    ["{range}"] = range,
    ["{filetype}"] = filetype,
    ["{text}"] = text,
  }
  local message = (config.template:gsub("{%a+}", function(key)
    -- an unknown placeholder is left as itself, so a typo in a configured
    -- template looks like a typo instead of vanishing
    return fields[key]
  end))
  return message, range, cut
end

--- @param from integer
--- @param to integer
--- @param prompt string
local function send(from, to, prompt)
  local message, range, cut = M.compose(from, to, prompt)

  --- @param dest agent_send.Dest
  --- @param pane string
  local function deliver(dest, pane)
    herdr.prompt(pane, message, function(perr)
      if perr then
        -- A fresh agent that cannot be given its task is a window nobody
        -- asked for, so it goes away again. Closing a workspace touches no
        -- files: the directory it opened on was already there.
        if dest.fresh then
          herdr.close_workspace(pane, function() end)
        end
        return vim.notify("agent-send: " .. perr, vim.log.levels.ERROR)
      end
      last_pane = pane
      local note = ("agent-send: %s lines sent to %s"):format(range, dest.kind)
      if dest.fresh then
        note = note .. (" in %s"):format(vim.fn.fnamemodify(dest.cwd, ":t"))
      end
      if cut then
        note = note .. (" (cut to %d lines)"):format(config.max_lines)
      end
      vim.notify(note, vim.log.levels.INFO)
    end)
  end

  --- Workspace, then agent, then task. Whatever was made is unmade if the
  --- step after it fails, or a half-built window is left behind.
  --- @param dest agent_send.Dest
  local function start_and_deliver(dest)
    vim.notify(("agent-send: starting %s in %s…"):format(dest.kind, dest.cwd), vim.log.levels.INFO)
    local label = ("%s · %s"):format(dest.kind, vim.fn.fnamemodify(dest.cwd, ":t"))

    herdr.create_workspace(dest.cwd, label, function(pane, werr)
      if werr then
        return vim.notify("agent-send: " .. werr, vim.log.levels.ERROR)
      end
      herdr.start_agent(pane, dest.kind, function(aerr)
        if aerr then
          herdr.close_workspace(pane, function() end)
          return vim.notify("agent-send: " .. aerr, vim.log.levels.ERROR)
        end
        deliver(dest, pane)
      end)
    end)
  end

  herdr.agents(function(agents, err)
    if err then
      return vim.notify("agent-send: " .. err, vim.log.levels.ERROR)
    end

    choose(M.destinations(agents), function(dest)
      if not dest then
        return
      end
      if dest.fresh then
        start_and_deliver(dest)
      else
        deliver(dest, dest.pane)
      end
    end)
  end)
end

--- The entry point the command uses.
--- @param opts table the command's own argument table
function M.send(opts)
  if not herdr.available() then
    return vim.notify("agent-send: herdr is not on the PATH", vim.log.levels.ERROR)
  end

  -- With a range, the selection. Without one, the whole buffer: asking about a
  -- file you did not select any of is a real thing to want.
  local from, to = opts.line1, opts.line2
  if opts.range == 0 then
    from, to = 1, vim.api.nvim_buf_line_count(0)
  end

  local prompt = vim.trim(opts.args or "")
  if prompt ~= "" then
    return send(from, to, prompt)
  end

  vim.ui.input({ prompt = "Ask the agent: " }, function(answer)
    if not answer or vim.trim(answer) == "" then
      return
    end
    send(from, to, vim.trim(answer))
  end)
end

--- Prints what is running, without sending anything.
function M.list()
  if not herdr.available() then
    return vim.notify("agent-send: herdr is not on the PATH", vim.log.levels.ERROR)
  end
  herdr.agents(function(agents, err)
    if err then
      return vim.notify("agent-send: " .. err, vim.log.levels.ERROR)
    end
    if #agents == 0 then
      return vim.notify("agent-send: no agents running", vim.log.levels.INFO)
    end
    local out = {}
    for _, a in ipairs(agents) do
      table.insert(out, "  " .. describe(a))
    end
    vim.notify(table.concat(out, "\n"), vim.log.levels.INFO)
  end)
end

return M
