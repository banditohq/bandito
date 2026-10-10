# Team (Команда)

The Team mode is the main place: your agents in a sidebar, one chat per agent in the middle, and the workbench panel
on the right. The panel holds the agent's details, its terminal, the browser, files and the changes, so you do not
leave the chat for them. Open the Team mode with ⌘1 or the Team (Команда) button in the mode bar.

## Team mode

<!-- id: team-mode; covers: mode:team -->
The window has three parts: the sidebar with agents (Pinned, NEEDS YOU, TEAM), the thread of the selected agent, and the workbench panel on the right that you open on demand (see "Workbench panel" below).
Где: Mode bar → Team (Команда), or Menu View → Team (Команда)
1. Press ⌘1 or click Team (Команда) in the mode bar.
2. Click an agent in the sidebar to open its chat. The selection is kept when you switch to another mode and back.
3. Click the agent name at the top of the thread, or press ⌘I, to show the agent's details in the panel.

## Workbench panel (Панель)

<!-- id: team-workbench; covers: -->
A panel beside the chat with tabs: Details (the agent's name), Terminal (a terminal of the server in the agent's folder), Browser, a file or a folder of the server (the memory files open this way), and What changed. Each agent has its own tabs; they stay when you switch agents or modes. The terminal tab is the same terminal as in the Terminals mode, so it is shown in one place at a time: where it is not on show, the panel says where it is and offers Show here (Показать здесь).
Где: Team → chat header → the panel button (sidebar icon) or ⌘J; the + button in the panel adds a tab
1. Press ⌘J, or click the panel button in the chat header, to open the panel. Press ⌘J again to close it.
2. Click + to add a tab: New terminal, Browser, Changes or Details. The new tab goes to the pane you are in.
3. Click the square-split button to split the panel into two panes, one above the other. Drag the line between them to change their sizes, or double-click it to make them even. Right-click a tab and choose Move to the other pane (Переместить в другую панель) to move it.
4. Drag the left edge of the panel to make it wider or narrower; double-click the edge to return to the default width.
5. Close a tab with its × or ⌘⌥W. Close the panel with its × button. Pick a tab with ⌘⌥1…9.
6. When the agent starts using its browser, the chat header shows "The agent is using the browser · Show". Click Show to open the browser tab; the tab is never opened by itself.
7. If a terminal could not open, the panel says why above the tabs. A closed terminal tab offers Open a new one.

## Agent status dots

<!-- id: team-status; covers: -->
Each agent has one status. Agents that need you are sorted to the top and get the orange dot.
Где: Team → sidebar → agent row
1. Idle (ждёт задачу): nothing running, no decision needed.
2. Working (работает): a turn is running.
3. Needs you (ждёт вас): an approval is waiting, or the agent asked a question. The orange dot appears.
4. Error (Ошибка): the agent stopped because of a failure. A banner gives the reason and Retry (Повторить).
5. Offline (Не в сети): the server is not reachable.
## Sidebar: pin, delete, pause

<!-- id: team-sidebar-menu; covers: -->
Pinned agents are listed at the top. The context menu of an agent has Pin (Закрепить) or Unpin (Открепить), Pause (Приостановить) or Resume (Продолжить), and Delete… (Удалить…). A paused agent shows a pause mark next to its name, and its avatar sleeps.
Где: Team → sidebar → agent → right click
1. Right-click an agent and choose Pause (Приостановить). The mark appears and the avatar goes to sleep.
2. Right-click it again and choose Resume (Продолжить) to bring it back.
## Pause (Приостановить)

<!-- id: team-pause; covers: -->
A paused agent keeps its chat and its memory and starts no work. A message you send to it appears in the chat at once and waits there; it runs when you resume the agent. Pausing also stops the turn that is running, as Stop agent (⌘.) does. Scheduled runs of a paused agent are skipped.
Pause all agents (Пауза для всех агентов) pauses every agent of the server at once, or resumes them all when they are all paused.
Где: Team → Inspector (⌘I) → State (Состояние) → Pause (Приостановить); Agent menu → Pause all agents (Пауза для всех агентов); the composer → /pause
1. Open the Inspector with ⌘I and find State (Состояние). Click Pause (Приостановить); the state reads Paused (На паузе).
2. To pause every agent, press ⌘⇧P or choose Agent → Pause all agents. Choose it again to resume them all.
3. To resume one agent, click Resume (Продолжить) in the same place.
4. On a server with an older Bandito the pause items are disabled (see [troubleshooting.md](troubleshooting.md)).

