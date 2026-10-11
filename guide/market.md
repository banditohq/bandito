# Marketplace (Маркетплейс)

Three pages in one place: the services the agents can use (MCP servers that you connect once, on the server, and every
agent can then use their tools), ready-made bots, and skills. The mode lists the catalog, shows what is connected, and
has a page for every service. Open it with ⌘6.

## Services, Bots, Skills

<!-- id: market-tabs; covers: -->
The switch at the top of the Marketplace has three segments: Services (Сервисы), Bots (Боты) and Skills (Скиллы). Each
page has its own list in the sidebar and its own search. Bandito remembers the page you left it on. Bots and Skills show
only when the server is new enough to have them; an older server shows Services alone.
Где: Marketplace → the switch under the title → Services (Сервисы), Bots (Боты), Skills (Скиллы)
1. Click a segment to change the page. The search field is cleared, and the sidebar changes to that page's rows.
2. Bots lists All (Все), My bots (Мои боты) and the categories. Skills lists All (Все), Installed (Установленные) and the categories.
3. The search on each page finds by name, in the language of the app and in English, and by the description.

## Marketplace mode

<!-- id: market-mode; covers: mode:market -->
The main area lists the services. The connected ones are in one row at the top; the catalog follows without them. Each
connected card shows its address and the result of the last check: the number of tools, the error, or Not checked yet.
Each catalog card shows the icon, the name, the publisher, two lines about the service, View (Посмотреть) and Connect
(Подключить).
Где: sidebar footer → Marketplace button (Маркетплейс), or Menu View → Go to Marketplace (Маркетплейс)
1. Press ⌘6, or click the Marketplace button at the bottom left of the sidebar, between your profile and the usage button.
2. The button is lit while the Marketplace is on show. It is not in the mode bar at the top of the sidebar.
3. Without a server, the page says No servers (Нет серверов). Click Add server (Добавить сервер).

## Filters and categories

<!-- id: market-filters; covers: -->
The sidebar lists All (Все), Connected (Подключённые), and the categories of the catalog: Development (Разработка),
Productivity (Продуктивность), Data (Данные), Web (Веб), Design (Дизайн) and Other (Другое). A category shows its
services whether or not they are connected. Only the categories the catalog has are listed.
Где: Marketplace → sidebar → All (Все), Connected (Подключённые), a category
1. Click Connected (Подключённые) to hide the services that are not connected.
2. Click a category to see only its services.
3. With no connected service, the page says Nothing is connected yet (Ничего ещё не подключено).
4. Clicking a row in the sidebar also closes the page of a service.

## Search

<!-- id: market-search; covers: -->
The search field at the top right finds services by name and by description. It ignores case and spaces at the ends. Its focus shows as a cream ring around the field. Catalog services show their logo on the brand-colour tile.
Где: Marketplace → search field (Поиск)
1. Type part of the name or the description. A search with no match says Nothing found (Ничего не нашлось).

## A service's page

<!-- id: market-detail; covers: -->
Click a card, or View (Посмотреть) on it, to read about the service before you connect it. The page has the icon, the
name, the publisher with the Official (Официальный) badge when the service is the maker's own, and the category. On
the right: Connect (Подключить), or the status and Configure (Настроить) when it is connected.
Below: What it can do (Что умеет), About (Описание), What you need (Что понадобится), How to connect (Как подключить)
with one to three steps made from the service's fields (get the key, fill in the address or the path, press Connect),
and the links Documentation (Документация) and Website (Сайт). A connected service also shows its status with the number of tools from the
last check and To the list (К списку), which jumps to the Tools section below; then the switch Available to agents
(Доступно агентам), Check (Проверить) and Remove (Удалить).
Где: Marketplace → a card → View (Посмотреть)
1. Click View (Посмотреть) on a card. The page opens in the same area.
2. Click Marketplace (Маркетплейс) at the top left, or press Esc, to go back to the list.
3. Click Connect (Подключить) on the page to open the sheet with the service's settings.

## Connect a service

