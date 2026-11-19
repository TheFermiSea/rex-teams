-- Shared by the scripts. Rex runs them with `rex do`,
-- so they need nothing but rex.
local lib = {}

lib.windows = package.config:sub(1, 1) == "\\"
lib.sep = lib.windows and "\\" or "/"
lib.dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])")

-- Rex tells every agent to name its session when its first task arrives.
-- The session and its tabs belong to the user, and tab labels are how agents
-- find each other, so every kickoff and message says this.
lib.rule = "Don't rename the Rex session or your tab."

-- Agent sandboxes usually let programs write to /tmp.
lib.root = (lib.windows and os.getenv("TEMP") or "/tmp") .. lib.sep .. "rex-teams"

function lib.path(...)
  return table.concat({ lib.root, ... }, lib.sep)
end

-- Lua can't make folders, so ask the OS.
function lib.mkdir(path)
  local argv = lib.windows and { "cmd", "/c", "if", "not", "exist", path, "mkdir", path } or { "mkdir", "-p", path }
  assert(assert(rex.exec(argv)).ok, "can't make " .. path)
end

function lib.read(path)
  local f = assert(io.open(path))
  local text = f:read("*a")
  f:close()
  return text
end

function lib.write(path, text)
  local f = assert(io.open(path, "w"))
  assert(f:write(text))
  assert(f:close())
end

function lib.call(method, args)
  return assert(rex.call(method, args))
end

-- Git runs on the machine running this script, like the task files.
function lib.worktree(cwd)
  local opts = { timeout = 2, env = { GIT_DIR = false, GIT_WORK_TREE = false, GIT_COMMON_DIR = false } }
  local r = rex.exec({ "git", "-C", cwd, "rev-parse", "--absolute-git-dir", "--path-format=absolute", "--git-common-dir", "--show-toplevel" }, opts)
  if not r or not r.ok then return end
  local gitdir, common, root = r.stdout:gsub("\r\n", "\n"):match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n$")
  if not root or gitdir == common then return end
  local branch = rex.exec({ "git", "-C", cwd, "symbolic-ref", "--quiet", "--short", "HEAD" }, opts)
  return {
    path = root,
    branch = branch and branch.ok and branch.stdout:gsub("[\r\n]+$", "")
      or (branch and branch.code == 1 and "detached HEAD" or "unknown"),
  }
end

-- The agent running this script.
function lib.me()
  return assert(os.getenv("REX_SESSION"), "run this inside a Rex terminal"), os.getenv("REX_BLOCK")
end

-- A script must attach to a session before it can act on it.
function lib.attach(session)
  lib.call("session.attach", { session_id = session })
end

