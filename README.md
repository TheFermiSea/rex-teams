# Rex Teams

![Claude starts three subagents in Rex, and they run side by side](media/hero.webp)

Run subagents inside Superlogical's [Rex terminal](https://rex.superlogical.com), across agent harnesses. Rex Teams lets a parent agent spawn Claude Code, Codex, Pi, OpenCode, or other agent CLIs in background tabs, receive their reports, and close completed tabs.

The skill also lets agents message long-running teammates and set one-time or recurring alarms.

This is an unofficial community skill. It isn't made by or affiliated with Superlogical, so please report bugs here, not to Rex.

> [!TIP]
> I expect Rex to do this better itself one day. When it does, delete the skill.

Rex already gives agents everything this skill needs: tabs, `rex send`, and `rex capture`. `rex-teams` just adds the habits on top. It sets out how a subagent reports back, and it starts every message with the command for replying. A message is typed into the other agent's terminal, which starts its next turn, so nobody polls.

## Install

```sh
npx skills add campfireshuffle/rex-teams
```

## Usage patterns 

### Subagents

Ask your agent:

> Have Codex review this diff and Pi check the docs, then merge their findings.

Parallel coding agents use separate Git worktrees. Their tabs show `↳ task (w)`; launch output and the team listing show the branch and checkout path without crowding the tab. Parents handle integration and cleanup. Closing a tab leaves the worktree intact.

### Teammates (Grok Bot style)

Open agents in labeled tabs or panes, then talk to one:

> Hi Chief, ask Marketer to create a launch video for my product. 

### Across machines

Agents on different Rex servers message each other with `host=`, which takes what `rex -S` takes: a label from `rex hosts` or a server address.

> Ask the Codex agent on studio whether the migration has finished.

```sh
rex do <skill>/scripts/team.lua host=studio
rex do <skill>/scripts/send.lua host=studio block=<block ID> message='<message>'
```

The skill has to be installed on both machines. Each message's header carries a reply command written for the receiving machine: that machine's path to the skill, and `host=` set to the receiver's own label for the sender, or else the sender's address. Reaching the other server, and being allowed in, is all Rex: the scripts run themselves again with `rex -S HOST`, with no relay or daemon. Replies need Rex to work in both directions, so each server must admit the other (with built-in Tailscale, both must allow tailnet members).

### Set alarms

> Check in on the Marketer agent in 20 minutes.

> Every 10 minutes, check CI on my PR and stop once it's green.

## Limitations

- If you're typing in a pane when a message lands, the message mixes into your draft. Rex doesn't expose a terminal's unsent input, so the scripts can't see a draft, and guessing from focus or the screen was too flaky to ship.
- Delivery is checked through the status an agent reports to Rex (OSC 7501, which Claude Code and Codex send). A message is never typed into an agent that is blocked on a question or permission prompt, and a lost Enter is pressed once more. For a program that reports no status, or a message queued behind a running turn, nothing is checked.
- Across machines, only messages and team listings travel. Subagents, task files and alarms stay on one host, and a reply needs the receiving machine to be allowed onto the sender's Rex server.
- A subagent that crashes before reporting wakes nobody.
- Alarms stop if the Rex server restarts.
- Tested with Rex 0.1.0 (beta), Claude Code 2.1, Codex CLI 0.166, Pi 1.5 and OpenCode 2.2.
