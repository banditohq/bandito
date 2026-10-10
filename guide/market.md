# Marketplace (Маркетплейс)

The services the agents can use: MCP servers that you connect once, on the server, and every agent can then use
their tools. The mode lists the catalog, shows what is connected, and has a page for every service. Open it with ⌘6.

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