<!-- id: market-connect; covers: -->
Connect (Подключить) opens the sheet with the service's settings: the command or the address, the variables and the
headers. The sheet can check the connection before you leave it.
Где: Marketplace → a catalog card or a service's page → Connect (Подключить)
1. Fill in the secrets. They are kept on the server; the app does not show them again.
2. Click Connect (Подключить) to save. The server is then checked, and the sheet shows the tools it offers.
3. The card then shows Connected (Подключено) and Configure (Настроить).

## Connect in the browser

<!-- id: market-oauth; covers: -->
A service that signs in with its own page (no key to copy) shows Connect (Подключить) like the others, but Connect opens your
browser instead of the sheet. Linear, Notion and Sentry connect this way. The server asks the service for the permission page and Bandito opens it; the keys never
come to this Mac. A sheet says Waiting for your permission in the browser (Ждём разрешения в браузере) with Open the
browser again (Открыть браузер снова) and Cancel (Отмена). After you allow access the browser brings you back to Bandito,
the sheet says Connected (Подключено) and the card shows the tools. If the access is refused, expires or is revoked, the
card says Needs sign-in again (Нужно войти снова) with the button Sign in again (Войти снова); the agents see the service
as off until then. If the service is out of reach when Bandito renews the access, the card says Couldn't renew the sign-in, will retry (Не удалось обновить вход, попробуем ещё раз): the access still works, and Bandito tries again by itself. Remove (Удалить) also withdraws the access on the service's side when it can.
Где: Marketplace → a catalog card or a service's page → Connect (Подключить), then the sheet; Sign in again (Войти снова) on a card, in its menu (…), or on its page
1. Click Connect (Подключить). The browser opens the service's page.
2. Allow access there. Come back to Bandito if the browser does not bring you back by itself.
3. Click Done (Готово) in the sheet. Cancel (Отмена) gives the sign-in up; a late answer from the browser is ignored.
4. A sign-in waits ten minutes. If it expired, or you pressed Cancel, click Connect (Подключить) again.
5. Click Sign in again (Войти снова) when the card asks for it. The same service page opens.

## Configure, turn off, remove

<!-- id: market-configure; covers: -->
The switch Available to agents (Доступно агентам) on a connected card turns the service on or off for the agents. The
menu (…) on the card has Check (Проверить), Edit (Изменить) and Remove (Удалить); the page of the service has the same
actions. Remove takes the service off the server: the agents lose its tools. Its secrets stay on the server.
Где: Marketplace → connected card → Available to agents (Доступно агентам) switch, or the menu (…) → Check (Проверить), Edit (Изменить), Remove (Удалить)
1. Click the menu (…) on the card and choose Remove (Удалить). Confirm in the dialog.
2. Click Configure (Настроить) on a catalog card to change the settings of a connected service.

## Own integration

<!-- id: market-own; covers: -->
Own integration (Своя интеграция) adds a server that is not in the catalog. At the top, paste what the server's
documentation shows, and the fields fill themselves in. It reads a Claude Desktop or Cursor config (`mcpServers`; with
several servers it lists them with check boxes), one server's object, a command such as `npx -y @scope/package`,
`uvx package` or `docker run …`, `claude mcp add …`, or a URL. A line says what it recognized, or why it could not read
the text. The server is listed with the connected services.
Где: Marketplace → Own integration (Своя интеграция)
1. Paste the config, the command or the address into the large field (Вставьте конфиг из документации).
2. Or fill in by hand (или заполните вручную): the Name (Название), the type, and the command or the address. The
   technical name is made from the title and shown small, for example "will be: github-2"; click it to change it.
3. Choose Program on the server (Программа на сервере) for a command, or Address on the internet (Адрес в интернете)
   for an HTTP or SSE server. A program has one field, the Full command (Команда целиком), with quotes for a word that
   holds a space.
4. Add the Environment variables (Переменные окружения) or the Headers (Заголовки). Turn on Secret (Секрет) for a
   key: its value is kept on the server and the integration holds only a reference.
5. Click Check (Проверить) to try the connection: the sheet lists the tools it found, or says what went wrong. A check
   adds the server turned off; leaving the sheet without Add (Добавить) removes it again, with the secrets the
   sheet wrote.
