# Marketplace (Маркетплейс)

The services the agents can use: MCP servers that you connect once, on the server, and every agent can then use
their tools. The mode lists the catalog and shows what is connected. Open it with ⌘6.

## Marketplace mode

<!-- id: market-mode; covers: mode:market -->
The main area lists the services. The connected ones are in one row at the top; the catalog follows without them. Each
connected card shows its address and the result of the last check: the number of tools, the error, or Not checked yet.
Где: sidebar footer → Marketplace button (Маркетплейс), or Menu View → Go to Marketplace (Маркетплейс)
1. Press ⌘6, or click the Marketplace button at the bottom left of the sidebar, between your profile and the usage button.
2. The button is lit while the Marketplace is on show. It is not in the mode bar at the top of the sidebar.
3. Without a server, the page says No servers (Нет серверов). Click Add server (Добавить сервер).

## Filters

<!-- id: market-filters; covers: -->
The sidebar lists two filters: All (Все) shows the connected row and the catalog of the services that are not connected;
Connected (Подключённые) shows only the connected services.
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
The switch Available to agents (Доступно агентам) on a connected card turns the service on or off for the agents. The
menu (…) on the card has Check (Проверить), Edit (Изменить) and Remove (Удалить). Remove takes the service off the
server: the agents lose its tools. Its secrets stay on the server.
Где: Marketplace → connected card → Available to agents (Доступно агентам) switch, or the menu (…) → Check (Проверить), Edit (Изменить), Remove (Удалить)
1. Click the menu (…) on the card and choose Remove (Удалить). Confirm in the dialog.
2. Click Configure (Настроить) on a catalog card to change the settings of a connected service.

## Own integration

<!-- id: market-own; covers: -->
Own integration (Своя интеграция) adds a service that is not in the catalog: a program the server starts, or a web
address. It is listed with the connected services.
Где: Marketplace → Own integration (Своя интеграция)
1. Choose Program (Программа) or Web address (Адрес), fill in the fields and click Connect (Подключить).
