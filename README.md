# agent-send.nvim

Select some lines, ask a question, and it goes to a coding agent that is
already running.

```
:'<,'>AgentSend
Ask the agent: why does this deadlock?
Send to: claude · sbql   Verificar si cambios están en main
```

The agent receives the question, where the lines are, and the lines
themselves — tagged with the buffer's filetype so they arrive as code.

## What it needs

[herdr](https://herdr.dev) on your `PATH`, with a server running. That is
where the agents live; this plugin only talks to it. Nothing else is required,
and nothing is installed alongside it.

## Install

With lazy.nvim:

```lua
{
  "Osmait/agent-send.nvim",
  keys = {
    { "<leader>aa", ":AgentSend<cr>", mode = "v", desc = "Ask an agent about this" },
    { "<leader>al", "<cmd>AgentList<cr>", desc = "Agents running" },
  },
  opts = {},
}
```

`opts = {}` is enough; the defaults below are the whole configuration.

## Commands

| Command | What it does |
|---|---|
| `:'<,'>AgentSend` | asks for a question, then sends the selection |
| `:'<,'>AgentSend why is this slow?` | sends it without asking |
| `:AgentSend` | no range, so the whole buffer |
| `:AgentList` | shows what is running, sends nothing |

## What actually travels

**The buffer, not the file on disk.** What is on screen is what you are asking
about, and it is routinely a few keystrokes ahead of what has been written out.
Sending the saved copy would answer a question nobody asked.

**An absolute path, and the text.** An agent working in a git worktree or
another checkout cannot resolve `src/foo.rs` the way your editor does, so it
gets both the location and the lines themselves.

**Up to `max_lines`.** Past that the message says how much was cut rather than
quietly sending a fraction — an agent that cannot tell it got half of something
will reason confidently about the half it has.

## Where it goes

The agents that can take work are offered first; the ones that cannot are
**listed with the reason** rather than hidden, because "all of them are busy"
is a more useful answer than "none found".

An agent is refused when it is:

- **working** — typing into it mid-task loses its context;
- **blocked** — it is stopped on a permission prompt and would read your
  question as the answer to that prompt;
- **unknown** — not knowing is not permission.

With exactly one free agent it does not ask. With several it asks once and
remembers, so a second question goes to the same place; set
`remember_target = false` to be asked every time.

## Configuration

```lua
require("agent-send").setup({
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
})
```

The placeholders are `{prompt}`, `{path}`, `{range}`, `{filetype}` and
`{text}`. One this plugin does not recognise is left as itself, so a typo in
your template looks like a typo instead of vanishing.

Substitution goes through a function rather than a replacement string on
purpose: Lua reads `%1` and friends inside a `gsub` replacement, and source
code is full of `%`. A `printf("%d%%")` would otherwise arrive mangled, which
is the sort of bug that only shows up in the one line you most wanted the agent
to look at.

## Tests

```sh
nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/run.lua"
```

No framework — the plugin is small enough that one would be more code than the
thing it tests. The last few run against whatever herdr is actually running, so
they check the JSON is parsed and every agent has a pane that can be addressed.

## A note on the envelope

herdr wraps its answers, and prints the *failure* envelope on stdout with a
zero exit status. A call that went wrong looks exactly like one that went right
until the envelope is opened, so nothing here trusts the exit status alone.
