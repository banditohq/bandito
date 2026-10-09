# New agent (Новый агент)

Creating an agent: its name, runtime, model, project folder and approvals. Open the sheet with ⌘N. After Create,
the agent is selected in the Team mode.

## Open the New agent sheet

<!-- id: na-open; covers: sheet:newAgent -->
The sheet has the fields on the left and the workplace, memory and approvals on the right. The default values are: runtime Claude Code, effort Medium, approvals Risky only, memory Smart, no fallback.
Где: Sidebar → New agent (⌘N) (New agent (⌘N)); Menu Agent → New agent (Новый агент); composer → /new
1. Press ⌘N (or click New agent (⌘N) in the sidebar, or type /new in a composer).
2. Fill in the fields described below. The Create button is enabled when the name is filled and the project folder is chosen.
3. Click Create {name} (Create Forge) to create the agent. Cancel (Отмена) closes the sheet without saving.

## Start from a template (From template…)

<!-- id: na-template; covers: -->
A template fills the name, role, runtime, effort, instructions and approvals for a common job. You can change any field afterwards.
Где: New agent sheet → From template… (Из шаблона…)
1. Click From template… (Из шаблона…).
2. Pick one of the templates: Builder (Сборщик) writes and fixes code and opens PRs; Reviewer (Ревьюер) reviews changes; On-call watches production and wakes you only when it matters; Assistant (Ассистент) handles mail, calendar, notes and reminders; Researcher (Исследователь) searches and compares sources; From scratch (С нуля) is an empty agent.
3. Check the fields, then click Create.

## Name, role, face (Name, Role, Face)

<!-- id: na-name; covers: -->
The name is shown in the sidebar and in the chat. The role is a short label, for example builder, reviewer or on-call. The face is the avatar: one of the three faces and six colors.
Где: New agent sheet → Name (Имя), Role (Роль), Face (Face:)
1. Type a name in Name (Имя). It is required.
2. Type a role in Role (Роль), for example builder, or leave it empty.
3. Choose a face and a color under Face (Face:).

## Runtime: Powered by (Чем думает)

<!-- id: na-runtime; covers: -->
The CLI that runs the agent. Claude Code, Codex and Grok run on the server with their own subscriptions. Each runtime shows its state, so you see at once why one is not ready.
Где: New agent sheet → Powered by (Чем думает)
1. Pick Claude Code, Codex or Grok.
2. Read the state under each runtime: Signed in · N% left (Signed in · N% left) means it is ready. Not installed on the server (Не установлен на сервере) and Not signed in on the server (Вход на сервере не выполнен) mean you must fix it on the server first. Run the command shown there, for example `codex login`.
3. API key (API-ключ) is in the sheet with the label Coming soon (Скоро здесь): it is not available in this build.

## Model (Модель) and effort (Effort)

<!-- id: na-model-effort; covers: -->
The model is the one the CLI runs; the default is the runtime's own. Effort sets how long the agent thinks.
Где: New agent sheet → Model (Модель), Effort (Усилие)
1. Leave Default (По умолчанию) to use the runtime's default model, or type any model name the CLI accepts.
2. Choose the effort: Low (Низкое) is fast and cheap for small edits; Medium (Среднее) is enough for everyday work; High (Высокое) for hard tasks; Very high (Очень) for big rewrites; Max (Максимум) only when nothing else worked. The levels offered depend on the runtime.

## If the limit runs out (Если лимит кончится)

<!-- id: na-fallback; covers: -->
Sets a second runtime that takes over when the subscription limit of the first one is used up. The agent comes back to the first one when the limit resets. Memory and tasks move with the agent.
Где: New agent sheet → If the limit runs out (Если лимит кончится)
1. Keep Don't switch (Не переключаться), or pick another runtime from the list.
2. If you pick one, type a model in the field that shows Default (По умолчанию), or leave it empty to use the runtime's default.
3. The same setting is in Agent details → Details (see [team.md](team.md)).

## Project folder (Project on the server)