## Team home (⌘0)

<!-- id: team-home; covers: -->
The screen shown in the Team mode when no chat is open: a greeting with the raccoon, the New agent (Новый агент) button, the six agents used last (each with its status: working, waiting or asleep, and the time of its last event), the templates and a few ideas for what to hand off. The last message of an agent shows as one plain line. The templates start with the built-in ones; on a server with Bots in the Marketplace they are the first five bots of the Marketplace, then From scratch (С нуля), and All bots in the marketplace (Все боты в маркетплейсе →) opens the Bots page.
Где: Sidebar → TEAM (КОМАНДА) label; ⌘0; swipe right with two fingers in a chat
1. Click the TEAM label above the agents, press ⌘0, or swipe right with two fingers in a chat.
2. Click New agent, or a template, to open the New agent sheet; a bot tile opens the create sheet of that bot in the Marketplace; click an agent to open its chat.
3. Swipe left with two fingers to return to the chat you left.

## Search and quick open (⌘K)

<!-- id: team-quick-open; covers: -->
A palette with agents, files, terminals, ports and actions. Type to filter; arrow keys move; the palette shows what is found.
Где: Sidebar → Search (⌘K) (Search (⌘K)), or Menu Go → Quick open (Быстрый переход)
1. Press ⌘K. Type an agent name, a file, a terminal or a command, for example "pause" or "terminal".
2. Use ↑↓ to choose (↑↓ select), then ↵ to open (↵ open). ⌘↵ sends a message to the agent (⌘↵ message).
3. Press Esc to close the palette.

## Write a message

<!-- id: team-composer; covers: -->
The composer sits at the bottom of the thread. It sends the message to the selected agent and shows the reply as it arrives.
Где: Team → agent thread → composer (Message {name})
1. Click in the field and type. Press ↵ to send (↵ send). Press ⇧↵ for a new line (⇧↵ new line).
2. While the agent is working, the send button becomes Stop (Остановить). Press ⌘. to stop the turn (⌘. stop).
3. A message you send while the agent is busy, or saving its memory before a new chapter, appears in the chat at once with the line Queued (В очереди) below it. The line goes away when the agent takes the message. If the agent stopped or the server restarted before it did, the line reads Not delivered (Не доставлено); right-click the message and choose Send again (Отправить снова). After a new chapter begins, the message sits below the chapter divider, where the agent reads it. The counter beside Thinking… counts from the start of the current turn.

## Attach a file to a message

<!-- id: team-attach; covers: -->
Attach files, pictures and screenshots to the composer. They upload to the agent's attachment folder and go out with your next message. Drop files anywhere in the chat, or paste a picture with ⌘V when the clipboard holds no text. Folders and web links are not attached. Pictures show in the thread; click one to see it full size: pinch, or ⌘= and ⌘- (⌘ with the scroll wheel too) to zoom, double-click to switch between fit and 100% at the click, drag a zoomed picture to move it, ← and → for the other pictures of the message, Esc to close. The + button is off when the server is too old to take attachments.
Где: Team → agent thread → composer → +
1. Click +. Choose File or picture…, Screenshot or From clipboard.
2. Wait until the file stops showing Uploading…. A file that cannot be attached shows why (for example, Over 20 MB) and is not sent; remove it with ✕.
3. Press ↵. The files leave the composer with the message.

## Slash commands (/)

