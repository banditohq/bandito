# Files (Файлы)

Browse the files of the server in the app, open and edit them, create, rename, move to the Trash and download them.
The files are the server's own: the same folders the agents work in. Open the mode with ⌘2.

## Files mode

<!-- id: files-mode; covers: mode:files -->
A sidebar with places and the folders where agents work, the folder list in the middle, and a details panel on the right for the selected item.
Где: Mode bar → Files (Файлы), or Menu View → Files (Файлы)
1. Press ⌘2 or click Files (Файлы) in the mode bar.
2. Pick a place in the sidebar, or open an agent's folder from WHERE AGENTS WORK (ГДЕ РАБОТАЮТ АГЕНТЫ).
3. Use Back (Назад) and Forward (Вперёд) in the toolbar, or two-finger swipe left and right on the trackpad, to move through the folders you visited.

## Places in the sidebar (Places)

<!-- id: files-places; covers: -->
The sidebar groups the places into FAVORITES (ИЗБРАННОЕ) and WHERE AGENTS WORK (ГДЕ РАБОТАЮТ АГЕНТЫ), with Server disk (Диск сервера) at the bottom showing how much is free.
Где: Files → sidebar
1. Home (Домашняя) opens the server user's home folder (~).
2. Projects (Проекты) opens the projects folder of the server (~/projects, or the folder set by the server).
3. Agent memory (Память агентов) opens the folder where agents keep their memory (~/bandito/agents).
4. Logs (Логи) opens /var/log, read only for most files.
5. Downloads (Загрузки) and Trash (Корзина) open the matching folders on the server.
6. Under WHERE AGENTS WORK (ГДЕ РАБОТАЮТ АГЕНТЫ), each agent's project folder is listed. Click one to open it.

## Find and sort in a folder (Search in {folder})

<!-- id: files-search-sort; covers: -->
The search field filters the current folder. The view switches between a list and icons, and the columns are Name (Имя), Modified (Изменён), Size (Размер) and Changed by (Кто менял).
Где: Files → toolbar → Search in {folder} (Search in {folder}); layout buttons List (Списком) and Icons (Значками)
1. Type in the search field: the list shows only matches, or Nothing found (Ничего не найдено).
2. Click List (Списком) or Icons (Значками) to change the view.
3. If a folder is long, the first items are shown with a note: Showing the first N items (Showing the first {count} items).

## Open a file or a folder

<!-- id: files-open; covers: -->
A folder opens in the list. A file opens in the viewer, or in the app that shows its kind (image, PDF, video, audio).
Где: Files → select an item → right-click → Open (Открыть); or ⌘↓
1. Double-click an item, or select it and press ⌘↓.
2. To go up one folder, press ⌘↑ or click Back (Назад).

## New folder and new file (New, Folder, File)

<!-- id: files-new; covers: -->
Creates an empty folder or an empty file in the current folder.
Где: Files → toolbar → New (Создать) → Folder (Папка) or File (Файл); shortcuts ⌘⇧N (New folder) and ⌥⌘N (New file)
1. Click New (Создать), choose Folder (Папка) or File (Файл), or press the shortcut.
2. Type the name in the dialog and click Create (Создать). If the name is taken, see the conflict below.

## Rename, duplicate, copy path

<!-- id: files-rename-duplicate; covers: -->
Changes the name, makes a copy in the same folder, or copies the full path to the clipboard.
Где: Files → select an item → right-click → Rename (Переименовать), Duplicate (Дублировать), Copy path (Копировать путь)
1. Select the item and press ↵ to rename it (Rename), type the new name, and press ↵ again.
2. Press ⌘D (Duplicate) to make a copy next to the file.
3. Press ⌥⌘C (Copy path) to copy the path.

## Move to Trash (В корзину)

<!-- id: files-trash; covers: -->
Moves the selected item to the server's Trash (Корзина). It is not deleted for good.
Где: Files → select an item → right-click → Move to Trash (В корзину); shortcut ⌘⌫
1. Select the item and press ⌘⌫, or right-click and choose Move to Trash (В корзину).
2. To bring it back, open Trash (Корзина) in the sidebar and move the item out.

## Show hidden files (Показывать скрытые файлы)

<!-- id: files-hidden; covers: -->
Hidden files (names that start with a dot) are not shown by default. The toggle ⌘⇧. shows them in the folder. The default for new folders is set in Settings → Terminal and files.
Где: Files → ⌘⇧. (fixed shortcut, not in the keymap); Settings → Terminal and files (Терминал и файлы) → Show hidden files (Показывать скрытые файлы)
1. Press ⌘⇧. to show or hide hidden files in the current folder.
2. Set the default in Settings (⌘,) → Terminal and files (Терминал и файлы) → Show hidden files (Показывать скрытые файлы).

## Quick look (Быстрый просмотр)

<!-- id: files-quicklook; covers: -->
Shows a quick preview of the selected file without opening the viewer.
Где: Files → select a file → Quick look (Быстрый просмотр)
1. Select the file and press Space.
2. Press Space again to close the preview.

