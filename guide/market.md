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
and the links Documentation (Документация) and Website (Сайт). A connected service also shows its status, the tools
from the last check, the switch Available to agents (Доступно агентам), Check (Проверить) and Remove (Удалить).
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

