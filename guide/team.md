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
Pinned agents are listed at the top. The context menu of an agent has Pin (Закрепить) or Unpin (Открепить), Pause (Приостановить) or Resume (Продолжить), and Move to… (Перенести на…) when another connected server takes moved agents, and Delete… (Удалить…). A paused agent shows a pause mark next to its name, and its avatar sleeps.
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

## Move an agent to another server (Перенести на…)

<!-- id: team-move-agent; covers: sheet:moveAgent -->
Move to… (Перенести на…) in the agent's menu moves it to another connected server of yours that takes moved agents. Its settings, memory and chat history move; the project folder (the code) does not, so you choose the project folder on the new server: a new folder in the agents folder, or an existing one. The agent is paused on the old server while it moves. Progress goes through packing, copying, unpacking and done. Cancel (Остановить перенос) stops it before the new server has the agent. A failed move leaves the agent on the old server as it was, and Try again (Повторить) starts it over.
Где: Team → sidebar → agent → right click → Move to… (Перенести на…). The item is there only when another connected server takes moved agents.
1. Right-click an agent and choose Move to… (Перенести на…). Pick the server and the project folder there, then Move (Перенести).
2. Wait for Done (Готово). Then choose Done to open the agent on the new server.
3. On the old server the agent shows Moved to <server> (Перенесён на <сервер>) under its header, paused. Open there (Открыть там) goes to it; Delete here (Удалить здесь) deletes the copy on the old server after a confirmation.

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

## Start a new agent's thread

<!-- id: team-empty-thread; covers: -->
A new agent's thread has no messages yet. It shows the agent's avatar, its name and role, and four suggestions to begin with, chosen from what the agent may do (Terminal, Project files, Browser, Message the crew).
Где: Team → agent thread, before the first message (Write a task or a question…)
1. Click a suggestion. Its text goes into the message field, after anything already there, without being sent. The field takes the keyboard with the caret at the end: change the text if you want, then press ↵ to send.
2. The suggestions go away with the first message, yours or the agent's. A thread that already has messages on the server shows none.

## Write a message

<!-- id: team-composer; covers: -->
The composer sits at the bottom of the thread. It sends the message to the selected agent and shows the reply as it arrives.
Где: Team → agent thread → composer (Message {name})
1. Click in the field and type. Press ↵ to send (↵ send). Press ⇧↵ for a new line (⇧↵ new line).
2. While the agent is working, the send button becomes Stop (Остановить). Press ⌘. to stop the turn (⌘. stop).
3. A message you send while the agent is busy, or saving its memory before a new chapter, appears in the chat at once with the line Queued (В очереди) below it. The line goes away when the agent takes the message. If the agent stopped or the server restarted before it did, the line reads Not delivered (Не доставлено); right-click the message and choose Send again (Отправить снова). After a new chapter begins, the message sits below the chapter divider, where the agent reads it. The counter beside Thinking… counts from the start of the current turn.

## Jump to the newest message

<!-- id: team-jump-latest; covers: -->
When you scroll up in a thread, a small capsule with a down arrow appears over the composer, in the middle. If messages came in meanwhile it also says how many ("3 new"). Click it to slide back to the newest message. When you send a message, the thread slides down to it by itself wherever you were, and keeps following the replies until you scroll up yourself. With Reduce Motion the capsule only fades and the thread jumps instead of sliding.
Где: Team → agent thread → capsule over the composer
1. Scroll up to read earlier messages. The capsule fades in over the composer.
2. Click it, or send a message, to go to the bottom.
3. Scroll up while the agent is answering: the thread stays where you are, and the capsule counts the new messages.

## Dictate a message

<!-- id: team-dictation; covers: -->
Speak instead of typing. Speech is turned into text on this Mac; no audio is sent over the network. The words go into the field at the caret.
Где: Team → agent thread → composer, the microphone button (Надиктовать) next to +, or ⌥⌘D (menu Team → Dictate into the message)
1. Press the microphone or ⌥⌘D. The first time, macOS asks for the microphone and for speech recognition: allow both. If you refused, a line above the field says so and links to System Settings.
2. Speak. The words appear in the field at the caret. While it listens the microphone is filled and has a cream dot.
3. Stop it with the microphone again, ⌥⌘D or Esc, or let it stop by itself: two seconds after the last words it recognised, or eight seconds if you said nothing. Check the text, then press ↵ to send.
4. A language without an offline speech model cannot be dictated. The line above the field says how to add it: System Settings → Keyboard → Dictation.

## Read replies aloud

<!-- id: team-read-aloud; covers: -->
Hear an agent's answer. The voice follows the language of the text. Markdown is read as plain sentences; a code block is not read, it becomes "code skipped" (код пропущен).
Где: the ⋯ menu of an agent's message (or right-click) → Read aloud (Прочитать вслух); Inspector → Details → Read replies aloud (Читать ответы вслух)
1. Point at an agent's message, press ⋯ and choose Read aloud. Choose Stop reading (Остановить) to stop.
2. To hear every new finished reply of one agent, turn on Read replies aloud in its Details. It is off by default and kept on this Mac, per agent. A reply is read once, when its turn has ended. It is read only while Bandito is the active app; opening a thread reads nothing from its history.

## Links in a message (Ссылки в сообщениях)

