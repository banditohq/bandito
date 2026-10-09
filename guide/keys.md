# Keys (Клавиши)

Every command of the app, with the default shortcut and where to find it. The shortcuts shown are the defaults of the
`Bandito` preset. Each command is listed once, in the order of its context.

## How to change a shortcut

<!-- id: keys-change; covers: -->
Changes are made in Settings. A shortcut can be replaced, removed or reset, and presets change many at once.
Где: Settings (⌘,) → Keys and gestures (Клавиши и жесты) → Keys (Клавиши)
1. Find the command with the search field Find an action or press a shortcut (Найти действие или нажмите сочетание), or by its context.
2. Click the shortcut in the row, then press the new keys.
3. If another command in the same context or a global command has the same keys, the row shows taken by: {name}. Click Replace (Заменить) to move the shortcut to this command.
4. A preset in the list (Bandito, Like VS Code, Like iTerm, Like Slack) changes only the commands it names. Reset all (Сбросить всё) returns every shortcut to the Bandito defaults.
5. Export (Экспорт) saves all changed shortcuts to a file. Import (Импорт) loads such a file.
6. Text fields keep their system shortcuts (⌘A, ⌘Z, ⌘C). The composer sends on ↵ and makes a new line on ⇧↵.

## Quick open (Быстрый переход)

<!-- id: key-global-quickopen; covers: command:global.quickOpen -->
Opens the palette that finds agents, files, terminals, ports and commands.
Где: Go → Quick open (Быстрый переход); Sidebar → Search (⌘K)
1. Press ⌘K.
2. Type a name, a file, a terminal or a command, then press ↵.
Хоткей: ⌘K

## Go to Team (Команда)

<!-- id: key-global-mode-team; covers: command:global.mode.team -->
Switches the main window to the Team mode (agents and chats).
Где: View → Go to Team (Команда)
1. Press ⌘1, or choose the item in the View menu.
Хоткей: ⌘1

## Go to Files (Файлы)

<!-- id: key-global-mode-files; covers: command:global.mode.files -->
Switches the main window to the Files mode.
Где: View → Go to Files (Файлы)
1. Press ⌘2, or choose the item in the View menu.
Хоткей: ⌘2

## Go to Terminals (Терминалы)

<!-- id: key-global-mode-terminals; covers: command:global.mode.terminals -->
Switches the main window to the Terminals mode.
Где: View → Go to Terminals (Терминалы)
1. Press ⌘3, or choose the item in the View menu.
Хоткей: ⌘3

## Go to Browser (Браузер)

<!-- id: key-global-mode-browser; covers: command:global.mode.browser -->
Switches the main window to the Browser mode of the server.
Где: View → Go to Browser (Браузер)
1. Press ⌘4, or choose the item in the View menu.
Хоткей: ⌘4

## Go to Server screen (Экран сервера)

<!-- id: key-global-mode-screen; covers: command:global.mode.screen -->
Switches the main window to the Server screen mode.
Где: View → Go to Server screen (Экран сервера)
1. Press ⌘5, or choose the item in the View menu.
Хоткей: ⌘5

## Go to Server (Сервер)

<!-- id: key-global-mode-server; covers: command:global.mode.server -->
Switches the main window to the Server mode (health, workplaces, secrets, ports, devices, updates).
Где: View → Go to Server (Сервер)
1. Press ⌘6, or choose the item in the View menu.
Хоткей: ⌘6

## New agent (Новый агент)

<!-- id: key-global-newagent; covers: command:global.newAgent -->
Opens the New agent sheet.
Где: Agent → New agent (Новый агент); Sidebar → New agent (⌘N)
1. Press ⌘N to open the New agent sheet (see [new-agent.md](new-agent.md)).
Хоткей: ⌘N

## Back (Назад)