6. Click Add (Добавить) to keep the server. If you ticked several servers in a pasted config, the next one comes into
   the form after each Add.

## Bots

<!-- id: market-bots; covers: -->
The Bots page lists ready-made bots: an agent with its role, instructions, scheduled runs, skills and the services it
uses already set up. Each card has the icon on a coloured tile, the name, the category, a short description, small
logos of the services the bot uses (the optional ones are dimmer), View (Посмотреть) and Create bot (Создать бота).
Где: Marketplace → Bots (Боты)
1. Click a category in the sidebar to see only its bots.
2. Click View (Посмотреть) on a card, or the card itself, to read about the bot.
3. Click Create bot (Создать бота) on a card to go straight to the create sheet.

## My bots

<!-- id: market-my-bots; covers: -->
My bots (Мои боты) lists the bots you made from a template, one card each: the name, the template it came from and Open
(Открыть), which opens the bot's chat in the team. Bots you made by hand are not listed. Until you make one, the page
says so and points to Create bot (Создать бота).
Где: Marketplace → Bots (Боты) → My bots (Мои боты)
1. Click Open (Открыть) on a card, or the card itself, to open the bot.
2. The search finds a bot by its name or by the name of its template.

## A bot's page

<!-- id: market-bot-detail; covers: -->
View (Посмотреть) opens a panel over the page: the long description, On a schedule (По расписанию) with each run in
words (for example Weekdays at 8:00 AM), Services it uses (Какие сервисы использует) and Skills (Скиллы). A service is
marked Required (Обязательно) or Optional (По желанию), and shows Connected (Подключённые), Turned off in Services, or the
button Connect (Подключить). Connect works as on the Services page, including the sign-in in the browser; the panel stays
open and updates when the service is connected.
Где: Marketplace → Bots (Боты) → a card → View (Посмотреть)
1. Click Connect (Подключить) next to a service that is not connected.
2. Click Create bot (Создать бота) at the bottom right to go on. Close (Закрыть) or Esc leaves the panel.

## Create a bot

<!-- id: market-bot-create; covers: -->
Create bot (Создать бота) opens the sheet that makes an agent from the template. Name (Имя) is the template's name in
the language of the app, and you can change it; the same rules as for a new agent apply, with at most 32 characters.
Powered by (Чем думает) lists only the programs that are installed and signed in on the server; the template's own
choice comes first. Under On a schedule (По расписанию) each run is a switch; the ones the template recommends are on.
If a required service is not connected, the sheet says so and offers Connect (Подключить) there: you can still create the
bot, but it cannot do its job until the service is connected. When it is made, its chat opens and the first message is
already in the input field. Bandito does not send it: read it, change it if you like, and send it yourself. If a step
after the agent was made did not work (a skill, a schedule), a note at the bottom of the window says which one; the
agent stays.
Где: Marketplace → Bots (Боты) → Create bot (Создать бота)
1. Check the Name (Имя); a red line explains a name that is taken or not allowed.
2. Choose what it is Powered by (Чем думает), and turn the schedules on or off.
3. Click Create bot (Создать бота). The button says Creating… (Создаём…) and the sheet cannot be closed until it is done.
4. Click Cancel (Отмена) or press Esc to leave without creating.

## Bundles

<!-- id: market-bundles; covers: -->
Above the ready-made bots, Bots (Боты) shows Bundles (Наборы): a set of three to five bots that work together, such as a
startup team (a task manager, a code reviewer, a Sentry on-call and a documentation writer). Each set card shows its icon,
its name and description in the language of the app, and small tiles of the bots it holds. The sets follow the sidebar
filter and the search; My bots (Мои боты) shows none of them. Bundles show only when the server is new enough to have them.
If the sets do not load, a quiet line says Sets did not load (Наборы не загрузились) with Retry (Повторить); the single bots still show.
Где: Marketplace → Bots (Боты) → Bundles (Наборы), above the ready-made bots
1. Click View (Посмотреть) on a set, or the card itself, to open its panel.
2. Sets are found by their name, in the language of the app and in English, and by their description.

