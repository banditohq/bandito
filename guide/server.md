# Server (Сервер)

The health and the setup of the server that runs your agents: its load, what is installed, the workplaces, secrets,
open ports, paired devices and updates. Open the mode with ⌘7. The sections are switched at the top of the mode.

## Server mode

<!-- id: server-mode; covers: mode:server -->
The Server mode has seven sections: Overview (Обзор), Workplaces (Рабочие места), Secrets (Секреты), Ports (Порты), Devices (Устройства), Updates (Обновления), and Daemon log (Журнал демона). A server with a recent daemon also has Backups (Резервные копии). The current server is shown in the top bar.
Где: Mode bar → Server (Сервер), or Menu View → Server (Сервер)
1. Press ⌘7 or click Server (Сервер) in the mode bar.
2. Choose a section at the top. Each section keeps its own state.
3. To switch to another server, use the server picker in the top bar. Actions in progress are dropped when the server changes.

## Overview: load and health (Overview)

<!-- id: server-overview; covers: -->
The first screen: CPU, Memory, Disk and Network tiles, a health line, and the processes that use the most resources.
Где: Server → Overview (Обзор)
1. Read the health line: All good (Всё в порядке), Disk almost full (Диск почти полон), Memory almost full (Памяти почти не осталось), or Disk and memory almost full (Диск и память почти заполнены).
2. Switch the chart range: 1 h (1 h) or 24 h (24 h).
3. Read Who uses the most (Кто сколько ест): the agent processes with their CPU share. If nothing runs, the list says Nothing is running yet.

<!-- id: server-update-card; covers: -->
When the daemon on the server has a newer release, a card at the top says Version X is available (you have Y) (Доступна версия X (у вас Y)).
Где: Server → Overview (Обзор) → Update server (Обновить сервер)
1. Click Update server (Обновить сервер) and confirm Update (Обновить). The server downloads the release, checks its signature, and restarts. The connection drops for a few seconds, then comes back by itself.
2. The card then says The server runs X now (Сервер работает на версии X). If the server does not come back within two minutes, the card says so: check the server in Terminal.
3. The server list in the Bandito menu shows a dot next to a server whose daemon has an update.

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
Lists the workplaces where agents run: the shared server first, then the containers. Each card shows the agents in it, the status of the container, its limits, its network and its folders. The screen needs the workplaces feature of the server; without it, the sample cards show only while examples are on (Settings → General → Show examples, see [settings.md](settings.md)).
Где: Server → Workplaces (Рабочие места)
1. Read the status chip of a container: Running (Работает), Stopped (Остановлено), or Docker does not answer (Docker не отвечает).
2. Read the limits: Processor and Memory, or No limit (Без ограничения). Network is internet, or off when the container has no network. Without a network the agent cannot reach its model, so it does not answer.
3. Agents in a workplace are shown as avatars under Agents (Агенты). Move an agent from its Inspector: Where it works → Change (Сменить). The agent starts a new chapter there, and its CLI session is not carried over.

## Create a workplace (Создать рабочее место)

<!-- id: server-workplace-create; covers: -->
Makes a container workplace: a name, a processor limit and a memory limit (or no limit), and the network. The button is enabled when Docker is ready.
Где: Server → Workplaces (Рабочие места) → Create workplace (Создать рабочее место)
1. Click Create workplace (Создать рабочее место).
2. Type a Name (Название), 1 to 64 characters. Choose Processor (Процессор) and Memory (Память), or leave them at No limit (Без ограничения).
3. Choose Network (Сеть): Internet (Интернет) lets the agent reach its model; None (Нет) cuts the network off completely.
4. Read what the workplace gives and what it takes away: the agent sees only its own folder and the folders you add, and inside a container it has no browser and no screen tools.
5. Click Create (Создать). The workplace is saved at once. Its container starts with the first message of an agent in it.

## Folders of a workplace (Папки)