<!-- id: key-global-back; covers: command:global.back -->
Returns to the previously shown mode.
Где: Go → Back (Назад)
1. Press ⌘[ to go to the previous mode.
2. The item is greyed out when there is no history.
Хоткей: ⌘[

## Forward (Вперёд)

<!-- id: key-global-forward; covers: command:global.forward -->
Goes forward again after Back.
Где: Go → Forward (Вперёд)
1. Press ⌘] to go forward again after Back.
2. The item is greyed out when there is nothing to go forward to.
Хоткей: ⌘]

## Toggle sidebar (Боковая панель)

<!-- id: key-global-togglesidebar; covers: command:global.toggleSidebar -->
Hides or shows the sidebar.
Где: View → Toggle sidebar (Боковая панель)
1. Press ⌃⌘S to hide or show the sidebar.
Хоткей: ⌃⌘S

## Usage limits (Лимиты подписок)

<!-- id: key-global-usage; covers: command:global.usage -->
Opens or closes the subscription limits popover.
Где: View → Usage limits (Лимиты подписок)
1. Press ⌥⌘U to open the subscription limits popover (see [settings.md](settings.md) for the list of limits).
Хоткей: ⌥⌘U

## Settings (Настройки)

<!-- id: key-global-settings; covers: command:global.settings -->
Opens the Settings window.
Где: Bandito → Settings (Настройки)
1. Press ⌘, to open the Settings window (see [settings.md](settings.md)).
Хоткей: ⌘,

## Search all history (Поиск по всей истории)

<!-- id: key-global-searchhistory; covers: command:global.searchHistory -->
Opens the palette to search across everything, including history.
Где: Go → Search all history (Поиск по всей истории)
1. Press ⇧⌘F to open the palette with the focus on the search of everything.
Хоткей: ⇧⌘F

## Previous agent (Предыдущий агент)

<!-- id: key-team-previousagent; covers: command:team.previousAgent -->
Selects the agent above the current one in the sidebar order.
Где: Go → Previous agent (Предыдущий агент)
1. Press ⌥⌘↑ to select the agent above in the sidebar order.
Хоткей: ⌥⌘↑

## Next agent (Следующий агент)

<!-- id: key-team-nextagent; covers: command:team.nextAgent -->
Selects the agent below the current one in the sidebar order.
Где: Go → Next agent (Следующий агент)
1. Press ⌥⌘↓ to select the agent below in the sidebar order.
Хоткей: ⌥⌘↓

## Go to who needs you (К тому, кто ждёт вас)

<!-- id: key-team-needsyou; covers: command:team.needsYou -->
Opens the first agent that waits for your decision.
Где: Go → Go to who needs you (К тому, кто ждёт вас)
1. Press ⇧⌘A to open the first agent that waits for you.
Хоткей: ⇧⌘A

## Approve focused request (Разрешить выбранный запрос)

<!-- id: key-team-approve; covers: command:team.approve -->
Approves the approval request of the selected agent.
Где: Agent → Approve focused request (Разрешить выбранный запрос)
1. Select an agent with a pending approval.
2. Press ⌘↵ to approve. The item is greyed out when nothing waits.
Хоткей: ⌘↵

## Deny focused request (Отклонить выбранный запрос)

<!-- id: key-team-deny; covers: command:team.deny -->
Denies the approval request of the selected agent.
Где: Agent → Deny focused request (Отклонить выбранный запрос)
1. Select an agent with a pending approval.
2. Press Esc (⎋) to deny it. The item is greyed out when nothing waits.
Хоткей: ⎋ (Esc)

## Stop agent (Остановить агента)

<!-- id: key-team-stop; covers: command:team.stop -->
Stops the turn that is running for the selected agent.
Где: Agent → Stop agent (Остановить агента)
1. Select an agent.
2. Press ⌘. to stop its turn. The item is greyed out with no agent selected.
Хоткей: ⌘.
## Pause all agents (Пауза для всех агентов)

<!-- id: key-team-pauseall; covers: command:team.pauseAll -->
Pauses every agent of the current server, or resumes them all when they are all paused already. Paused agents keep their messages and start nothing until they are resumed (see [team.md](team.md)).
Где: Agent → Pause all agents (Пауза для всех агентов)

