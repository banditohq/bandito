# Server (Сервер)

The health and the setup of the server that runs your agents: its load, what is installed, the workplaces, secrets,
open ports, paired devices and updates. Open the mode with ⌘6. The sections are switched at the top of the mode.

## Server mode

<!-- id: server-mode; covers: mode:server -->
The Server mode has seven sections: Overview (Обзор), Workplaces (Рабочие места), Secrets (Секреты), Ports (Порты), Devices (Устройства), Updates (Обновления), and Daemon log (Журнал демона). The current server is shown in the top bar.
Где: Mode bar → Server (Сервер), or Menu View → Server (Сервер)
1. Press ⌘6 or click Server (Сервер) in the mode bar.
2. Choose a section at the top. Each section keeps its own state.
3. To switch to another server, use the server picker in the top bar. Actions in progress are dropped when the server changes.

## Overview: load and health (Overview)

<!-- id: server-overview; covers: -->
The first screen: CPU, Memory, Disk and Network tiles, a health line, and the processes that use the most resources.
Где: Server → Overview (Обзор)
1. Read the health line: All good (Всё в порядке), Disk almost full (Диск почти полон), Memory almost full (Памяти почти не осталось), or Disk and memory almost full (Диск и память почти заполнены).
2. Switch the chart range: 1 h (1 h) or 24 h (24 h).
3. Read Who uses the most (Кто сколько ест): the agent processes with their CPU share. If nothing runs, the list says Nothing is running yet.

## Stop an agent's processes (Stop)

<!-- id: server-stop-processes; covers: -->
Stops all processes of one agent that use the server. Use it when an agent runs away with the CPU or memory.
Где: Server → Overview → Who uses the most → Stop processes of {name} (Stop processes of {name})
1. Click the stop button next to the agent. The question Stop {name}? appears.
2. Click Stop (Остановить). The processes get a stop signal. Those still running after 3 seconds are killed.
3. The agent itself is not deleted.

## Capabilities: components and install (Capabilities, Install)

<!-- id: server-capabilities; covers: -->
Shows what the server has: the Screen (Экран), the Browser (Браузер), Containers (Контейнеры), and the runtimes Claude Code, Codex and Grok. Each line has a state: Ready (Готово), Not installed (Не установлен), or Not available (Недоступно).
Где: Server → Overview → Capabilities (Возможности) → Install (Установить)
1. Read the states. Click Install (Установить) to install all missing items that can be installed here. The log shows the progress.
2. If an administrator password is needed, the card asks you to run the command in a Bandito terminal. Click Open terminal (Открыть терминал) and type the password there. See [getting-started.md](getting-started.md).
3. If an install fails, the message says Could not install … (Could not install {component}). See the log above it.

## Ports and previews (Порты и превью)

<!-- id: server-ports-overview; covers: -->
The card on Overview lists the ports that open on the server with their owner. A port can be opened in the Browser.
Где: Server → Overview → Ports and previews (Порты и превью)
1. Read the ports. If none are open, the card says No open ports.
2. Click Open (Открыть) next to a port to see it in the Browser (see [browser.md](browser.md)).

## Workplaces (Рабочие места)

<!-- id: server-workplaces; covers: -->
Shows where each agent works: its files, browser, screen and terminals. The screen explains the three kinds of workplace and lists the agents in each.
Где: Server → Workplaces (Рабочие места) → How to choose (Как выбрать)
1. Shared (Общее): the agent works on the same server as you. Quick and simple. Nothing to install.
2. Separate user (Отдельный пользователь): the agent has its own files, browser and screen. Bandito creates the user itself.
3. Container (Контейнер): full isolation: its own disk, network, and CPU and memory limits. Needs Docker or Podman.
4. The agents are listed under each kind (shared with the server, separate user, container · full isolation). Drag an agent to another workplace: it moves with its next task.
5. If the examples are off, the screen says there is nothing to show. Turn them on in Settings → General → Show examples (see [settings.md](settings.md)).
## Separate and container workplaces (planned)

<!-- id: server-workplaces-planned; covers: ; status: planned -->
Creating separate and container workplaces is not available in this build. The New agent sheet offers Shared only. Use Shared.
Где: Server → Workplaces (Рабочие места); New agent sheet → Workplace (Рабочее место)

## Secrets (Секреты)

<!-- id: server-secrets; covers: -->
Keys and passwords that agents need, stored on the server. An agent gets each secret as an environment variable. The values are never shown in the chat.
Где: Server → Secrets (Секреты) → Add secret (Добавить секрет)
1. Click Add secret (Добавить секрет). Type the Name (Имя), for example OPENAI_API_KEY. Use capitals, digits and _, up to 64 characters, not starting with a digit. Names such as PATH and HOME are refused.
2. Type the Value (Значение) and enter it again in Enter the value again (Введите значение заново). The value can be up to 64 KB. After saving, only the last four characters are visible.
3. Under Agents (Агенты), choose All agents (Все агенты) or pick the agents that get the secret.
4. Click Save (Сохранить).
5. To change a secret, click Change {name} (Change {name}) in its row. To remove it, click Delete {name} (Delete {name}) and confirm with Delete (Удалить). The agents that had it restart without it.

## Ports (Порты)

<!-- id: server-ports; covers: -->
A table of the open ports: Port (Порт), Process (Процесс), Owner (Владелец), and Address (Адрес). Owner says whether an agent, a terminal, or the Bandito daemon opened the port.
Где: Server → Ports (Порты)
1. Read the table. Owner shows Agent (Агент), Terminal (Терминал), or Bandito daemon (Демон Bandito).
2. Address shows all interfaces (all interfaces) for a port that listens on every address.
3. Click Open (Открыть) to open the port in the Browser.

## Devices (Устройства)

<!-- id: server-devices; covers: -->
The phones and Macs that connect to this server. Revoking one device cuts off only that device.
Где: Server → Devices (Устройства) → Add device (Добавить устройство)
1. To add a device, click Add device (Добавить устройство). The sheet Pair a device (Добавить устройство) shows a code that is valid for N min (Valid for {minutes} min.). Scan it with Bandito on the device, or type it in. The code works once.
2. To remove a device, click Revoke (Отозвать) in its row, read Revoke {name}?, and confirm. The device loses access to the server at once.
3. Each row shows Added {date} and, when known, last seen (last seen {last}).

## Updates (Обновления)

<!-- id: server-updates; covers: -->
Shows the version of the daemon on the server and the latest release, and how to update it.
Где: Server → Updates (Обновления) → How to update (Как обновить) → Open in terminal (Открыть в терминале)
1. Read Daemon version (Версия демона) and Latest release (Последний релиз). The badge says Update available (Доступно обновление) or Up to date (Актуально).
2. Click Open in terminal (Открыть в терминале). The update runs the same install script as the first setup. It replaces the daemon and keeps your data and settings.
3. Run it in the terminal that opens. The Terminals mode shows the output.
## Daemon log (Журнал демона)

<!-- id: server-daemon-log; covers: -->
The daemon's own log on the server: its newest lines, with the level filter. Secrets and Bandito's tokens are masked before they are shown. The view follows the end of the log. On a server with an older Bandito the section says that the log needs an update.
Где: Server (⌘6) → Daemon log (Журнал демона)
1. Open Daemon log. The newest 500 lines are shown, the last one at the bottom.
2. Choose All (Все), Warnings (Предупреждения) or Errors (Ошибки) to filter the lines by level.
3. Click Refresh (Обновить) to read the log again, or Copy all (Скопировать всё) to copy the lines on screen.