-- Every block in a session, with its tab and pane labels.
function lib.blocks(session)
  lib.attach(session)
  local out = {}
  for _, window in ipairs(lib.call("session.view", { session_id = session }).windows) do
    local blocks = {}
    for _, layer in ipairs(window.layers) do
      for _, block in ipairs(layer.blocks) do blocks[#blocks + 1] = block end
    end
    for _, block in ipairs(blocks) do
      out[#out + 1] = { id = block.block_id, tab = window.label or "", pane = block.label or "", split = #blocks > 1 }
    end
  end
  return out
end

-- An agent goes by its pane's label in a split tab, and by its tab's label
-- otherwise. Rex labels an unnamed pane "shell".
function lib.name(block)
  if block.split and block.pane ~= "shell" then return block.pane end
  return block.tab
end

-- The status the agent in a terminal last reported (OSC 7501), or nil for a
-- program that reports none. The root record comes first.
function lib.status(session, block)
  local r = rex.call("block.method", { session_id = session, block_id = block, method = "program_status", args = {} })
  return r and r.records and r.records[1]
end

-- Wait up to `seconds` for the terminal to report a state that passes `want`,
-- and return that report, or nil. Rex keeps the events a script hasn't read
-- yet, so a report can't slip by between two calls: this is decided by
-- events, not by sleeping and looking.
function lib.await(block, seconds, want)
  local deadline = os.time() + seconds
  repeat
    local ev = rex.wait("terminal.program_status_changed", { block_id = block }, math.max(deadline - os.time(), 0.05))
    if ev and ev.record and want(ev.record.state) then return ev.record end
  until not ev
end

local function key_enter(session, block)
  for _, action in ipairs({ "press", "release" }) do
    lib.call("block.event", { session_id = session, block_id = block, event = { type = "key", payload = {
      key = "enter", mods = "", consumed_mods = "", text = "\r", unshifted_codepoint = 13, composing = false, action = action,
    } } })
  end
end

-- Paste one line into a terminal, then press Enter. A paste event lets the
-- program tell the text from the Enter that submits it.
function lib.paste_line(session, block, text)
  lib.call("block.event", { session_id = session, block_id = block, event = { type = "paste", payload = { text = text } } })
  key_enter(session, block)
end

-- paste_line for an agent, checked against the status the agent reports.
-- The session must be attached, which is also what makes its events arrive.
-- Returns "started" when the agent began a turn, "queued" when it was already
-- working (its harness holds the message until it can take it), or "sent"
-- when the program reports no status, so nothing can be checked.
--
-- * An agent that is blocked has a question or permission dialog open, and a
--   pasted line with Enter would answer it. Wait up to `patience` seconds for
--   the dialog to go, then fail without typing anything.
-- * The Enter is sometimes lost, and the text sits unsent in the input box
--   while both agents wait. An idle agent that got the Enter reports "working"
--   at once. If no such report comes, press Enter once more: the box still
--   holds the text. The text itself is never pasted again, so nothing can
--   arrive twice.
function lib.submit(session, block, text, patience)
  local function blocked(state) return state == "blocked" end
  local function began(state) return state == "working" or blocked(state) end
  -- Forget reports from before this message, so an old "working" can't vouch for it.
  lib.await(block, 0, function() return false end)
  local before = lib.status(session, block)
  if before and blocked(before.state) then
    before = lib.await(block, patience or 60, function(state) return not blocked(state) end)
    if not before then
      error("not sent: that agent is waiting for its user to answer a question or permission prompt. Try again later.", 0)
    end
  end
  lib.paste_line(session, block, text)
  if not before then return "sent" end
  if before.state == "working" then return "queued" end
  -- A turn that goes straight to a dialog has begun too. Never press Enter into one.
  for attempt, seconds in ipairs({ 4, 8 }) do
    if lib.await(block, seconds, began) then return "started" end
    local now = lib.status(session, block)
    if now and began(now.state) then return "started" end
    if attempt == 1 then key_enter(session, block) end
  end
  error("pasted, but the agent didn't start a turn, even after pressing Enter again. The text may still be in its "
    .. "input box. Don't send it again; look with rex capture, or tell the user.", 0)
end

-- Single quotes keep every character literal in POSIX shells.
function lib.quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- The command that sends a message to a terminal, for pasting into prompts.
-- A full block ID is enough to find the terminal; Rex knows its session.
-- `host` is how the machine that will run the command names the terminal's
-- Rex server, and `dir` is where that machine keeps these scripts.
function lib.send_command(block, message, host, dir)
  return "rex do " .. lib.quote((dir or lib.dir) .. "send.lua") .. (host and " host=" .. lib.quote(host) or "")
    .. " block=" .. lib.quote(block) .. " message=" .. lib.quote(message)
end

-- The name an agent goes by, from its terminal's block ID.
function lib.whoami(session, block)
  for _, b in ipairs(lib.blocks(session)) do
    if b.id == block then return lib.name(b) end
  end
  return "an agent"
end

-- The header that starts every message: who wrote, and how to answer.
function lib.header(from, reply)
  return "[from " .. from .. ", who can't see this screen. " .. lib.rule .. " " .. reply .. "] "
end

-- Find a terminal the way rex -b does: by full ID, the end of an ID, or a
-- block label, in `session` or in every session. Fails with Rex's answer.
function lib.find(block, session)
  local found = lib.call("target.resolve", {
    kinds = { "block" }, queries = { tostring(block) }, scope = session and { session = tostring(session) } or nil,
  }).results[1]
  if found.status ~= "resolved" then
    local choices = {}
    for _, c in ipairs(found.candidates or {}) do choices[#choices + 1] = c.block_id .. " (" .. (c.where or "") .. ")" end
    error("block " .. tostring(block) .. " is " .. tostring(found.status):gsub("_", " ")
      .. (#choices > 0 and ": " .. table.concat(choices, ", ") or "") .. ". Run team.lua to list agents.", 0)
  end
  return found.target.session_id, found.target.block_id
end

-- Other hosts ---------------------------------------------------------------
--
-- A script talks to one Rex server. To act on another host, run the script
-- again with `rex -S HOST`, which takes a label from `rex hosts` or a server
-- address. Reaching the host and proving who you are stay Rex's job: there is
-- no relay and no protocol here.

-- Run one of these scripts against HOST and return what it printed.
function lib.remote(host, script, args)
  local r, err = rex.exec({ "rex", "-S", tostring(host), "do", lib.dir .. script, "--args", rex.json.encode(args) },
    -- This terminal's session doesn't exist on the other server.
    { timeout = 100, env = { REX_SERVER = false, REX_SESSION = false, REX_BLOCK = false } })
  assert(r, err)
  local out = ((r.code == lib.refused and "" or r.stderr) .. r.stdout):gsub("%s+$", ""):gsub("^Error: ", "")
  if r.ok then return out end
  -- The script ran over there and said no, for example to a blocked agent.
  if r.code == lib.refused then error(out, 0) end
  -- Anything else is rex failing to reach HOST, or HOST turning us away.
  error(out .. "\nNothing happened: this machine can't use the Rex server " .. tostring(host)
    .. ". HOST is a label from `rex hosts` or a server address. Rex reaches hosts one way at a time, so check"
    .. " `rex hosts check` here and that the server admits this machine (with built-in Tailscale, it must"
    .. " allow tailnet members). Tell the user; don't retry.", 0)
end

-- The far end of lib.remote: run `fn`, and exit with a status of our own when
-- it fails, so the near end can tell a refusal from an unreachable host.
lib.refused = 3
function lib.far(fn)
  local ok, err = pcall(fn)
  if ok then return end
  print((tostring(err):gsub("^.-%.lua:%d+: ", "")))
  rex.stop(lib.refused)
end

-- How other hosts can name this Rex server: its ID, and its address if it
-- has one that works from another machine.
function lib.address()
  local status = lib.call("server.status")
  local https = status.tailscale and status.tailscale.https
  return status.host_id, https and https.state == "available" and https.url or nil
end

local function bare(endpoint) return (tostring(endpoint):lower():gsub("^%a+://", ""):gsub("/+$", "")) end

-- Where the machine behind a terminal keeps these scripts. Agents install
-- skills under their own folder, and home differs per machine, so ask the
-- terminal. `same` is the sender's own folder, tried last.
function lib.skill_dir(session, block, same)
  local status = lib.status(session, block)
  local tries = { "~/.claude/skills/rex-teams/scripts", "~/.agents/skills/rex-teams/scripts" }
  if status and status.effective_app == "codex" then tries = { tries[2], tries[1] } end
  tries[#tries + 1] = same
  for _, path in ipairs(tries) do
    local dir = rex.call("block.method", { session_id = session, block_id = block, method = "list_dir", args = { path = path, limit = 1 } })
    if dir and dir.status == "ok" then return dir.path:gsub("[/\\]+$", "") .. lib.sep end
  end
end

-- The reply instruction for a message that came from another host. This runs
-- against the receiver's server. The sender is `a.reply_host_id`, reachable at
-- `a.reply_url`. Prefer the label the receiver's server has for it, because
-- that is the route its user set up.
function lib.route_back(session, block, a)
  local host = a.reply_url
  local hosts = rex.call("hosts.list")
  for _, h in pairs(hosts and hosts.hosts or {}) do
    local same = h.host_id and h.host_id == a.reply_host_id
    for _, endpoint in pairs(h.endpoints or {}) do
      same = same or (a.reply_url and bare(endpoint) == bare(a.reply_url))
    end
    if same then host = h.label end
  end
  if not host then
    return nil, "It can't be answered through Rex from this host: the sender's Rex server has no address other machines can reach."
  end
  local dir = lib.skill_dir(session, block, a.reply_dir)
  if dir then return host, "Reply by running: " .. lib.send_command(a.reply_block, "<reply>", host, dir) end
  -- No rex-teams on this machine. Plain rex still reaches the sender.
  local to = "rex -S " .. lib.quote(host) .. " send"
  return host, "Reply by running: " .. to .. " -b " .. lib.quote(a.reply_block) .. " '<reply>' && " .. to .. "-key -b "
    .. lib.quote(a.reply_block) .. " enter"
end

-- Deliver a message on the server this script talks to. send.lua calls it
-- directly for this host, and through deliver.lua and lib.remote for another.
function lib.deliver(a)
  local session, block = lib.find(a.block, a.session)
  lib.attach(session)
  local from, reply = a.from, nil
  if a.reply_host_id then
    local host
    host, reply = lib.route_back(session, block, a)
    from = from .. " on " .. (host and bare(host) or "another host")
  else
    reply = "Reply by running: " .. lib.send_command(a.reply_block, "<reply>")
  end
  return lib.submit(session, block, lib.header(from, reply) .. a.message, a.wait)
end

return lib