## A set's panel

<!-- id: market-bundle-panel; covers: -->
The panel lists the bots of the set, each with its description, the services the set's bots use, and Powered by (Чем
думает). A service is Required (Обязательно) or Optional (По желанию) and connects as it does on a bot's page. Create team
(Создать команду) makes one bot for each template of the set, in the language of the app, with the template's schedules
turned on. A bot whose name is taken gets a number (for example Code reviewer 2). The panel then lists the bots that were
made and the ones that were not, with the reason; a bot made with a problem after its creation still exists. Open (Открыть)
goes to the chat of the first bot the set made. Close (Закрыть) or Esc leaves the panel. The panel cannot be closed while
the team is being made. If the request fails (a timeout, a lost connection), the panel reads the list of bots again and
says that some bots may have been created. Create missing bots (Создать недостающих) then makes only the bots that have
no agent of their template from the last ten minutes; nothing is made twice.
Где: Marketplace → Bots (Боты) → Bundles (Наборы) → a set → View (Посмотреть)
1. Choose Powered by (Чем думает) if the default is not the one you want. Only the programs ready on the server are offered.
2. If a required service is not connected, the panel says so and you can Connect (Подключить) it there, or create the team now and connect later.
3. Click Create team (Создать команду). The button says Creating… (Создаём…) while the bots are made.
4. Read the list of results, then click Open (Открыть) to see the first bot's chat.

## Skills

<!-- id: market-skills; covers: -->
The Skills page lists open skills: folders of instructions and scripts that an agent reads when a task fits. Each card has
the name, the author and the licence (small), a short description, the label Claude only (Только Claude) when the skill
works natively in Claude Code alone, and a warning when the skill needs care (for example a script that runs the command
you give it). The state shows on the card: Installed (Установлено) with Remove (Удалить) when the skill is installed for
every agent on the server, On N agents (У N агентов) when only some agents have it, Name taken (Имя занято) when a
folder of that name already exists that Bandito did not make.
Где: Marketplace → Skills (Скиллы)
1. Click Installed (Установленные) in the sidebar to see only the skills that are installed somewhere.
2. Click Install (Установить) on a card to choose where, or View (Посмотреть) to read first.

## A skill's page

<!-- id: market-skill-detail; covers: -->
View (Посмотреть) opens a panel: the description, the warning, Where it is installed (Где установлено) with each place and
Remove (Удалить), the Files (Файлы) the skill brings, and the Source (Источник): a link such as owner/repo@abc1234 that
opens the author's folder at that exact commit in the browser. Bandito ships a reviewed copy of the files; nothing is
downloaded when you install.
Где: Marketplace → Skills (Скиллы) → a card → View (Посмотреть)
1. Click the source link to read the files at the author's repository.
2. Click Install (Установить) at the bottom right to choose where to install.

## Install a skill

<!-- id: market-skill-install; covers: -->
Install (Установить) asks where: All agents on the server (Всем агентам на сервере) puts the skill where every agent that
reads the server user's skills has it; One agent (Одному агенту) puts it in that agent's folder only, and a list lets you
pick the agent. A place that is not free is greyed out with the reason: Installed (Установлено), or Name taken (Имя
занято) for a folder of the same name that is not Bandito's. Bandito never overwrites such a folder and has no button for
it: move or rename the folder yourself, then install.
Где: Marketplace → Skills (Скиллы) → Install (Установить)
1. Choose All agents on the server (Всем агентам на сервере) or One agent (Одному агенту) and pick the agent.
2. Click Install (Установить). The skill is on the server a moment later and the card shows its state.

## Remove a skill

<!-- id: market-skill-remove; covers: -->
Remove (Удалить) deletes the folder Bandito installed, after you confirm. Removing the server's copy takes the skill
from every agent that used it; removing an agent's copy touches that agent's folder only. A folder Bandito did not make is
never removed.
Где: Marketplace → Skills (Скиллы) → Remove (Удалить) on an installed card, or on the skill's page
1. Click Remove (Удалить) and confirm in the dialog.

