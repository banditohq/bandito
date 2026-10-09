# Terminals (Терминалы)

Real shells on the server, shown in panes. A terminal keeps running on the server when the app is closed. Open the mode with ⌘3.

## Terminals mode

<!-- id: terminals-mode; covers: mode:terminals -->
The sidebar lists the terminals On screen (На экране), Collapsed (Свёрнуты) and the empty state No terminals (Терминалов нет). The main area shows the panes in the chosen layout.
Где: Mode bar → Terminals (Терминалы), or Menu View → Terminals (Терминалы)
1. Press ⌘3 or click Terminals (Терминалы) in the mode bar.
2. If the server has no terminals, the screen says No terminals yet. A terminal keeps running on the server, even when this app is closed. Click New terminal (Новый терминал).

## New terminal (Новый терминал)

<!-- id: terminals-new; covers: -->
Opens a new shell on the server in the default folder, or in the folder of a selected agent or file.
Где: Terminals → toolbar → New terminal (Новый терминал) (⌘T); Menu Terminals → New terminal (Новый терминал)
1. Press ⌘T or choose New terminal (Новый терминал) from the Terminals menu.
2. To start a terminal in an agent's folder, use /terminal in the Team mode or Terminal here in Files (see [files.md](files.md)).
3. If the server is not reachable, the message says Could not open a terminal: … and offers Retry (Повторить).

## Split a pane

<!-- id: terminals-split; covers: -->
Adds a new pane next to the focused one. If there is no room, the app says No room on screen. Collapse or close a pane first.
Где: Terminals → pane → Split (Разделить); Menu Terminals → Split vertically (Разделить вертикально) / Split horizontally (Разделить горизонтально)
1. Press ⌘D to split vertically, or ⌘⇧D to split horizontally.

## Layouts (Layout)

<!-- id: terminals-layout; covers: -->
Four ways to arrange the panes on screen: One window (Одно окно), Side by side (Рядом), Main and two on the right (Главное и два справа), and Grid 2×2 (Grid 2×2). At most as many panes as the layout has room for are on screen; the rest wait in the dock.
Где: Terminals → toolbar → Layout (Расположение)
1. Click Layout (Расположение) and choose the arrangement.

## Move between panes

<!-- id: terminals-move; covers: -->
Moves the focus to the pane in that direction.
Где: Menu Terminals → Pane to the left (Панель слева), Pane to the right (Панель справа), Pane above (Панель сверху), Pane below (Панель снизу)
1. Press ⌥⌘← (left), ⌥⌘→ (right), ⌥⌘↑ (above), or ⌥⌘↓ (below).

## Collapse a pane and bring it back

<!-- id: terminals-collapse; covers: -->
Collapse (keeps running) moves the pane out of the screen into the dock. Its process keeps running, and the dock keeps following its output. Collapse is not close.
Где: Terminals → pane → Collapse — keeps running; Menu Terminals → Collapse (keeps running); dock → Restore (Вернуть)
1. Press ⌘⇧↓ to collapse the focused pane. The dock on the side shows it with waiting for input (waiting for input) or running (running) and the count of new lines (+N lines).
2. Press ⌘⇧T (Bring back last collapsed) to bring back the last collapsed pane, or click Restore (Вернуть) in the dock.

## Close a terminal

<!-- id: terminals-close; covers: -->
Ends the process in the pane. If the process is still running, the app asks first.
Где: Terminals → pane → Close and end the process (Закрыть и завершить); Menu Terminals → Close (ends the process) (Close (ends the process))
1. Press ⌘W. If the process is running, the question The process is still running. End it? appears.
2. Click End process (Завершить) to end it, or Cancel (Отмена) to keep it.

## Clear the screen

<!-- id: terminals-clear; covers: -->
Clears the text in the focused terminal. The process is not stopped.
Где: Menu Terminals → Clear (Очистить)
1. Press ⌘⇧K.

## Text size (Размер текста)

<!-- id: terminals-font; covers: -->
Changes the text size of all terminals together. The same value is used for new terminals.
Где: Menu Terminals → Font bigger (Крупнее), Font smaller (Мельче), Reset font size (Сбросить размер); Settings → Terminal and files (Терминал и файлы) → Text size (Размер текста)
1. Press ⌘+ to make the text bigger, ⌘− to make it smaller, or ⌘0 to reset it.
2. The same size is set in Settings (⌘,) → Terminal and files → Text size (Размер текста), with a stepper.

## Full screen pane (Full screen, Back to the grid)

<!-- id: terminals-fullscreen; covers: -->
Makes one pane fill the screen. Back to the grid (Вернуть в сетку) returns to the layout.
Где: Terminals → pane → Full screen (На весь экран) / Back to the grid (Вернуть в сетку)
1. Click Full screen (На весь экран) on the pane, or spread two fingers over it on the trackpad (Pinch out — full screen).
2. Click Back to the grid (Вернуть в сетку), or pinch in.

## Rename a pane (Name)

<!-- id: terminals-rename; covers: -->
Gives a pane a name, so it is easy to find in the sidebar.
Где: Terminals → pane → double-click the title (Double-click to rename)
1. Double-click the title, type the name, and press ↵.

## Restart after the process ended (Restart)

<!-- id: terminals-restart; covers: -->
When the process in a pane has ended, the pane says so with the exit code or signal, and offers a restart.
Где: Terminals → pane → Process ended (code N) (Process ended (code {code})) → Restart (Перезапустить)
1. Read the message: Process ended (Процесс завершился), Process ended (code N), or Process ended (signal …).
2. Click Restart (Перезапустить) to start the shell again in the same folder.

## Input to all panes (Input to all)

<!-- id: terminals-input-all; covers: -->
A switch that sends what you type in the focused pane to every pane on screen. Use it for the same command on several servers' panes or in several folders.
Где: Terminals → toolbar → Input to all (Ввод во все)
1. Switch Input to all (Ввод во все) on. The hint says: What you type in the focused pane goes to every pane on screen.
2. Switch it off when you are done.

## Terminal errors (Terminal error, Update the server to use terminals)

<!-- id: terminals-errors; covers: -->
Shown in the pane when the connection or the server cannot run a terminal.
Где: Terminals → pane → message
1. Terminal error: … (Terminal error: {message}): click Retry (Повторить) on the banner.
2. Update the server to use terminals: the server runs an older Bandito. Update it from Server → Updates (see [server.md](server.md)).
3. No server selected (Сервер не выбран): choose a server in the top bar.