<!-- id: team-slash; covers: -->
Typing / in the composer opens a list of commands. Four sources are merged and can be filtered: Server (the CLI's own commands and skills), From Mac (commands from ~/.claude on this Mac), Bandito (built-in), and Mine (your snippets).
Где: Team → agent thread → composer → type /
1. Type / and read the list. Use ↑↓ to choose (↑↓ select), ↵ to run (↵ run), or ⇥ to complete the name (⇥ complete).
2. Use the filters All (Все), Server (Сервер), From Mac (С Mac), Bandito (Bandito), Mine (Мои) to narrow the list.
3. A command from This Mac that is not on the server yet asks Install /name on the server? (Install /name on the server?). Click Install and send (Установить и отправить): the command is copied once, then the message is sent.
4. The Bandito commands also answer to words in the language of the app: in Russian, /модель finds /model and /усилие finds /effort. The English name always works, case and accents do not matter.

## Mentions (@)

<!-- id: team-mentions; covers: -->
Type @ after a space to point the agent at something: a service (SERVICES), a teammate (AGENTS), a file or folder of the agent's project (FILES), or an open tab of the server's browser (BROWSER). The pick leaves @Name in the message and a chip above the field; the agent reads a short note of what each one is. The message in the thread shows the chips under it. A service that is not connected is marked Connect (Подключить). Search finds the name, the English name and the words of the group (@сервисы, @files).
Где: Team → agent thread → composer → type @
1. Type @ and a few letters. Use ↑↓ to choose (↑↓ select), ↵ to insert (↵ insert), ⇥ to complete (⇥ complete), Esc to close.
2. The chip appears above the field. Click ✕ on it, or press Backspace right after @Name, to take it away with its words.
3. A service that is not connected asks Connect Linear? (Connect {name}?) above the field. Click Connect: the sign-in opens in the browser, or the sheet of keys, as in the Marketplace. The message goes by itself when the service is connected.
4. A server older than this build sends the words only, without the chips.

## /new

<!-- id: team-slash-new; covers: -->
Opens the New agent sheet. Same as ⌘N.
Где: Team → agent thread → composer → /new (New agent)
1. Type /new and press ↵.

## /model and /effort

<!-- id: team-slash-model-effort; covers: -->
Change the model and the effort of the selected agent for the next messages. Without an argument, /model asks you to name a model (Name a model, for example /model opus). /effort takes low, medium, high, xhigh or max, and only the levels that the runtime offers.
Где: Team → agent thread → composer → /model <name>, /effort <level>
1. Type /model opus (or another model name the CLI accepts) and press ↵. The new model applies to the next messages.
2. Type /effort high and press ↵. If the runtime does not offer that level, the note says so (does not offer the level).
3. The same settings are in the inspector: Details → Model and Effort.

## /memory, /changes, /terminal, /files, /usage

<!-- id: team-slash-open; covers: -->
Five commands that open other places for the selected agent.
Где: Team → agent thread → composer → /memory, /changes, /terminal, /files, /usage
1. /memory opens the inspector on the Memory tab (see "Memory tab" below).
2. /changes opens What changed in the workbench panel (see "What changed" above).
3. /terminal opens the agent's terminal in the workbench panel, the same as the terminal button in the chat header: the terminal in the project folder, or a new one there.
4. /files opens the Files mode in the agent's project folder.
5. /usage opens the Subscription limits popover.
## /pause

<!-- id: team-slash-pause; covers: -->
Typing /pause in the composer pauses the agent, or resumes it when it is paused. It does the same as the State switch in the Inspector (see Pause above). /chapter is not in the list in this build: the chapter settings are in the Inspector, Memory tab.
Где: Team → agent thread → composer → /pause
1. Type /pause and press Return. The state changes at once.

## My snippets

<!-- id: team-snippets; covers: -->
A saved prompt with parts to fill in. The parts are in curly braces, for example `{project}`. The cursor goes to the first part when the snippet is inserted.
Где: Team → agent thread → composer → / → + New snippet (+ New snippet)
1. Type / and click + New snippet (+ New snippet).
2. Type the name (for example standup) and the text. Put the parts in curly braces.
3. Save. The snippet appears in the list under My snippets (MY SNIPPETS).

## Approvals in the thread

<!-- id: team-approval; covers: -->
When an agent wants to run a risky command, an approval card appears in the thread with the agent name, the action, and the command or diff. The agent waits until you answer. See [security.md](security.md) for which actions are asked about.
Где: Team → agent thread → approval card (Needs you)
1. Read the command. Long commands show a note to open Bandito to review them.
2. Click Approve (Разрешить) or press ↵ to allow it, or Deny (Отклонить) or press Esc (⎋) to refuse it.
3. Tick Always allow this here (Всегда разрешать здесь) before you approve to keep the exact command allowed for this agent. Another command still asks.
4. The answered card shrinks to a line: Allowed by you · just now (Allowed by you · just now), Denied by you (Denied by you · just now), Allowed by a rule (Разрешено правилом), or Denied by a rule (Запрещено правилом).

## Go to who needs you (К тому, кто ждёт вас)

<!-- id: team-needs-you; covers: -->
Jumps to the first agent that waits for you.
Где: Menu Go → Go to who needs you (К тому, кто ждёт вас)
1. Press ⌘⇧A, or choose the menu item. The agent that needs you opens. If nobody waits, nothing happens.

## Previous and next agent

<!-- id: team-prev-next; covers: -->
Steps through the agents in the sidebar order.
Где: Menu Go → Previous agent (Предыдущий агент) / Next agent (Следующий агент)
1. Press ⌥⌘↑ for the previous agent, ⌥⌘↓ for the next one.

## Stop the agent

<!-- id: team-stop; covers: -->
Stops the turn that is running for the selected agent.
Где: Menu Agent → Stop agent (Остановить агента), or the Stop (Остановить) button in the composer
1. Select the agent and press ⌘. (or click Stop (Остановить) in the composer).
2. The turn ends. The agent is ready for the next message.

## Inspector: agent details

<!-- id: team-inspector; covers: -->
A panel on the right with the selected agent's details. It has three tabs: Details (Сведения), Memory (Память), and Where it runs (Где работает).
Где: Team → agent → Agent details (Сведения об агенте) toggle (⌘I), or Menu Agent → Agent details
1. Press ⌘I to open the panel. Press ⌘I again to close it.
2. Choose a tab at the top of the panel.

## Details tab: runtime, model, fallback, approvals, project

<!-- id: team-details; covers: -->
The main settings of the agent. Each row changes the agent for the next message.
Где: Team → agent → Agent details (⌘I) → Details (Сведения)
1. Runs on (Работает на): choose another runtime, Claude Code, Codex or Grok. Memory and tasks move with the agent.
2. Model (Модель): type a model name, or click Default (По умолчанию) to use the runtime's default.
3. If the limit runs out (Если лимит кончится): choose Don't switch (Не переключаться) or another runtime. The agent continues there until the first limit resets.
4. Approvals (Одобрения): choose Risky only (Только рискованное), Everything (Всё подряд) or Nothing (Ничего). See [security.md](security.md).
5. Project (Проект): the folder the agent works in on the server. Change it with the folder picker of the row.
6. Effort (Усилие): choose Low, Medium, High, Very high or Max. Higher levels are smarter on hard tasks but use the limit faster.
7. Instructions (INSTRUCTIONS): edit the text, then click Save (Сохранить).

## Schedules (SCHEDULE)

<!-- id: team-schedules; covers: sheet:schedule -->
Runs a prompt for the agent at a set time, for example every morning. A schedule is a repeat rule with a time and a prompt. The New schedule (Новое расписание) sheet opens over the main window.
Где: Team → agent → Agent details → Details → SCHEDULE → Add schedule (Добавить)
1. Click Add schedule (Добавить).
2. Choose how often in Repeat (Повтор): Every, Every day, Weekdays, Days of the week, or Other (cron). Set the time in At (В) and the request in Prompt (Запрос). Only Other (cron) takes a cron expression.
3. Click Add schedule (Добавить) to save. The list shows Next run (Next run …) for each schedule.
4. Use the switch in a row to pause or resume it.

## Where it runs tab

<!-- id: team-where; covers: -->
Shows where the agent works on the server and the state of its runtime: the install and login state of the CLI, and the usage limits. Each place opens its own mode.
Где: Team → agent → Agent details → Where it runs (Где работает)
1. Click Project folder (Папка проекта) to open the Files mode in the project. Agent terminal (Терминал агента) opens the terminal tab in the panel. Its browser (Его браузер) opens the browser tab in the panel. Screen (Экран) opens the Server screen.
2. Read the runtime state: Installed or Not installed (Не установлен), Logged in or Not logged in (Вход не выполнен).
3. Usage (Использование) shows the limit bars of the runtime; the reset time is shown on each bar.

## Memory tab

<!-- id: team-memory; covers: -->
The agent keeps its memory in plain Markdown files on the server. Long chats are split into chapters. The Memory tab shows the current chapter, how full it is, and how the chapters are split.
Где: Team → agent → Agent details → Memory (Память); also /memory
1. Read Chapter N (Chapter {count}), the line N tokens used (tokens used), and new chapter after N (new chapter after {limit}), which is the limit of the chapter.
2. Choose how to split the chats under HOW TO SPLIT INTO CHAPTERS (КАК ДЕЛИТЬ НА ГЛАВЫ): Smart (Smart, recommended) starts a new chapter when the conversation grows and a fresh one each morning; Every day (Каждый день) starts a clean page each morning; One long chapter (Одна длинная глава) keeps one chapter, and the agent compresses old messages itself. This costs more. Under Smart, Chapter length (Длина главы) sets how many tokens a chapter may hold: 60K, 120K (default), 200K, 500K, 1M, or your own number (Своё…); sizes above the model's window are off.
3. Open the memory files under MEMORY: MEMORY.md (main points: projects, decisions, open tasks), Notes (notes/), Journal (journal/), Files (files/). Each opens as a tab in the workbench panel. Open in Files (Открыть в Файлах) in the tab moves to the Files mode.
4. Edit or delete a file in Files. The agent reads the new version next time.

## What changed (Что изменил агент)

<!-- id: team-changes; covers: -->
A tab of the workbench panel that lists the files the agent changed, task by task, with a diff for each file. The header shows the agent's name, the number of files, the lines added and removed, and the task. You can keep a file back to its state before the task, or roll back the whole task. In a narrow panel the file list is on top of the diff. Until the agent changes a file, the tab says Nothing changed yet (Пока ничего не изменено).
Где: Team → agent thread → Changes (Изменения) button in the header; Menu Agent → What changed (Что изменил агент); ⌘⇧D; /changes
1. Open the changes tab. The tasks are listed with their restore points: Before the task (До задачи), End of turn (Конец хода), and Before restore (Перед откатом).
2. Click a file to see its diff. Switch between Inline (Построчно) and Side by side (Рядом). Binary files show Binary file changed.
3. To keep a file as it was before the task, untick it (Keep {name}). The count shows Keep N files. The other files stay as they are.
4. To roll back the whole task, click Roll back the whole task (Откатить всю задачу), read the question, and click Roll back (Откатить). Files go back to how they were before the task.
5. After a rollback, a notice appears with Undo (Отменить). Click it to bring the changes back.
6. Ask about a place: click Ask {name} about this place (Ask {name} about this place) on a diff line. The composer gets the request for that file and line.

## Changes needs a current server (Update the server)

<!-- id: team-changes-old-server; covers: -->
The Changes tab needs a current server. On an older server it shows Update the server (Обновите сервер).
Где: Team → agent → What changed → Update the server (Обновите сервер)
1. Update the daemon from the Server mode → Updates (see [server.md](server.md)).

## Switching the runtime when the limit runs out

<!-- id: team-fallback; covers: -->
When the subscription limit of the runtime runs out and a fallback is set, the agent continues on the other runtime. The thread shows a note: "Claude Code limit ran out — continuing on Codex until …". When the limit resets, the note says Back on Claude Code.
Где: Team → agent → Agent details → Details → If the limit runs out (Если лимит кончится)
1. Set the fallback in the Details tab. Choose Don't switch (Не переключаться) to turn it off.
2. Nothing else to do: the note in the thread shows the switch and the return.