## Updates

<!-- id: market-updates; covers: -->
When the catalog has moved on, Bandito says so and updates in one click. A connected service shows Update available (Есть
обновление) with the old and the new version of its package, for example 1.2.0 → 1.3.0, or New service address (Новый адрес
сервиса) when the service's address changed, and the button Update (Обновить). Update takes the command and the address
from the catalog; your keys, headers and variables, and whether the service is on for the agents, stay as they are. A skill
whose installed copy is older than the catalog's shows Update (Обновить) instead of Installed (Установлено): it installs
the catalog's copy in the same place, for the server or for the agent, and its page marks each place that is behind. Agents
pick up a new service definition at their next session.
Где: Marketplace → Services (Сервисы) → a connected card → Update (Обновить); Marketplace → Skills (Скиллы) → a card or its page → Update (Обновить)
1. Click Update (Обновить). The button says Updating… (Обновляем…) while it works.
2. If it fails, the reason shows under the list, as for the other actions of the card.

## Suited to the project

<!-- id: market-recommend; covers: -->
On the Services page, above the catalog, a row Suited to the project of <agent> (Подойдут для проекта <агент>) suggests up
to six services that are not connected yet. The server looks at the agent's project folder (the folder itself and the
folders directly in it: a git remote on GitHub, package.json, a Sentry or Supabase config, and the like) and each card says
why in small text, with the file that showed it in monospace. The agent is the one open in the window, else the last one
you opened. The row shows under All (Все) with an empty search, and only when the server can suggest and has an agent.
Connect (Подключить) works as on the other cards, including the sign-in in the browser. The cross at the right hides the
row for that agent on this server; another agent gets its own row.
Где: Marketplace → Services (Сервисы) → the row above the catalog → Connect (Подключить), cross (Скрыть подсказки)
1. Click Connect (Подключить) on a suggestion. The service leaves the row once it is connected.
2. Click the cross to hide the row for this agent.

## Tools of a service

<!-- id: market-tools; covers: -->
The page of a connected service has a section Tools (Инструменты) that says what the agents may do with its tools. Three
segments set the mode for the whole service: Everything (Всё) lets the agents use every tool as their approval mode says;
With confirmation (С подтверждением) runs the tools that only read and asks you before each tool that changes something;
Read only (Только чтение) runs the tools that only read and refuses the rest, in every approval mode, even when the agent's approval is Nothing
(Ничего). A new service from the catalog starts With confirmation; one you add yourself starts with
Everything. Under the segments every tool the last check found is listed, marked reads (читает), changes (меняет) or
deletes (удаляет), with three words: Allow (Разрешить), Ask (Спрашивать), Deny (Запретить). The word of a tool wins over
the mode; a word that equals what the mode does anyway is not kept. A tool the service did not mark as only reading counts
as one that changes something, and so does every tool of a service that was never checked: use Check (Проверить) to list
them. The refusal reaches the agent with a sentence that says who forbade it, so it does not retry. A question is an
ordinary approval card in the chat with the service, the tool and its arguments (long values cut). The settings are
kept by Bandito for agents that run on Claude. An agent on Codex or Grok cannot be held to them, so when the mode is not
Everything (or a tool has Ask or Deny) the service is not given to such an agent at all: its prompt says the owner limited
it, and the section lists these agents by name.
Где: Marketplace → Services (Сервисы) → a connected service → View (Посмотреть) → Tools (Инструменты)
1. Click a segment to set the mode. The line under it says what it does.
2. Click Allow (Разрешить), Ask (Спрашивать) or Deny (Запретить) on a tool to give it a word of its own.
3. Click Check (Проверить) when the section says no tools are known yet.

## Journal of calls

