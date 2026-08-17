--- Small, dependency-free windows for writing a message and choosing an agent.
---
--- `vim.ui.select` and `vim.ui.input` are useful extension points, but their
--- built-in versions collapse the two things that matter here: an agent has a
--- status plus a task, and a question often needs more than one line.

local M = {}

local namespace = vim.api.nvim_create_namespace("agentline-ui")

local STATUS_MARK = {
  idle = "●",
  done = "●",
  working = "◌",
  blocked = "!",
  unknown = "?",
  new = "+",
}

local STATUS_HIGHLIGHT = {
  idle = "DiagnosticOk",
  done = "DiagnosticOk",
  working = "DiagnosticWarn",
  blocked = "DiagnosticError",
  unknown = "DiagnosticWarn",
  new = "DiagnosticInfo",
}

local function clamp(value, low, high)
  return math.max(low, math.min(value, high))
end

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local out = ""
  for i = 0, vim.fn.strchars(text) - 1 do
    local char = vim.fn.strcharpart(text, i, 1)
    if vim.fn.strdisplaywidth(out .. char .. "…") > width then
      break
    end
    out = out .. char
  end
  return out .. "…"
end

local function pad(text, width)
  local missing = width - vim.fn.strdisplaywidth(text)
  return text .. string.rep(" ", math.max(1, missing))
end

local function window_size(preferred_width, preferred_height)
  local width = clamp(preferred_width, 1, math.max(1, vim.o.columns - 4))
  local height = clamp(preferred_height, 1, math.max(1, vim.o.lines - 6))
  return width, height
end

local function open_window(buf, opts)
  local width, height = window_size(opts.width, opts.height)
  local spec = {
    relative = "editor",
    width = width,
    height = height,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    style = "minimal",
    border = "rounded",
    title = (" %s "):format(opts.title),
    title_pos = "center",
  }
  if vim.fn.has("nvim-0.10") == 1 and opts.footer then
    spec.footer = (" %s "):format(opts.footer)
    spec.footer_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, true, spec)
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,FloatTitle:Title"
  return win, width, height
end