<!-- id: na-folder; covers: -->
The folder on the server where the agent works. Pick one that exists, create a new folder, or clone a repository from a link into a new folder on the server.
Где: New agent sheet → Project on the server (Проект на сервере) → Choose… (Выбрать…)
1. Click Choose… (Выбрать…). The folder picker opens.
2. Type a folder name or paste a path into Find a folder or paste a path (Найти папку или вставить путь). The lists are RECENT (НЕДАВНИЕ) and REPOSITORIES FOUND (НАЙДЕНЫ РЕПОЗИТОРИИ). Hidden folders are marked hidden (hidden).
3. To make a folder, click New folder (Новая папка), type the name, and press ↵.
4. To clone a repository, click Clone from a link (Склонировать по ссылке), paste the Repository address (https:// or git@host:path), set Folder name (Имя папки), and click Clone (Клонировать). Cloning can take a few minutes.
5. Click Choose {name} (Choose {name}) to select the folder.

## Workplace: Shared (Общее)

<!-- id: na-workplace; covers: -->
Where the agent's CLI runs. Shared (Общее) is the server itself, as the Bandito user: the agent works with the same files as you on that server, and it can use the server's browser and screen. Nothing to install. This is the default.
Где: New agent sheet → Workplace (Рабочее место) → Shared (Общее)
1. Leave Shared (Общее) selected.

## Separate workplace (Отдельное рабочее место)

<!-- id: na-workplace-separate; covers: -->
A separate workplace is a Docker container on the server. The agent sees only its own folder and the folders added to the workplace (see [server.md](server.md)). Your other files and keys on the server are out of its reach. The container has its own disk, its own network and limits of processor and memory. The cost: inside a container the agent has no browser and no screen tools, because those run on the server.
Где: New agent sheet → Workplace (Рабочее место) → Separate (Отдельное рабочее место)
1. Choose Separate (Отдельное рабочее место). It is offered only when Docker is ready on the server. Otherwise the sheet says Docker is needed; install it in Server → Overview.
2. Pick an existing workplace from the menu, or choose New… (Новое…).
3. For New… type a Name (Название), 1 to 64 characters. The new workplace gets the default limits (2 CPU, 2048 MB) and internet. It is made when you click Create. Change its limits and network later in Server → Workplaces.
4. An agent in a separate workplace is moved there later from its Inspector: Where it works (Где работает).

## Memory (Память)

<!-- id: na-memory; covers: -->
Where the agent keeps its notes. It is created automatically in the agent's own folder, so the agent remembers things and messages do not get more expensive.
Где: New agent sheet → Memory (Память)
1. Keep the default Smart (Smart, recommended), or pick Every day (Каждый день) or One long chapter (Одна длинная глава). The descriptions are in Agent details → Memory (see [team.md](team.md)).

## Approvals for the new agent (Ask me about)

<!-- id: na-approvals; covers: -->
Sets when the agent asks you before it acts. Pushes, deploys, deletes and writes outside the project folder always wait for your yes. See [security.md](security.md).
Где: New agent sheet → Ask me about (Что спрашивать у вас)
1. Pick Risky only (Только рискованное) (default): the routine work goes on by itself, risky steps are asked about.
2. Pick Everything (Всё подряд): every tool call the CLI asks about goes to you.
3. Pick Nothing (Ничего): the agent runs without asking. Use it only for sandboxes.
4. You can change this later in Agent details → Details → Approvals.

## What it may do (Что ему можно)

<!-- id: na-tools; covers: -->
A summary of the tools the agent gets: Terminal (Терминал), Project files (Файлы проекта), Browser (Браузер) and Message the team (Писать команде) are on; Server screen (Экран сервера) is off. The row is informational in this build: the tools cannot be switched here.
Где: New agent sheet → What it may do (Что ему можно)
1. Read the list. It only shows what the agent gets; the list does not switch anything in this build.

## Instructions (Инструкции)

<!-- id: na-instructions; covers: -->
A text that the agent gets with every task, like a brief for a new colleague. It is optional.
Где: New agent sheet → Instructions (Инструкции)
1. Type the rules, the scope and the things to avoid. Edit it later in Agent details → Details → INSTRUCTIONS → Save (Сохранить).