## What changed (Что изменил агент)

<!-- id: key-team-whatchanged; covers: command:team.whatChanged -->
Opens the list of files the selected agent changed, with rollback.
Где: Agent → What changed (Что изменил агент)
1. Select an agent.
2. Press ⇧⌘D to open the list of changes (see [team.md](team.md)).
Хоткей: ⇧⌘D

## Agent details (Сведения об агенте)

<!-- id: key-team-agentdetails; covers: command:team.agentDetails -->
Opens or closes the agent details inspector.
Где: Agent → Agent details (Сведения об агенте)
1. Select an agent.
2. Press ⌘I to open or close the inspector.
Хоткей: ⌘I

## New terminal (Новый терминал)

<!-- id: key-terminals-new; covers: command:terminals.new -->
Opens a new terminal on the server.
Где: Terminals → New terminal (Новый терминал)
1. Open the Terminals mode with ⌘3 (the menu item works only there).
2. Press ⌘T.
Хоткей: ⌘T

## Split vertically (Разделить вертикально)

<!-- id: key-terminals-splitvertical; covers: command:terminals.splitVertical -->
Splits the focused pane into two side by side.
Где: Terminals → Split vertically (Разделить вертикально)
1. In the Terminals mode, press ⌘D to split the focused pane.
Хоткей: ⌘D

## Split horizontally (Разделить горизонтально)

<!-- id: key-terminals-splithorizontal; covers: command:terminals.splitHorizontal -->
Splits the focused pane into two, one above the other.
Где: Terminals → Split horizontally (Разделить горизонтально)
1. In the Terminals mode, press ⇧⌘D to split the focused pane horizontally.
Хоткей: ⇧⌘D

## Collapse (keeps running) (Свернуть)

<!-- id: key-terminals-collapse; covers: command:terminals.collapse -->
Moves the focused pane to the dock; its process keeps running.
Где: Terminals → Collapse (keeps running) (Свернуть)
1. In the Terminals mode, press ⇧⌘↓. The pane goes to the dock and keeps running.
Хоткей: ⇧⌘↓

## Bring back last collapsed (Вернуть последний свёрнутый)

<!-- id: key-terminals-restorecollapsed; covers: command:terminals.restoreCollapsed -->
Brings the last collapsed pane back to the screen.
Где: Terminals → Bring back last collapsed (Вернуть последний свёрнутый)
1. Press ⇧⌘T to bring back the last collapsed pane.
Хоткей: ⇧⌘T

## Pane to the left (Панель слева)

<!-- id: key-terminals-paneleft; covers: command:terminals.paneLeft -->
Moves the focus to the pane on the left.
Где: Terminals → Pane to the left (Панель слева)
1. Press ⌥⌘← to move the focus to the pane on the left.
Хоткей: ⌥⌘←

## Pane to the right (Панель справа)

<!-- id: key-terminals-paneright; covers: command:terminals.paneRight -->
Moves the focus to the pane on the right.
Где: Terminals → Pane to the right (Панель справа)
1. Press ⌥⌘→ to move the focus to the pane on the right.
Хоткей: ⌥⌘→

## Pane above (Панель сверху)

<!-- id: key-terminals-paneup; covers: command:terminals.paneUp -->
Moves the focus to the pane above.
Где: Terminals → Pane above (Панель сверху)
1. Press ⌥⌘↑ to move the focus to the pane above.
Хоткей: ⌥⌘↑

## Pane below (Панель снизу)

<!-- id: key-terminals-panedown; covers: command:terminals.paneDown -->
Moves the focus to the pane below.
Где: Terminals → Pane below (Панель снизу)
1. Press ⌥⌘↓ to move the focus to the pane below.
Хоткей: ⌥⌘↓

## Close (ends the process) (Закрыть)

