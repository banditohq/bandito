# Account (Аккаунт)

The account is optional. It syncs the list of your servers, shortcuts and prompts between your devices. Code, API keys
and conversations stay on your servers. Everything works on one Mac without an account.

## Account sheet

<!-- id: acc-sheet; covers: sheet:account; status: planned -->
The sign-in sheet that Settings → Account and sync opens. In this build the sheet is a placeholder: its title is Account and sync (Аккаунт и синхронизация), and it says Coming soon (Скоро здесь), with Close (Закрыть). The working sign-in is in the first-run introduction (see below).
Где: Settings (⌘,) → Account and sync (Аккаунт и синхронизация) → Sign in (Войти)
1. Click Sign in (Войти). The sheet says Coming soon (Скоро здесь).
2. Click Close (Закрыть). To sign in now, start the introduction again: Help → Show the introduction again (Показать знакомство снова), then sign in on the Account step.

## Sign in with GitHub

<!-- id: acc-github; covers: -->
Signs in with your GitHub account by a device code. You confirm it on github.com, and nothing is typed on a keyboard except the code that is copied for you.
Где: First-run introduction → Account → Continue with GitHub (Продолжить с GitHub)
1. Click Continue with GitHub (Продолжить с GitHub). The app shows Connecting to GitHub… (Подключаем GitHub…).
2. Click Copy code and open GitHub (Скопировать код и открыть GitHub). The code is copied, and the github.com/login/device page opens.
3. Paste the code on the page and confirm. Bandito shows Waiting for your confirmation on GitHub (Ждём подтверждения на GitHub) until you do.
4. If the code expired, the message says The code has expired. Start again. Click Try again (Ещё раз). If you declined, the message says You declined the sign-in on GitHub.

## Sign in with email code

<!-- id: acc-email; covers: -->
Signs in by a 6-digit code sent to your email. No password to make up.
Где: First-run introduction → Account → or with email → Send code (Прислать код)
1. Type your address in Email (Почта). An invalid address shows Enter a valid email address.
2. Click Send code (Прислать код). Type the 6 digits from the letter, one per box. The code is checked when all six are typed.
3. If the code is wrong or did not arrive, wait for the countdown (Send a new code in N s), then click Send a new code (Прислать новый код). To use another address, click Use another email (Другая почта).

## Continue without an account (Продолжить без аккаунта)

<!-- id: acc-skip; covers: -->
Skips the sign-in. Everything stays on this Mac, and you can sign in later from Settings.
Где: First-run introduction → Account → Continue without an account (Продолжить без аккаунта)
1. Click Continue without an account (Продолжить без аккаунта). The hint says everything stays on this Mac only.
2. Your servers and agents keep working on this Mac.

## What the account stores (privacy)

<!-- id: acc-privacy; covers: -->
Only the list of your servers is stored in the account: encrypted, and only your devices hold the key. Tokens are kept in the Mac's Keychain, not in the settings file.
Где: Settings (⌘,) → Account and sync (Аккаунт и синхронизация) → intro text; first-run introduction → Account → privacy line
1. Read the privacy line on the Account step. It says code, API keys and conversations stay on your servers.

## Device key error (Could not read this Mac's device key)

<!-- id: acc-device-key; covers: -->
Sign-in needs a key that identifies this Mac. If the key cannot be read, the step shows Could not read this Mac's device key. Try again.
Где: First-run introduction → Account → message
1. Click Try again (Ещё раз). If it keeps failing, see [troubleshooting.md](troubleshooting.md).

## Device approval after sign-in (planned)

<!-- id: acc-approval; covers: ; status: planned -->
A new device should be approved on the Approval step before it gets your servers. The step is a placeholder in this build (Coming soon), so it is not in the flow for signed-in devices that are approved; approval by code is not in the app yet.
Где: First-run introduction → Approval
1. Click Next (Дальше). See [getting-started.md](getting-started.md).

## Devices of a server (Devices)

<!-- id: acc-devices; covers: -->
The phones and Macs that connect to a server. Adding and revoking are on the server, not in the account screen. See [server.md](server.md).
Где: Server (⌘6) → Devices (Устройства)
1. To pair a new device, click Add device (Добавить устройство) and enter the code on the device.
2. To cut one device off, click Revoke (Отозвать) in its row.

## Sign out (Sign out of this server)

<!-- id: acc-sign-out; covers: ; status: planned -->
Sign-out is not available in this build: the app has no sign-out action. To remove a server from this Mac, use Settings → Servers → Delete (see [settings.md](settings.md)).
Где: Settings (⌘,) → Servers (Серверы) → Delete (Удалить)
1. Remove the server in Settings → Servers. The app forgets the server and its token; nothing on the server is deleted.

## Reset (Сбросить)

<!-- id: acc-reset; covers: -->
Ways to start over without deleting data on the server: show the introduction again, reset every shortcut, or remove a server from this Mac.
Где: Help → Show the introduction again (Показать знакомство снова); Settings (⌘,) → Keys and gestures (Клавиши и жесты) → Reset all (Сбросить всё); Settings (⌘,) → Servers (Серверы) → Delete (Удалить)
1. Show the introduction again: it starts at Welcome.
2. Reset all shortcuts: click Reset all (Сбросить всё) in Keys and gestures. Your presets and custom shortcuts are removed.
3. Remove a server from this Mac: Delete (Удалить) in Servers. It is only forgotten by this Mac.

## Session too old (sign-in again)

<!-- id: acc-session; covers: -->
When the saved sign-in is too old or lost, the app goes back to the Account step, so you sign in again.
Где: First-run introduction → Account
1. Sign in again with GitHub or email, or continue without an account.