<!-- id: server-workplace-folders; covers: -->
Folders are the host folders the container may see, besides the folders of its agents. The folder is mounted read-write at the same path.
Где: Server → Workplaces (Рабочие места) → a container card → Folders (Папки) → Add folder (Добавить папку)
1. Click Add folder (Добавить папку) and choose the folder in the folder picker.
2. The change applies when the container next starts. Until then the container keeps its old folders.
3. Remove a folder with the cross next to its path. Bandito's own data folder, the server root and the Docker socket cannot be added. A folder that holds Bandito's data gets the sentence "This folder holds Bandito's own data".

## Start, stop and delete a workplace (Запустить, Остановить, Удалить)

<!-- id: server-workplace-control; covers: -->
Start (Запустить) and Stop (Остановить) control the container. Delete (Удалить) removes the workplace with its container and its own disk. The folders on the server stay.
Где: Server → Workplaces (Рабочие места) → a container card → Start (Запустить), Stop (Остановить), Delete (Удалить)
1. Click Stop (Остановить) to stop the container. The next message of an agent in it starts it again.
2. Click Delete (Удалить) and confirm. A workplace with agents in it cannot be deleted: the card lists the agents (Здесь работают агенты) and asks you to move them first. The shared server cannot be deleted.

## Install Docker (Установить Docker)

<!-- id: server-workplace-docker; covers: -->
Containers need Docker on the server. Until Docker is ready, the Workplaces screen shows an Install Docker (Установить Docker) card instead of the Create button.
Где: Server → Workplaces (Рабочие места) → Install Docker (Установить Docker)
1. If the card has an Install (Установить) button, click it. Bandito installs Docker and shows the log.
2. If not, the card gives the instruction: install Docker by hand, then come back. The guide is at docs.docker.com/engine/install.

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
Shows the version of the daemon on the server and the latest release, and how to update it. The Overview card (see above) installs the update from the app; this page is the manual way.
Где: Server → Updates (Обновления) → How to update (Как обновить) → Open in terminal (Открыть в терминале)
1. Read Daemon version (Версия демона) and Latest release (Последний релиз). The badge says Update available (Доступно обновление) or Up to date (Актуально).
2. Click Open in terminal (Открыть в терминале). The update runs the same install script as the first setup. It replaces the daemon and keeps your data and settings.
3. Run it in the terminal that opens. The Terminals mode shows the output.
## Backups (Резервные копии)

<!-- id: server-backups; covers: -->
Copies of the server's database. The daemon saves one at its start, before an update and once a day, and keeps the newest 14. The section lists them and makes a copy now. It appears only on a server whose daemon has backups.
Где: Server (⌘7) → Backups (Резервные копии)
1. Read the list, newest first. Each copy shows its date and time, why it was made (At start, Before update, Daily, Manual, Before restore), and its size.
2. Click Make a copy now (Сделать копию сейчас) to save the database at once.
3. To restore a copy, click Restore (Восстановить) in its row and confirm Restore the copy from {date}?. The current database is kept first and never deleted. The server restarts and agents stop for a few seconds; the banner The server is restarting… stays until it is back, then the result of this restore is shown.
4. A row marked Database saved before a restore (База, сохранённая перед восстановлением), or Damaged database saved before a restore, is the old database that a restore set aside. The daemon never deletes it; you can restore it like a copy.
5. If a restore leaves the server with no usable database, the server starts in safe mode: Overview and Backups show why, and only Backups works. Choose a copy in the list and click Restore (Восстановить).

## Daemon log (Журнал демона)

<!-- id: server-daemon-log; covers: -->
The daemon's own log on the server: its newest lines, with the level filter. Secrets and Bandito's tokens are masked before they are shown. The view follows the end of the log. On a server with an older Bandito the section says that the log needs an update.
Где: Server (⌘7) → Daemon log (Журнал демона)
1. Open Daemon log. The newest 500 lines are shown, the last one at the bottom.
2. Choose All (Все), Warnings (Предупреждения) or Errors (Ошибки) to filter the lines by level.
3. Click Refresh (Обновить) to read the log again, or Copy all (Скопировать всё) to copy the lines on screen.