<!-- id: key-terminals-close; covers: command:terminals.close -->
Closes the focused terminal and ends its process.
Где: Terminals → Close (ends the process) (Закрыть)
1. Press ⌘W. If the process runs, confirm End process (Завершить).
Хоткей: ⌘W

## Clear (Очистить)

<!-- id: key-terminals-clear; covers: command:terminals.clear -->
Clears the screen of the focused terminal.
Где: Terminals → Clear (Очистить)
1. Press ⇧⌘K to clear the focused terminal. The process keeps running.
Хоткей: ⇧⌘K

## Font bigger (Крупнее)

<!-- id: key-terminals-fontbigger; covers: command:terminals.fontBigger -->
Makes the text of all terminals bigger.
Где: Terminals → Font bigger (Крупнее)
1. Press ⌘+ to make the text of all terminals bigger.
Хоткей: ⌘+

## Font smaller (Мельче)

<!-- id: key-terminals-fontsmaller; covers: command:terminals.fontSmaller -->
Makes the text of all terminals smaller.
Где: Terminals → Font smaller (Мельче)
1. Press ⌘− to make the text of all terminals smaller.
Хоткей: ⌘−

## Reset font size (Сбросить размер)

<!-- id: key-terminals-fontreset; covers: command:terminals.fontReset -->
Resets the text size of the terminals to the default.
Где: Terminals → Reset font size (Сбросить размер)
1. Press ⌘0 to reset the text size.
Хоткей: ⌘0

## Open (Открыть)

<!-- id: key-files-open; covers: command:files.open -->
Opens the selected folder, or the selected file in the viewer.
Где: Files → Open (Открыть), in the context menu of an item
1. Select an item in Files (⌘1…⌘6 mode Files: ⌘2).
2. Press ⌘↓. A folder opens; a file opens in the viewer.
Хоткей: ⌘↓

## Enclosing folder (Родительская папка)

<!-- id: key-files-enclosingfolder; covers: command:files.enclosingFolder -->
Opens the folder that contains the current one.
Где: Files → Enclosing folder (Родительская папка)
1. In Files, press ⌘↑ to go to the folder above.
Хоткей: ⌘↑

## Quick look (Быстрый просмотр)

<!-- id: key-files-quicklook; covers: command:files.quickLook -->
Shows a quick preview of the selected file.
Где: Files → Quick look (Быстрый просмотр)
1. Select a file and press Space. Press Space again to close.
Хоткей: Space

## New folder (Новая папка)

<!-- id: key-files-newfolder; covers: command:files.newFolder -->
Creates a new folder in the current folder.
Где: Files → New → Folder (Папка)
1. In Files, press ⇧⌘N, type the name, and click Create.
Хоткей: ⇧⌘N

## New file (Новый файл)

<!-- id: key-files-newfile; covers: command:files.newFile -->
Creates a new empty file in the current folder.
Где: Files → New → File (Файл)
1. In Files, press ⌥⌘N, type the name, and click Create.
Хоткей: ⌥⌘N

## Rename (Переименовать)

<!-- id: key-files-rename; covers: command:files.rename -->
Renames the selected item.
Где: Files → Rename (Переименовать)
1. Select an item and press ↵, type the new name, and press ↵ again.
Хоткей: ↵

## Move to Trash (В корзину)

<!-- id: key-files-trash; covers: command:files.trash -->
Moves the selected item to the server's Trash.
Где: Files → Move to Trash (В корзину)
1. Select an item and press ⌘⌫. The item goes to Trash, not deleted for good.
Хоткей: ⌘⌫

## Copy path (Копировать путь)

<!-- id: key-files-copypath; covers: command:files.copyPath -->
Copies the full path of the selected item.
Где: Files → Copy path (Копировать путь)
1. Select an item and press ⌥⌘C. The path is copied.
Хоткей: ⌥⌘C

## Duplicate (Дублировать)

