-- rex do <skill>/scripts/alarm.lua in=1200 message="Check the deployment"
-- Use every=1800 to repeat. The target defaults to the calling agent.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local a = rex.args
local seconds = assert(a["in"] or a.every, "use in=SECONDS or every=SECONDS")
assert(seconds > 0 and not (a["in"] and a.every), "use one positive interval")
local message = tostring(assert(a.message, "message is required"))
assert(not message:find("[\r\n]"), "the message must be one line")

if not a.worker then
  local from_session, from_block = lib.me()
  local session, block = a.session or from_session, a.block or from_block
  local header = session == from_session and block == from_block
    and "[alarm you set] "
    or lib.header(lib.whoami(from_session, from_block), "Reply by running: " .. lib.send_command(from_block, "<reply>"))
  lib.attach(session)
  local alarm = lib.call("session.new_block", {
    session_id = session,
    label = "alarm: " .. message:sub(1, 40),
    flavor = "com.superlogical.terminal.shell",
    options = { command = { "rex", "do", "-s", session, "--fail-fast", lib.dir .. "alarm.lua",
      "worker=true", "session=" .. session, "block=" .. block,
      (a.every and "every=" or "in=") .. seconds, "message=" .. header .. message } },
  })
  print("alarm: " .. alarm.block_id)
  return
end

lib.attach(a.session)
local schedule = a.every and rex.every or rex.after
schedule(seconds, function()
  -- submit won't type into a question or permission dialog, which Enter would
  -- answer. An alarm can wait: give the dialog ten minutes to go, then skip
  -- this one. A repeating alarm tries again at its next turn.
  local ok, err = pcall(lib.submit, a.session, a.block, message, 600)
  if not ok then print(os.date("%H:%M:%S ") .. tostring(err)) end
end)
