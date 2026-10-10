# Marketplace (Маркетплейс)

The services the agents can use: MCP servers that you connect once, on the server, and every agent can then use
their tools. The mode lists the catalog and shows what is connected. Open it with ⌘6.

## Marketplace mode

<!-- id: market-mode; covers: mode:market -->
The main area lists the services. The connected ones are in one row at the top; the catalog follows. Each connected
card has a status dot: green is working, red is a failed check, grey is not checked yet (or off).
Где: Mode bar → Marketplace (Маркетплейс), or Menu View → Go to Marketplace (Маркетплейс)
1. Press ⌘6 or click Marketplace (Маркетплейс) in the mode bar.
2. Without a server, the page says No servers (Нет серверов). Click Add server (Добавить сервер).

## Filters

<!-- id: market-filters; covers: -->
The sidebar lists two filters: All (Все) shows the connected row and the whole catalog; Connected (Подключённые) shows
only the connected services.
Где: Marketplace → sidebar → All (Все), Connected (Подключённые)
1. Click Connected (Подключённые) to hide the services that are not connected.
2. With no connected service, the page says Nothing is connected yet (Ничего ещё не подключено).

## Search

<!-- id: market-search; covers: -->
The search field at the top right finds services by name and by description. It ignores case and spaces at the ends.
Где: Marketplace → search field (Поиск)
1. Type part of the name or the description. A search with no match says Nothing found (Ничего не нашлось).

## Connect a service

<!-- id: market-connect; covers: -->
Connect (Подключить) opens the sheet with the service's settings: the command or the address, the variables and the
headers. The sheet can check the connection before you save.
Где: Marketplace → a catalog card → Connect (Подключить)
1. Fill in the secrets. They are kept on the server; the app does not show them again.
2. Click Check (Проверить) to see the tools the service offers.
3. Click Connect (Подключить) to save. The card then shows Connected (Подключено) and Configure (Настроить).

## Configure, turn off, remove

<!-- id: market-configure; covers: -->
Click a connected card, or Configure (Настроить), to change its settings. Right-click a connected card for the menu:
Available to agents (Доступно агентам) turns the service on or off for the agents; Remove (Удалить) takes it off the
server. The agents lose its tools. Its secrets stay on the server.
Где: Marketplace → connected card → right-click → Available to agents (Доступно агентам), Edit (Изменить), Remove (Удалить)
1. Right-click the card and choose Remove (Удалить). Confirm in the dialog.

## Own integration

<!-- id: market-own; covers: -->
Own integration (Своя интеграция) adds a service that is not in the catalog: a program the server starts, or a web
address. It is listed with the connected services.
Где: Marketplace → Own integration (Своя интеграция)
1. Choose Program (Программа) or Web address (Адрес), fill in the fields and click Connect (Подключить).
