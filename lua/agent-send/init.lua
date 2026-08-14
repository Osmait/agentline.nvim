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

--- @param agent agent_send.Agent
--- @return string
local function describe(agent)
  local where = vim.fn.fnamemodify(agent.cwd, ":t")
  local head = ("%s · %s"):format(agent.kind, where)
  if agent.refusal then
    return ("%s   (%s)"):format(head, agent.refusal)
  end
  if agent.title ~= "" then
    return ("%s   %s"):format(head, agent.title)
  end
  return head
end

--- Asks which agent, unless there is an obvious answer.
--- @param agents agent_send.Agent[]
--- @param on_pick fun(agent: agent_send.Agent|nil)
local function choose(agents, on_pick)
  local free = vim.tbl_filter(function(a)
    return a.refusal == nil
  end, agents)

  if #free == 0 then
    -- Every one of them listed with its reason, because "all of them are
    -- busy" is a more useful answer than "none found".
    local why = {}
    for _, a in ipairs(agents) do
      table.insert(why, ("  %s · %s — %s"):format(a.kind, vim.fn.fnamemodify(a.cwd, ":t"), a.refusal))
    end
    local detail = #why > 0 and ("\n" .. table.concat(why, "\n")) or ""
    vim.notify("agent-send: nothing is free to take it" .. detail, vim.log.levels.WARN)
    return on_pick(nil)
  end

  if config.remember_target and last_pane then
    for _, a in ipairs(free) do
      if a.pane == last_pane then
        return on_pick(a)
      end
    end
  end
  if #free == 1 then
    return on_pick(free[1])
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

  herdr.agents(function(agents, err)
    if err then
      return vim.notify("agent-send: " .. err, vim.log.levels.ERROR)
    end
    if #agents == 0 then
      return vim.notify("agent-send: no agents running", vim.log.levels.WARN)
    end

    choose(agents, function(agent)
      if not agent then
        return
      end
      herdr.prompt(agent.pane, message, function(perr)
        if perr then
          return vim.notify("agent-send: " .. perr, vim.log.levels.ERROR)
        end
        last_pane = agent.pane
        local note = ("agent-send: %s lines sent to %s"):format(range, agent.kind)
        if cut then
          note = note .. (" (cut to %d lines)"):format(config.max_lines)
        end
        vim.notify(note, vim.log.levels.INFO)
      end)
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
