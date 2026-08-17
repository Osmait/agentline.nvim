-- The commands. Kept out of `lua/` so they exist without the plugin having to
-- be required first, which is what makes `:AgentSend` work on a cold start.

if vim.g.loaded_agentline then
  return
end
vim.g.loaded_agentline = true

vim.api.nvim_create_user_command("AgentSend", function(opts)
  require("agentline").send(opts)
end, {
  range = true,
  nargs = "*",
  desc = "Send the selection (or the buffer) to a running coding agent",
})

vim.api.nvim_create_user_command("AgentList", function()
  require("agentline").list()
end, { desc = "Show the coding agents herdr is running" })
