# Security

How Bandito keeps agents from doing harm, in plain words. Agents work on your server with the rights of the user
they run as. Bandito checks each action of an agent before it runs: routine work goes on by itself, and risky
actions wait for your yes. Read the limits below too: this is a safety net, not a wall.

## Approval modes (Ask me about)

<!-- id: sec-modes; covers: settings:approvals -->
Each agent has one mode that decides when it asks you. The mode is set when the agent is created and can be changed later.
Где: Team → agent → Agent details (⌘I) → Details → Approvals (Одобрения); New agent sheet → Ask me about (Что спрашивать у вас)
1. Risky only (Только рискованное), the default: routine work goes on by itself; actions in the risky list below are asked about.
2. Everything (Всё подряд): every tool call that the CLI asks about goes to you.
3. Nothing (Ничего): the agent runs without asking. Use it only for a sandbox you do not care about.

## Approval card (Needs you)

<!-- id: sec-card; covers: -->
When an action is asked about, the agent stops and an approval card appears in its thread. The agent does not go on until you answer. Approvals that are not answered in 24 hours are denied.
Где: Team → agent thread → approval card (Needs you)
1. Read the agent name, the action, and the command or diff.
2. Click Approve (Разрешить) to allow it, or Deny (Отклонить) to refuse it. A long command asks you to open Bandito and review it.
3. Tick Always allow this here (Всегда разрешать здесь) to allow this exact command for this agent from now on. Other commands still ask.
4. You can also answer from the menu bar, from a notification, or from the iPhone app.

## Rules: allow, ask, deny (Approvals)

<!-- id: sec-rules; covers: -->
Your own rules for the agents, set in Settings. A rule matches a command pattern and says what to do: Allow (Разрешить), Ask (Спрашивать) or Deny (Отклонить). Rules apply on the server.
Где: Settings (⌘,) → Approvals (Одобрения) → New rule (Новое правило)
1. Type the pattern, for example terraform plan*. The * means anything.
2. Pick Allow, Ask, or Deny, and For (Для кого): All agents or one agent.
3. Click Add (Добавить). If two rules match, the rule for one agent wins, then the newer rule.
4. A rule can never allow the protected actions listed below. The built-in checks always apply.

## Actions that are always refused (Protected)

<!-- id: sec-protected; covers: -->
Bandito's own files and controls are off limits for agents in every mode, and no rule can allow them. The agent gets the message: Bandito's own files and controls are off limits to agents.
Где: Any mode → the agent's command is refused
1. Refused: reading or changing Bandito's data folder (~/.bandito), its program, and its service files.
2. Refused: stopping or restarting Bandito itself (for example killing its process or disabling its service).
3. This covers paths that the agent writes in a different way, such as variables or ~ tricks: they are followed when Bandito can work them out.

## Asked, not allowed silently (Can't check)

<!-- id: sec-unclear; covers: -->
A command that Bandito cannot read in full is asked about, never allowed on its own. For example, a command with a variable that is not set, a command that runs code from a string, or a folder that cannot be worked out.
Где: Team → agent thread → approval card, reason: can't check: … (can't check)
1. Read the reason on the card. If the command is safe, approve it. If you are not sure, deny it.

## The risky list (risky: …)

<!-- id: sec-risky; covers: -->
Actions that are asked about in Risky only and Everything. The reason on the card says which rule matched, for example risky: git push.
Где: Team → agent thread → approval card, reason: risky: … (risky: …)
1. Pushes and history rewrites in git: git push, reset --hard, clean -f, branch -D, checkout of files.
2. Deleting many files at once: rm -r, find -delete, shred, chmod -R, chown -R.
3. Publishing a package (npm publish, cargo publish) and deploys (a script named deploy…, vercel --prod, fly deploy).
4. Changes in clusters and infrastructure: kubectl delete or apply, helm upgrade, terraform apply or destroy, docker volume rm.
5. Deleting data in a database: DROP TABLE, TRUNCATE, DELETE FROM.
6. Shutdown and reboot, system services and cron jobs, user accounts (useradd, passwd, visudo).
7. Sending data out: curl with a body or upload, scp, rsync to another host, ssh with a command.
8. Writing outside the agent's project folder (asked as writes outside <folder>).

## Browser steps (Pay, Send, Delete, Sign in)

<!-- id: sec-browser; covers: -->
In the browser, some clicks are asked about even in Risky only: a payment (Pay, Buy), sending a form (Send), deleting on a site (Delete), and signing in with a password.
Где: Settings (⌘,) → Approvals (Одобрения) → Built-in checks → In the browser and on the screen (В браузере и на экране)
1. Read the step on the approval card. Deny a payment you did not expect.

## Secrets (Секреты)

<!-- id: sec-secrets; covers: -->
Keys and passwords for the agents are kept on the server. An agent gets each one as an environment variable. Values are never shown in the chat, and only the last four characters are visible after saving.
Где: Server → Secrets (Секреты) → Add secret (Добавить секрет)
1. Add a key and choose which agents get it. Use All agents (Все агенты) only for keys the whole team may use.
2. To remove a secret, click Delete (Удалить). The agents that had it restart without it.

## Workplaces: shared, separate user, container

<!-- id: sec-workplaces; covers: -->
Where an agent works decides what it can touch. Shared (Общее) is the only choice in this build: the agent works as the server user, with the same files and browser as you. Separate user (Отдельный пользователь) and Container (Контейнер) are planned.
Где: Server → Workplaces (Рабочие места) → How to choose (Как выбрать)
1. Shared: quick and simple. Fine when you trust the agent and the team.
2. Separate user: the agent gets its own files, browser and screen, and the server itself is shared. Not in this build.
3. Container: full isolation with its own disk, network, and CPU and memory limits, in Docker or Podman. For experiments and code you do not trust. Not in this build; Containers (Контейнеры) on the Server shows whether Docker or Podman is installed.

## Sandbox

<!-- id: sec-sandbox; covers: ; status: planned -->
A sandbox is a place where an agent cannot reach your files, network or other agents. In this build there is no sandbox for the agents: Shared is the only workplace, and the approvals are the safety net. Use a separate server or a container for work you do not trust.
Где: New agent sheet → Workplace (Рабочее место) → Container (Контейнер)
1. Until containers ship, do not give an agent access to a server that holds data you cannot lose.

## What the approvals do not stop (limits)

<!-- id: sec-limits; covers: -->
The risky checks read the command line. They stop a mistake. They do not stop an agent that tries to get around them: a script, an interpreter or a link can reach files that the check does not follow. A real boundary is a separate user or a container.
Где: Team → agent → Agent details → Details → Approvals (Одобрения)
1. Keep the agents' rights small: a separate user on the server for each agent, and no keys you do not need.
2. Keep Risky only (Только рискованное) or Everything (Всё подряд) on for agents that touch production.
3. The checks look at the actions the agent asks for: the tool, the command text and the paths. They do not look inside a program the agent wrote and runs (a script, `npm test`, a build script, a git hook). Such a program can read whatever the server user can read. For real isolation use a container.
## Touch ID and auto-deny (planned)

<!-- id: sec-touchid; covers: ; status: planned -->
Two safety features are planned, not in this build: Touch ID (or Face ID) for pushes to main, deploys and deletions, and an automatic denial after 30 minutes without an answer. Settings → Approvals shows no switch for either.
Где: Settings (⌘,) → Approvals (Одобрения)
1. Answer approvals in time. The request waits up to 24 hours before it is denied.