## Upload from this Mac

<!-- id: files-upload; covers: -->
Drag a file from the Finder into a folder in Files. The file is copied to the server, and the progress shows the count.
Где: Finder → drag the file → Files → the folder
1. Drag the file onto the folder in Files.
2. The line shows "{name} uploads from this Mac to {folder}" and the count, for example 2 of 5.
3. If a file with the same name is there, see the conflict below.

## Download to Mac (Скачать на Mac)

<!-- id: files-download; covers: -->
Copies a server file to this Mac. Use it for files that cannot be shown in the app, or for large ones.
Где: Files → select a file → right-click → Download to Mac (Скачать на Mac); or the details panel → Download to Mac (Скачать на Mac)
1. Right-click the file and choose Download to Mac (Скачать на Mac). Choose the place in the save dialog.
2. If the download fails, the message says Could not download: … (Could not download: {error}).

## Name conflict (“…” is already here)

<!-- id: files-conflict; covers: -->
When the name exists in the folder, the app asks what to do.
Где: Files → an action that creates or uploads a file → the dialog “{name}” is already here (“{name}” is already here)
1. Click Replace (Заменить) to overwrite the existing file.
2. Click Keep both (Оставить оба) to save the new one under another name.
3. Click Cancel (Отмена) to stop.

## Create an agent in this folder (Create agent in this folder)

<!-- id: files-agent-here; covers: -->
Starts a New agent with this folder as its project folder.
Где: Files → select a folder → right-click → Create agent in this folder (Создать агента в этой папке)
1. Choose the menu item. The New agent sheet opens with the folder filled in.

## Terminal here (Терминал здесь)

<!-- id: files-terminal-here; covers: -->
Opens a new terminal in the folder, see [terminals.md](terminals.md).
Где: Files → select a folder → right-click → Open terminal here (Открыть терминал здесь); or the toolbar → Terminal here (Терминал здесь)
1. Choose Open terminal here (Открыть терминал здесь). The Terminals mode opens with a terminal in that folder.

## Details panel (Preview)

<!-- id: files-preview; covers: -->
The panel on the right shows the selected item: Changed (Изменён), Access (Доступ) as Read only (Только чтение) or Read and write (Чтение и запись), Path (Путь), and buttons Open (Открыть) and Download to Mac (Скачать на Mac).
Где: Files → select an item → details panel
1. Read the access. Read only means the server user cannot change the file.
2. Click Open (Открыть) to open the file in the viewer.

## File viewer: read, edit, side by side (Read, Edit, Side by side)

<!-- id: files-viewer; covers: -->
A file opens in a tab. Markdown, code, text and config files can be read and edited. Images, PDF, video and audio are shown in their own preview. A file over 2 MB cannot be opened here.
Где: Files → open a file → top bar → Read (Читать) / Edit (Править) / Side by side (Рядом)
1. Click Edit (Править) or press ⌘E to change the text. Click Side by side (Рядом) or press ⌥⌘↵ to see the text and the preview together.
2. Markdown shows a preview in Read mode.
3. Edit the text, then press ⌘S (Save) to save. Unsaved changes · ⌘S (Unsaved changes · ⌘S) shows that there are unsaved edits.
4. Use ⌃⇥ (Next tab) and ⌃⇧⇥ (Previous tab) to switch tabs. Click Close tab (Закрыть вкладку) to close one.
5. If you close a tab with unsaved edits, the app asks Save changes to “{name}”? and offers Save (Сохранить), Don’t save (Не сохранять) or Cancel (Отмена).

## File changed on the server while you edit (Show difference)

<!-- id: files-viewer-conflict; covers: -->
If someone or an agent changed the file while you were editing it, the viewer stops and shows the conflict.
Где: Files → viewer → The file changed on the server while you were editing it
1. Click Show difference (Показать разницу) to compare Yours (Ваша версия) with On the server (На сервере).
2. Click Keep mine (Оставить мой) to save your version over the server one.
3. Click Take the server's (Take the server’s) to drop your edits and load the server version.

## Files that cannot be opened (Can’t show this file)

<!-- id: files-binary; covers: -->
Some files are not text or are too large. The viewer says why.
Где: Files → viewer → Can’t show this file (Не умею показывать этот файл) / Can’t play this file (Не получается проиграть этот файл)
1. Binary files show Binary file, not shown as text (Binary file, not shown as text). Click Download to Mac.
2. Files over 2 MB show The file is larger than 2 MB, so it can’t be opened here. Download it to your Mac.
3. Media that the viewer cannot play shows Can’t play this file (Не получается проиграть этот файл). Download it to your Mac.

## Trackpad in Files

<!-- id: files-gestures; covers: -->
Two-finger swipe left and right moves back and forward through folders and files, like Safari and Finder. It can be switched off in Settings → Keys and gestures.
Где: Files → two-finger swipe; Settings → Keys and gestures (Клавиши и жесты) → Trackpad gestures (Жесты тачпада)
1. Swipe with two fingers. Use the slider Swipe sensitivity (Чувствительность свайпов) to change how far a swipe goes.
