-- Paste a one-line message into another agent's Rex terminal and submit it.
--
--   rex do <skill>/scripts/send.lua [host=HOST] block=BLOCK message='MESSAGE'
--
-- BLOCK is the other agent's terminal: a full block ID, the end of one, or a
-- block label. team.lua prints this command, filled in, for each agent.
-- HOST is another Rex server, named as `rex -S` names it: a label from
-- `rex hosts` or an address. Left out, it means this host. session= narrows a
-- label to one session; a block ID doesn't need it.
-- The message arrives as
--   [from <your name>, who can't see this screen. <rule> Reply by running: <command>] MESSAGE
-- so the other agent knows who wrote and how to answer, even if it has never
-- heard of this skill. Without "can't see this screen", agents tend to answer
-- in their own pane, where nobody reads it. The reply command is written for
-- the receiver's machine: across hosts it carries host=<how to reach you>.
local lib = dofile(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*[/\\])") .. "lib.lua")
local a = rex.args
local usage = "usage: send.lua [host=HOST] block=BLOCK message='MESSAGE'"
local message = tostring(assert(a.message, usage))
assert(a.block, usage)
-- A newline would submit half the message.
assert(not message:find("[\r\n]"), "the message must be one line; put longer text in a file and send its path")

local session, me = lib.me()
local delivery = { block = tostring(a.block), session = a.session and tostring(a.session), message = message,
  wait = tonumber(a.wait), from = lib.whoami(session, me), reply_block = me }
local outcome
if a.host then
  delivery.reply_host_id, delivery.reply_url = lib.address()
  delivery.reply_dir = lib.dir
  outcome = lib.remote(a.host, "deliver.lua", delivery)
else
  outcome = lib.deliver(delivery)
end
print(({
  started = "delivered: the agent started a turn on it",
  queued = "delivered: the agent is busy and will get it when it can take input",
  sent = "sent: that terminal reports no agent status, so delivery wasn't checked",
})[outcome] or outcome)