<!-- id: market-journal; covers: -->
Bandito keeps a journal of every call an agent makes to a tool of a service: who, which tool, when, how long it took and how
it ended, for 30 days. A connected card shows the last day in one line, for example 12 calls in 24 hours · 1 error (12
вызовов за сутки · 1 ошибка); a service with no call in the last day shows nothing. The page of the service has a section
Journal (Журнал): the newest calls first, each with the agent's picture and name, the tool, the time (the clock for today,
the date too for another day), the duration, a tick or a cross for the end, the error's first line when it failed, and, in
quiet type, what Bandito did with the call: allowed (разрешено), you were asked (спросили вас) or denied (отказано). A call
that has no result (the turn ended, or the agent stopped) says No result (Нет итога). Arguments and results are not kept.
Где: Marketplace → Services (Сервисы) → a connected service → View (Посмотреть) → Journal (Журнал)
1. Click Show more (Показать ещё) under the list to read older calls.
2. With no calls yet, the section says so in one line.

## Try a tool

<!-- id: market-try; covers: -->
Each tool in the Tools (Инструменты) section has Try (Попробовать): it opens a form under the tool, made from the tool's own
description of its arguments. A text, a number and a whole number are fields; a yes or no and a list of values are
choices (Not set, Yes, No; or the values the tool accepts); a required field is marked required (обязательно), and the
tool's own words about a field are under its name. An argument that is a list, an object or one of several shapes is a
field of JSON text, which is checked before anything is sent; a tool whose arguments are not described takes one JSON
object. Run (Запустить) calls the tool through the server, as you and not as an agent, whatever the service's mode says. A
tool that is not marked as only reading asks first: This will change data in <service> (Это действие изменит данные в
<сервис>). The answer is under the form: the tool's text in monospace in a box that scrolls, and the structured part as
JSON. If the tool says it failed, the box is marked The tool answered with an error (Инструмент ответил ошибкой). If the call
itself did not go through (the service is off, no answer within 30 seconds, a sign-in that ended), the reason is shown.
Try is dimmed while the service is turned off; point at it to read why.
Где: Marketplace → Services (Сервисы) → a connected service → View (Посмотреть) → Tools (Инструменты) → Try (Попробовать)
1. Click Try (Попробовать) on a tool, fill in the fields, and click Run (Запустить).
2. A red line under a field says what to fix. Nothing is sent until every field is right.
3. Click Hide (Свернуть) to close the form.

## Import from Claude Code

<!-- id: market-import; covers: sheet:importer -->
Import from Claude Code (Импорт из Claude Code) brings what you already have for Claude Code and Codex into Bandito.
It reads these places on this Mac: the subagents in `~/.claude/agents`, the skills in `~/.claude/skills` (the whole
folder of each), the commands in `~/.claude/commands`, and the prompts in `~/.codex/prompts`. Add a project folder (Добавить
папку проекта) to read its `.claude/agents`, `.claude/skills` and `.claude/commands` too, and its `AGENTS.md`, which
becomes an agent named after the folder. Nothing else is read: no settings, no keys, no history. Nothing on the Mac is
changed or deleted, and a link is never followed, wherever it is on the way (a `.claude` that is a link is left alone too). A
file over 256 KB, or one that is not text, is not taken; a skill over 50 files or 2 MB, or one whose folder was only read in
part (too many files, or too deep), is not taken; the list under Found, but not taken (Найдено, но не взято) says which and why.
Each item has a check box, Preview (Просмотр) with the head of the file, and the folder it came from. An item whose text
looks like it holds a key or a password starts unchecked, with a line that says so; check it only if you are sure. A subagent becomes
an agent: its description (cut to a short role) is the role, its text is the instructions, its model is kept only when the
runtime you choose offers it, and its tools set what it may do: Bash is the terminal, Edit, Write, MultiEdit and NotebookEdit
are the files, WebFetch and WebSearch are the browser; a file that lists no tools leaves everything on. Pick the runtime in
Create agents on (Создавать агентов на); the default is Claude. A skill or a command is installed for every agent on the
server, with Bandito's commands and skills. If a name is taken (an agent with that name, a command or a skill the server
has, or another item of the same list), the item is marked Name taken (Имя занято): Rename (Переименовать) with a new name
(a free one is suggested), or Skip (Пропустить). Bandito never replaces what the server has. A line in orange warns of
such a file, of files of a skill that were left out (not text, or named like a key: `.env`, `*.pem`, `*.key`, `id_rsa`,
`id_ed25519`, `credentials`, `*.p12`; and hidden files, which are named in Found, but not taken and in the preview as Not sent (Не будет отправлено); none of them is ever copied, and the skill is installed without them), or of a model the
runtime does not have. Import (Импортировать) makes the checked items one after the other; Stop (Остановить) ends it after the one that is
being made. The screen then reports what was Created (Создано), Skipped (Пропущено, with the reason, and the items that
were not reached) and Failed (Не получилось).
Где: Marketplace → Services (Сервисы) → Import from Claude Code (Импорт из Claude Code), or the menu File → Import from Claude Code… (Файл → Импорт из Claude Code…)
1. Open the screen. Everything found is checked; clear what you do not want, or use Clear (Снять выбор) for a group.
2. Click Preview (Просмотр) to read an item, and Add a project folder (Добавить папку проекта) to look in a project.
3. Settle every Name taken (Имя занято): Rename (Переименовать) or Skip (Пропустить).
4. Choose Create agents on (Создавать агентов на) and click Import (Импортировать).
5. Read the report and click Done (Готово).