local function scratch_buffer(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  return buf
end

local function close(win)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

--- @class agentline.ui.Item
--- @field label string
--- @field status string
--- @field cwd string
--- @field detail string
--- @field disabled boolean|nil
--- @field value any

--- Turns each agent into one real buffer line. Its task and the visual gap
--- beneath it are virtual lines, so Neovim's cursor can only land on agents.
--- @param items agentline.ui.Item[]
--- @param width integer
--- @return string[] lines, integer[] starts, string[] details
function M.render(items, width)
  local lines, starts, details = {}, {}, {}
  local detail_width = math.max(1, width - 4)
  for index, item in ipairs(items) do
    starts[index] = index
    local status = item.status ~= "" and item.status or "unknown"
    local mark = STATUS_MARK[status] or STATUS_MARK.unknown
    local head = (" %s %s%s%s"):format(mark, pad(item.label, 14), pad(status, 11), item.cwd)
    table.insert(lines, truncate(head, width))
    details[index] = "   " .. truncate(item.detail, detail_width)
  end
  return lines, starts, details
end

local function paint_items(buf, items, starts, details)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for index, item in ipairs(items) do
    local group = STATUS_HIGHLIGHT[item.status] or STATUS_HIGHLIGHT.unknown
    vim.api.nvim_buf_add_highlight(buf, namespace, group, starts[index] - 1, 0, -1)
    local virtual = { { { details[index], "Comment" } } }
    if index < #items then
      table.insert(virtual, { { "", "NormalFloat" } })
    end
    vim.api.nvim_buf_set_extmark(buf, namespace, starts[index] - 1, 0, { virt_lines = virtual })
  end
end

--- Opens the agent cards. With `on_pick` they are selectable; without it the
--- window is an informational list.
--- @param items agentline.ui.Item[]
--- @param opts { title: string, empty: string|nil }
--- @param on_pick fun(item: agentline.ui.Item|nil)|nil
--- @return table handle
local function cards(items, opts, on_pick)
  local buf = scratch_buffer("agentline")
  local width = window_size(76, 1)
  local lines, starts, details = M.render(items, width)
  local display_height = #items * 3 - 1
  if #lines == 0 then
    lines = { "", "  " .. (opts.empty or "No agents running"), "" }
    display_height = #lines
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local footer = on_pick and "j/k move · Enter choose · q close" or "j/k move · q close"
  local win = open_window(buf, {
    width = 76,
    height = math.min(display_height, 18),
    title = opts.title,
    footer = footer,
  })
  vim.wo[win].cursorline = #items > 0
  vim.wo[win].cursorlineopt = "line"
  vim.wo[win].wrap = false
  paint_items(buf, items, starts, details)

  local current = 1
  local finished = false

  -- The cursor can move without one of our mappings — most notably when the
  -- user clicks a card. Deriving the item from its row prevents Enter from
  -- choosing the stale Lua index that happened to be selected beforehand.
  local function item_at_cursor()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    for index = #starts, 1, -1 do
      if line >= starts[index] then
        current = index
        return index
      end
    end
    return current
  end

  local function move(step)
    if #items == 0 then
      return
    end
    current = clamp(item_at_cursor() + step, 1, #items)
    vim.api.nvim_win_set_cursor(win, { starts[current], 0 })
  end

  local function finish(item)
    if finished then
      return
    end
    finished = true
    close(win)
    if on_pick then
      on_pick(item)
    end
  end

  local function choose(index)
    if not on_pick or #items == 0 then
      return
    end
    local item = items[index or item_at_cursor()]
    if item.disabled then
      return vim.notify("agentline: " .. item.detail, vim.log.levels.INFO)
    end
    finish(item)
  end

  local map_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "j", function()
    move(1)
  end, map_opts)
  vim.keymap.set("n", "<Down>", function()
    move(1)
  end, map_opts)
  vim.keymap.set("n", "k", function()
    move(-1)
  end, map_opts)
  vim.keymap.set("n", "<Up>", function()
    move(-1)
  end, map_opts)
  vim.keymap.set("n", "gg", function()
    move(1 - current)
  end, map_opts)
  vim.keymap.set("n", "G", function()
    move(#items - current)
  end, map_opts)
  vim.keymap.set("n", "<CR>", function()
    choose()
  end, map_opts)
  for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, function()
      finish(nil)
    end, map_opts)
  end

  if #items > 0 then
    vim.api.nvim_win_set_cursor(win, { starts[1], 0 })
  end
  return {
    buf = buf,
    win = win,
    choose = choose,
    cancel = function()
      finish(nil)
    end,
  }
end

--- @param items agentline.ui.Item[]
--- @param opts { title: string, empty: string|nil }
--- @param on_pick fun(item: agentline.ui.Item|nil)
--- @return table handle
function M.select(items, opts, on_pick)
  return cards(items, opts, on_pick)
end

--- @param items agentline.ui.Item[]
--- @param opts { title: string, empty: string|nil }
--- @return table handle
function M.list(items, opts)
  return cards(items, opts, nil)
end

local function message_height(buf, width)
  local height = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(1, width)))
  end
  return clamp(height + 1, 5, math.max(5, math.floor(vim.o.lines * 0.45)))
end

--- Opens a real buffer rather than a one-line command prompt. Ctrl-S submits;
--- Esc leaves insert mode and q closes without sending.
--- @param opts { title: string|nil }
--- @param on_done fun(answer: string|nil)
--- @return table handle
function M.prompt(opts, on_done)
  local buf = scratch_buffer("markdown")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local win, width = open_window(buf, {
    width = math.min(100, math.floor(vim.o.columns * 0.72)),
    height = 7,
    title = opts.title or "Message to agent",
    footer = "Ctrl-S send · Esc then q cancel",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local finished = false
  local function finish(answer)
    if finished then
      return
    end
    finished = true
    close(win)
    on_done(answer)
  end

  local function submit()
    local answer = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    if answer ~= "" then
      finish(answer)
    end
  end

  local function resize()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_height(win, message_height(buf, width))
    end
  end

  local map_opts = { buffer = buf, silent = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, map_opts)
  vim.keymap.set("n", "q", function()
    finish(nil)
  end, map_opts)
  vim.keymap.set("n", "<Esc>", function()
    finish(nil)
  end, map_opts)
  vim.keymap.set("n", "<C-c>", function()
    finish(nil)
  end, map_opts)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = resize,
  })
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
  end)

  return {
    buf = buf,
    win = win,
    submit = submit,
    cancel = function()
      finish(nil)
    end,
  }
end

return M