<!-- id: team-message-links; covers: -->
Web addresses and file paths in a message are links. A file opens in the workbench panel beside the chat, a folder in Files, and ⌥-click shows a file in Files. A web address opens in the built-in browser in the panel, unless Settings say otherwise (see Open links from chat in). ⌘-click opens it in the browser of the Mac; sign-in pages (Google, Microsoft, Apple, GitHub login, Composio, Auth0, any login or OAuth page) open in the browser of the Mac by default. ⌘ reverses every link, sign-in pages included. When the pointer is over a message with a web address, a hint under the message says where a click opens the link and where ⌘ takes it: hold ⌘ and the hint turns round. The first web link you click on this Mac shows a note with the same explanation; it goes away by itself and does not come back.
Где: Team → agent thread → a message with a link. Hover over the message to see the hint
1. Click a web address: it opens in the built-in browser. Hold ⌘ and click: it opens in the browser of the Mac.
2. To change which one a click uses, open Settings (⌘,) → General (Общие) → Open links from chat in (Ссылки из чата открывать).

## When a message was sent (Когда отправлено)

<!-- id: team-message-time; covers: -->
Point at a message, yours or the agent's, and the row of its actions shows when it was sent: quietly, at the end of the row, without moving the text. Today it reads сегодня, 14:22:05; yesterday вчера, 09:03:12; earlier this year 3 окт., 22:14:37; in an older year 11 окт. 2025, 22:14:37. The clock is 24-hour and shows the seconds. Hover over the time for a moment to see the full date with the weekday, the year and the seconds.
Где: Team → agent thread → hover over a message; the time is at the end of the row under it
1. Point at a message. The time appears under it, at the end of the row of actions (on the agent's message after the ⋯ button, on yours before the icons).
2. Hover over the time: a tooltip gives the whole date, for example Sunday, October 11, 2026, 22:14:37.

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

## An agent asks you to connect a service

<!-- id: team-connect-request; covers: -->
When an agent needs a service from the catalog (GitHub, Notion, Composio and so on), it does not ask you for ids and keys: a card appears in the thread, "Forge needs GitHub" (Агенту Forge нужен GitHub), with the service's logo and the agent's reason in quotes, signed "— Forge writes" (— пишет Forge): the words are the agent's. A line above the field says the agent waits for it: "Forge is waiting for you to connect GitHub" (Forge ждёт, когда вы подключите GitHub), with a link Go to the card (К карточке).
Где: Team → agent thread → card "needs …"
1. Click Connect (Подключить). A service that signs in with a code (GitHub) shows the code sheet; one that signs in in the browser opens the sign-in there; a service with keys opens the sheet of keys. It is the same connection as in the Marketplace, and only a connection started from this card closes it: connecting the same service from the Marketplace does not.
2. When the service is connected, the card folds to a line: "GitHub connected, Forge continues" (GitHub подключён, Forge продолжает). The agent gets the service itself, even if it had its own list of services, and goes on with its work. If you keep a service that is there already off this agent, it says so to the agent and shows no card.
3. Click Not now (Не сейчас) to refuse: the line says "You did not connect GitHub" (Вы не стали подключать GitHub), and the agent is told so.
4. A request that nobody answered for a day, or that was open when the server restarted, ends as "The request for GitHub timed out" (Запрос на GitHub истёк). A server older than this build shows no card.

## An agent asks to create another agent

<!-- id: team-agent-create; covers: -->
The main agent of the crew creates agents when you ask for one: "make an agent that checks my mail every 5 minutes". A card appears in its thread, "Forge wants to create an agent" (Forge хочет создать агента), with everything the new agent gets: Role (Роль), Runs on (Работает на), Asks you (Спрашивает вас), Can use (Может использовать), Services (Сервисы), Runs (Запуски), Folder (Папка) and Instructions (Инструкции). A new agent never gets more than the one that creates it: not a capability or a service it lacks, and it asks you at least as often.
Где: Team → main agent's thread → card "wants to create an agent"
1. Read the rows. Nothing exists yet.
2. Click Create (Создать) or press ⌘↵ to make the agent. It appears in the sidebar, and its thread says "Created by Forge" (Создан агентом Forge). The main agent then sets its regular runs and gives it its first task.
3. Click Decline (Отклонить) or press Esc (⎋) to refuse. The main agent is told not to try again unless you ask.
4. The card folds into a line: You allowed creating “Mailer” (Вы разрешили создать «Mailer»), You declined creating “Mailer” (Вы отклонили создание «Mailer»), or The request to create “Mailer” timed out (Запрос на создание «Mailer» истёк).
5. If the main agent asks for nothing (its approvals are set to About nothing), the agent is made at once, and the thread says "Created the agent “Mailer” without asking" (Создан агент «Mailer» без вопроса).

## Quick replies under a message

<!-- id: team-quick-replies; covers: -->
When an agent waits for you to do something outside the chat, or offers choices, it shows buttons under its last message instead of waiting for you to type: for example Done, it is connected (Готово, подключил) after you connect a mailbox, or buttons for options 1 and 2. A button with an arrow (↗) opens a page, such as the settings you have to change. "2 of 6" (2 из 6) says where you are in a long setup.
Где: Team → agent thread → buttons above the message field
1. Click a button to answer. Its text is sent as your message, and the buttons disappear. Point at a button to see the full text it sends when its label is short.
2. Click the button with the arrow to open the page. Web links open as links in messages do (see Links in a message).
3. Write your own message instead and the buttons go away too. They also go away when the agent starts another turn, and a newer set replaces an older one.

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
4. Ask for permission (Спрашивать разрешение): choose Only the risky ones (Только о рискованном), About everything (Обо всём) or About nothing (Ни о чём). See [security.md](security.md).
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
4. To roll back the whole task, click Roll back all (Откатить всё), read the question (Откатить всю задачу?), and click Roll back (Откатить). Files go back to how they were before the task.
5. After a rollback, a notice appears with Undo (Отменить). Click it to bring the changes back.
6. Ask about a place: click Ask agent (Спросить агента) on a diff line; its tooltip names the agent. The composer gets the request for that file and line.

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