## Share a bot

<!-- id: market-share; covers: sheet:share -->
Share... (Поделиться...) in the menu (⋯) of a bot in My bots publishes the bot as a link: the bot's settings without its secrets, memory, folders or accounts, with the services it may use as catalog names. The box at the top shows exactly what goes out; long text is cut to twelve lines until you choose Show all (Показать всё). Visibility is one of two cards: Public (Публично) is listed and found by search engines; Only by link (Только по ссылке) works for whoever has the link and nobody else. You set the name and the description. Publish (Опубликовать) gives the link, with Copy link (Скопировать ссылку) and a QR code for a phone. Without a sign-in the sheet says Sign in to share (Войдите, чтобы делиться) and opens Account.
Где: Marketplace → Bots (Боты) → My bots (Мои боты) → the menu (⋯) of a bot → Share... (Поделиться...)
1. Read what goes out in the box, and choose a visibility card.
2. Click Publish (Опубликовать). A second click while it runs does nothing.
3. Copy the link, or let a phone scan the code.

## Install a shared bot or skill

<!-- id: market-install-shared; covers: sheet:installShared -->
A link to a shared bot or skill (bandito.dev/s/...) opens this sheet: what it is, who made it, its version and a warning that the community made it, so check the prompt before you run it. A bot shows its capabilities as switches. Running commands, seeing the screen and managing other agents are off by default and marked as risky; turn them on only if you need them. After Add bot (Добавить бота) the schedules are created switched off, and the sheet lists the services that are not connected yet and the ones the catalog does not know. Open the bot (Открыть бота) opens its chat with the first message in the input field. A skill with scripts needs the tick I understand that agents will be able to run these scripts (Понимаю, что агенты смогут запускать эти скрипты) before Install skill (Установить скилл) becomes active; a skill whose name is already yours is not overwritten. Report (Пожаловаться) sends a reason; five reports hide the share until it is reviewed.
Где: a link to bandito.dev/s/... pasted into the Marketplace search, or the bandito://install link from a web page
1. Read the author, the version and the warning. For a bot, read the capabilities and the prompt.
2. Click Add bot (Добавить бота) or Install skill (Установить скилл).
3. Switch on the schedules in the bot's settings once you have checked the prompt.

## My shares

<!-- id: market-my-shares; covers: sheet:myShares -->
My shares (Мои публикации) lists what your account published, with the version, the number of installs and whether the platform hid it after reports. Visibility switches between Public (Публично) and Only by link (Только по ссылке). Update to current version (Обновить до текущей версии) publishes the bot or skill again from the place it was shared from on this Mac, as the next version; a share from another Mac has no update button. Delete (Удалить) asks first, and the link stops working. The copies people already installed stay with them.
Где: Marketplace → My shares (Мои публикации) beside the page switch
1. Change the visibility with the switch in a row.
2. Click Update to current version (Обновить до текущей версии) after you change the bot or skill.
3. Click Delete (Удалить) and confirm.