<!-- id: key-files-duplicate; covers: command:files.duplicate -->
Makes a copy of the selected item next to it.
Где: Files → Duplicate (Дублировать)
1. Select a file and press ⌘D to make a copy next to it.
Хоткей: ⌘D

## Read ⇄ Edit (Читать ⇄ Править)

<!-- id: key-viewer-toggleedit; covers: command:viewer.toggleEdit -->
Switches an open file between Read and Edit.
Где: Files → viewer → Read / Edit (Править)
1. Open a file. Press ⌘E to switch between Read and Edit.
Хоткей: ⌘E

## Side by side (Рядом)

<!-- id: key-viewer-sidebyside; covers: command:viewer.sideBySide -->
Shows the text of an open file and its preview side by side.
Где: Files → viewer → Side by side (Рядом)
1. Open a file. Press ⌥⌘↵ to show the text and the preview together.
Хоткей: ⌥⌘↵

## Save (Сохранить)

<!-- id: key-viewer-save; covers: command:viewer.save -->
Saves the open file to the server.
Где: Files → viewer → Save (Сохранить)
1. Edit a file and press ⌘S to save it.
Хоткей: ⌘S

## Next tab (Следующая вкладка)

<!-- id: key-viewer-nexttab; covers: command:viewer.nextTab -->
Switches to the next open file tab.
Где: Files → viewer → Next tab (Следующая вкладка)
1. With several files open, press ⌃⇥ to go to the next tab.
Хоткей: ⌃⇥

## Previous tab (Предыдущая вкладка)

<!-- id: key-viewer-previoustab; covers: command:viewer.previousTab -->
Switches to the previous open file tab.
Где: Files → viewer → Previous tab (Предыдущая вкладка)
1. Press ⌃⇧⇥ to go to the previous tab.
Хоткей: ⌃⇧⇥

## Address bar (Адресная строка)

<!-- id: key-browser-address; covers: command:browser.address -->
Moves the focus to the address bar of the browser.
Где: Browser → Address bar (Адресная строка)
1. Open the Browser mode with ⌘4.
2. Press ⌘L and type the address.
Хоткей: ⌘L

## Reload (Обновить)

<!-- id: key-browser-reload; covers: command:browser.reload -->
Reloads the current page in the browser.
Где: Browser → Reload (Обновить)
1. In the Browser mode, press ⌘R to load the page again.
Хоткей: ⌘R

## New tab (Новая вкладка)

<!-- id: key-browser-newtab; covers: command:browser.newTab -->
Opens a new tab in the browser on the server.
Где: Browser → New tab (Новая вкладка)
1. In the Browser mode, press ⌘T to open a new tab.
Хоткей: ⌘T

## Take / give back control (Взять / отдать управление)

<!-- id: key-browser-takecontrol; covers: command:browser.takeControl -->
Takes the control of the browser from the agent, or gives it back.
Где: Browser → Take / give back control (Взять / отдать управление)
1. When an agent drives the browser, press ⇧⌘C to take control. Press it again to give the control back.
Хоткей: ⇧⌘C

## Take / give back control (Взять / отдать управление)

<!-- id: key-screen-takecontrol; covers: command:screen.takeControl; status: planned -->
Takes the control of the server screen from the agent, or gives it back.
Где: Server screen → Take / give back control (Взять / отдать управление)
1. Press ⇧⌘C to take control of the server screen, or to give it back. The shortcut is fixed in this build: the row in Settings does not change it yet.
Хоткей: ⇧⌘C

## Send the key combination to the server (Отправить сочетание на сервер)

<!-- id: key-screen-sendctrlaltdelete; covers: command:screen.sendCtrlAltDelete; status: planned -->
Sends Ctrl+Alt+Del to the server screen.
Где: Server screen → toolbar button ⌃⌥⌫
1. Press ⌃⌥⌫ in the Server screen mode to send Ctrl+Alt+Del. The shortcut is fixed in this build: the row in Settings does not change it yet.
Хоткей: ⌃⌥⌫

