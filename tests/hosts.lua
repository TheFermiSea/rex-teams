-- Run from the repo root with `luajit tests/hosts.lua` or `lua5.1 tests/hosts.lua`.
-- Rex is mocked: one fake server holds one terminal, and records what is typed into it.
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local term, hosts, dirs, resolve
local function reset()
  -- state: what program_status answers. events: the status reports rex.wait has yet to hand over.
  term = { state = nil, events = {}, pastes = {}, enters = 0, typed = {} }
  hosts = {}
  dirs = { ["~/.claude/skills/rex-teams/scripts"] = "/home/far/.claude/skills/rex-teams/scripts" }
  resolve = { status = "resolved", target = { session_id = "session:far", block_id = "block:far" } }
end
-- The agent reports a state: Rex stores it and queues the event.
local function report(state)
  term.state = state
  term.events[#term.events + 1] = { block_id = "block:far", record = { state = state, effective_app = term.app } }
end
rex = {
  json = { encode = function(value) return value end },
  wait = function(event, filter, timeout)
    assert(event == "terminal.program_status_changed" and filter.block_id == "block:far" and timeout > 0)
    if #term.events == 0 then
      if term.on_timeout then term.on_timeout() end
      return nil, "timeout"
    end
    return table.remove(term.events, 1)
  end,
  call = function(method, args)
    if method == "target.resolve" then return { results = { resolve } } end
    if method == "session.attach" then return {} end
    if method == "hosts.list" then return { hosts = hosts } end
    if method == "block.event" then
      assert(args.session_id == "session:far" and args.block_id == "block:far")
      if args.event.type == "paste" then
        term.pastes[#term.pastes + 1] = args.event.payload.text
        term.typed[#term.typed + 1] = "paste while " .. tostring(term.state)
      end
      if args.event.type == "key" and args.event.payload.action == "press" then
        term.enters = term.enters + 1
        term.typed[#term.typed + 1] = "enter while " .. tostring(term.state)
        if term.on_enter then term.on_enter(term.enters) end
      end
      return {}
    end
    if method == "block.method" and args.method == "program_status" then
      return { records = { term.state and { state = term.state, effective_app = term.app } } }
    end
    if method == "block.method" and args.method == "list_dir" then
      local path = dirs[args.args.path]
      return path and { status = "ok", path = path } or { status = "not_found" }
    end
    error("unexpected Rex call: " .. method)
  end,
}
local lib = dofile("skills/rex-teams/scripts/lib.lua")
lib.dir = "/Users/near/.claude/skills/rex-teams/scripts/"
-- Deadlines use the clock. Each read of it moves a mock second on, so no trial sleeps.
local now = 0
os.time = function() now = now + 1; return now end

local count = 0
local function check(name, fn)
  reset()
  fn()
  count = count + 1
  print("ok " .. count .. " - " .. name)
end
local function fails(fn, text)
  local ok, err = pcall(fn)
  assert(not ok and tostring(err):find(text, 1, true), "expected failure with: " .. text .. ", got: " .. tostring(err))
end
local near = { block = "block:far", message = "hello", from = "Chief", reply_block = "block:near" }
local function far(extra)
  local a = { reply_host_id = "id-near", reply_url = "https://near.tail1234.ts.net", reply_dir = lib.dir }
  for k, v in pairs(near) do a[k] = v end
  for k, v in pairs(extra or {}) do a[k] = v end
  return a
end

-- Submitting (#40) and not typing into dialogs.
check("an idle agent that starts working is confirmed with one paste and one Enter", function()
  term.state = "done"
  term.on_enter = function() report("working") end
  assert(lib.deliver(near) == "started")
  assert(#term.pastes == 1 and term.enters == 1)
  assert(term.pastes[1] == "[from Chief, who can't see this screen. " .. lib.rule
    .. " Reply by running: rex do '" .. lib.dir .. "send.lua' block='block:near' message='<reply>'] hello")
end)
check("a turn that is over before anyone looks still counts, because events are kept", function()
  term.state = "idle"
  term.on_enter = function() report("working"); report("done") end
  assert(lib.deliver(near) == "started")
  assert(term.enters == 1)
end)
check("a lost Enter is pressed once more, and the text is never pasted twice", function()
  term.state = "idle"
  term.on_enter = function(n) if n == 2 then report("working") end end
  assert(lib.deliver(near) == "started")
  assert(#term.pastes == 1 and term.enters == 2)
end)
check("reports from before the message can't vouch for it", function()
  -- The agent finished a turn just before: its old reports are still queued.
  report("working"); report("done"); report("done")
  term.on_enter = function(n) if n == 2 then report("working") end end
  assert(lib.deliver(near) == "started")
  assert(term.enters == 2, "the stale working report must not hide the lost Enter")
end)
check("an agent that never starts fails loudly after one extra Enter", function()
  term.state = "done"
  fails(function() lib.deliver(near) end, "didn't start a turn")
  assert(#term.pastes == 1 and term.enters == 2)
end)
check("a busy agent gets the message queued, with no second Enter", function()
  term.state = "working"
  assert(lib.deliver(near) == "queued")
  assert(#term.pastes == 1 and term.enters == 1)
end)
check("a terminal that reports no status is sent to as before", function()
  assert(lib.deliver(near) == "sent")
  assert(#term.pastes == 1 and term.enters == 1)
end)
check("nothing is typed into a blocked agent's dialog", function()
  term.state = "blocked"
  fails(function() lib.deliver(far({ wait = 3 })) end, "not sent: that agent is waiting for its user")
  assert(#term.typed == 0)
end)
check("a dialog that closes in time lets the message through, typed only after it closed", function()
  term.state = "blocked"
  term.on_timeout = function() term.on_timeout = nil; report("idle") end
  term.on_enter = function() report("working") end
  assert(lib.deliver(near) == "started")
  assert(table.concat(term.typed, ", ") == "paste while idle, enter while idle", table.concat(term.typed, ", "))
end)
check("an agent that goes from idle straight to a dialog gets no second Enter", function()
  term.state = "idle"
  term.on_enter = function() report("blocked") end
  assert(lib.deliver(near) == "started")
  assert(term.enters == 1)
  reset()
  -- Even if the report of the dialog was missed, the stored status stops the second Enter.
  term.state = "idle"
  term.on_enter = function() term.state = "blocked" end
  assert(lib.deliver(near) == "started")
  assert(term.enters == 1)
end)

-- Finding the terminal (#29).
check("an unknown or ambiguous block fails with Rex's answer and types nothing", function()
  resolve = { status = "not_found" }
  fails(function() lib.deliver(near) end, "block block:far is not found")
  resolve = { status = "ambiguous", candidates = { { block_id = "block:1", where = "window 1 of a" }, { block_id = "block:2", where = "window 2 of b" } } }
  fails(function() lib.deliver(near) end, "is ambiguous: block:1 (window 1 of a), block:2 (window 2 of b)")
  assert(#term.pastes == 0)
end)

-- The way back (#31). These run as the receiver's server sees them.
local function reply_of(a)
  lib.deliver(a)
  return term.pastes[1]
end
check("with no host entry for the sender, the reply goes to its address", function()
  local text = reply_of(far())
  assert(text:find("[from Chief on near.tail1234.ts.net, who can't see this screen.", 1, true), text)
  assert(text:find("Reply by running: rex do '/home/far/.claude/skills/rex-teams/scripts/send.lua'"
    .. " host='https://near.tail1234.ts.net' block='block:near' message='<reply>'] hello", 1, true), text)
end)
check("the receiver's own label for the sender wins, matched by host ID or by address", function()
  hosts = { { label = "other", endpoints = { "https://other.ts.net" } }, { label = "studio", host_id = "id-near", endpoints = { "unix:///tmp/fwd.sock" } } }
  assert(reply_of(far()):find(" host='studio' block='block:near'", 1, true))
  reset()
  hosts = { { label = "laptop", endpoints = { "near.tail1234.ts.net/" } } }
  local text = reply_of(far())
  assert(text:find("[from Chief on laptop,", 1, true) and text:find(" host='laptop' ", 1, true), text)
end)
check("the reply command uses the folder of the receiving agent's own harness", function()
  dirs["~/.agents/skills/rex-teams/scripts"] = "/home/far/.agents/skills/rex-teams/scripts/"
  term.app = "codex"
  term.state = "working"
  assert(reply_of(far()):find("rex do '/home/far/.agents/skills/rex-teams/scripts/send.lua' host=", 1, true))
  reset()
  dirs = { [lib.dir] = lib.dir }
  assert(reply_of(far()):find("rex do '" .. lib.dir .. "send.lua' host=", 1, true), "the sender's folder is the last resort")
end)
check("without rex-teams on the receiver, the reply command is plain rex", function()
  dirs = {}
  local text = reply_of(far())
  assert(text:find("Reply by running: rex -S 'https://near.tail1234.ts.net' send -b 'block:near' '<reply>' && "
    .. "rex -S 'https://near.tail1234.ts.net' send-key -b 'block:near' enter] hello", 1, true), text)
end)
check("a sender nobody can reach says so instead of printing a dead command", function()
  local text = reply_of(far({ reply_url = false }))
  assert(text:find("[from Chief on another host,", 1, true), text)
  assert(text:find("It can't be answered through Rex from this host", 1, true) and not text:find("Reply by running", 1, true))
end)

-- lib.remote: routing with `rex -S`, and telling a refusal from an unreachable host.
check("another host is reached with rex -S and this terminal's session left out", function()
  local seen
  rex.exec = function(argv, opts)
    seen = { argv = argv, env = opts.env }
    return { ok = true, code = 0, stdout = "started\n", stderr = "" }
  end
  assert(lib.remote("studio", "deliver.lua", { block = "b" }) == "started")
  local argv = seen.argv
  assert(argv[1] == "rex" and argv[2] == "-S" and argv[3] == "studio" and argv[4] == "do" and argv[5] == lib.dir .. "deliver.lua")
  assert(argv[6] == "--args" and argv[7].block == "b")
  assert(seen.env.REX_SESSION == false and seen.env.REX_BLOCK == false and seen.env.REX_SERVER == false)
end)
check("a refusal from the far end is passed on as it is", function()
  rex.exec = function() return { ok = false, code = lib.refused, stdout = "not sent: that agent is waiting\n", stderr = "noise" } end
  local ok, err = pcall(lib.remote, "studio", "deliver.lua", {})
  assert(not ok and err == "not sent: that agent is waiting", tostring(err))
end)
check("an unreachable or refusing host is named, never retried on this host", function()
  local calls = 0
  rex.exec = function()
    calls = calls + 1
    return { ok = false, code = 1, stdout = "", stderr = "Error: server refused the connection: forbidden\n" }
  end
  local ok, err = pcall(lib.remote, "studio", "deliver.lua", {})
  assert(not ok and calls == 1)
  assert(err:find("^server refused the connection: forbidden\nNothing happened: this machine can't use the Rex server studio"), err)
end)
check("the far end reports a failure on stdout with its own exit status", function()
  local printed, stopped = {}, nil
  local real_print = print
  print = function(line) printed[#printed + 1] = line end
  rex.stop = function(code) stopped = code end
  lib.far(function() error("not sent: reason", 0) end)
  lib.far(function() assert(false, "plain failure") end)
  print = real_print
  assert(stopped == lib.refused and printed[1] == "not sent: reason" and printed[2] == "plain failure", table.concat(printed, "|"))
end)

-- The whole trip: the header one host writes must run on the other.
check("a cross-host reply command survives /bin/sh with hostile names", function()
  local tmp = os.tmpname()
  os.remove(tmp)
  assert(os.execute("mkdir -p " .. quote(tmp .. "/bin")) == 0)
  local f = assert(io.open(tmp .. "/bin/rex", "w"))
  f:write('#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done\n')
  f:close()
  dirs["~/.claude/skills/rex-teams/scripts"] = "/home/it's $HOME `x`/scripts"
  hosts = { { label = "it's $(touch " .. tmp .. "/canary)", host_id = "id-near" } }
  local command = assert(reply_of(far()):match("Reply by running: (.*)%] hello$"))
  local script = assert(io.open(tmp .. "/cmd.sh", "w"))
  script:write(command .. "\n")
  script:close()
  assert(os.execute("chmod +x " .. quote(tmp .. "/bin/rex") .. " && PATH=" .. quote(tmp .. "/bin") .. ':"$PATH" /bin/sh '
    .. quote(tmp .. "/cmd.sh") .. " >" .. quote(tmp .. "/out")) == 0)
  local out = assert(io.open(tmp .. "/out")):read("*a")
  assert(out == "do\n/home/it's $HOME `x`/scripts/send.lua\nhost=it's $(touch " .. tmp .. "/canary)\nblock=block:near\nmessage=<reply>\n", out)
  assert(not io.open(tmp .. "/canary"), "the shell ran text from the command")
  os.execute("rm -rf " .. quote(tmp))
end)
print("Passed " .. count .. " delivery and host routing trials.")
