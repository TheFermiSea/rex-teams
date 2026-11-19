-- List the agents in your Rex session, each with the command that messages it.
--
--   rex do <skill>/scripts/team.lua [host=HOST] [session=SESSION]
--
-- Tabs prefixed with a possibly indented ↳ are subagents. Teammates are the other labeled tabs
-- and panes.
-- With host=, list every session on another Rex server instead (or just
-- SESSION). HOST is a label from `rex hosts` or a server address.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local a = rex.args

-- `dir` marks the far end: lib.remote started this script against HOST, and
-- the commands it prints will run on the machine that asked, from `dir`.
if a.host and not a.dir then
  print(lib.remote(a.host, "team.lua", { host = tostring(a.host), session = a.session and tostring(a.session), dir = lib.dir }))
  return
end

local function list(session, me)
  for _, b in ipairs(lib.blocks(session)) do
    -- What the agent last reported, such as (codex, working), tells a busy or
    -- blocked agent from a free one, and an agent from a plain shell.
    local status = lib.status(session, b.id)
    local doing = status and "  (" .. (status.effective_app and status.effective_app .. ", " or "") .. status.state .. ")" or ""
    print(lib.name(b) .. doing .. "  " .. (b.id == me and "(you)" or lib.send_command(b.id, "<message>", a.host, a.dir)))
    -- Git runs on this machine, so it can't inspect another host's checkout.
    local process = not a.host and rex.call("block.method", { session_id = session, block_id = b.id, method = "process", args = {} })
    local cwd = process and process.foreground and process.foreground.cwd
    local worktree = cwd and lib.worktree(cwd)
    if worktree then
      print("  branch: " .. worktree.branch)
      print("  worktree: " .. worktree.path)
    end
  end
end

if not a.host then
  list(lib.me())
  return
end
lib.far(function()
  for _, s in ipairs(lib.call("session.list").sessions) do
    if not a.session or a.session == s.label or a.session == s.session_id then
      print("session " .. (s.label ~= "" and s.label or s.session_id) .. ":")
      list(s.session_id)
    end
  end
end)
