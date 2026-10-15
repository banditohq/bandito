# Account (Аккаунт)

The account is optional. It syncs the list of your servers, shortcuts and prompts between your devices. Code, API keys
and conversations stay on your servers. Everything works on one Mac without an account.
## Account sheet

<!-- id: acc-sheet; covers: sheet:account -->
The sheet that the profile button at the bottom of the sidebar opens, and that Settings → Account (Аккаунт) opens too. Without an account it offers the sign-in, the same as the account step of the introduction. With an account it shows, from the top: your photo (56 pt) with your name beside it, your email under the name (with the GitHub mark when you sign in with GitHub), and in the top right corner a round ? (Help and feedback, Помощь и обратная связь) and the close cross; then one card, Devices (Устройства), with a line for each device and, at its foot, Add iPhone or iPad (Добавить iPhone или iPad); under the card, This Mac's verification code (Код проверки этого Mac), folded; then one line of sync; and at the foot Sign out (Выйти из аккаунта) and Reset account (Сбросить аккаунт). The application's Settings are in the application menu (Settings, ⌘,).
Где: Sidebar → bottom left, the profile button (person icon); or Settings (⌘,) → Account (Аккаунт) → Sign in (Войти)
1. Click the profile button at the bottom left of the sidebar. The sheet opens on the account, or on the sign-in when nobody is signed in.
2. Click Sign in (Войти) to sign in with GitHub or by an email code, as in the introduction.
3. To change your photo, click it. A small box opens with Choose photo (Выбрать фото…) and, when there is a photo, Remove photo (Убрать фото). The picture is framed right in the sheet: drag it, set the zoom with the slider and click Save (Сохранить). Without a photo, the same box has the colour circles: the letter on the avatar takes the colour you pick. The photo is kept on this Mac and in your encrypted sync, so it shows after a restart, even without the network. The photo and the name are removed from this Mac by Sign out (Выйти из аккаунта) or Reset account (Сбросить аккаунт).
4. To change your name, click it (or the pencil), type a new one and press Return or click the check; Escape or the cross keeps the old one.
5. In Devices, the line under each device says online (в сети) when it was seen in the last five minutes, or when it was last seen. This Mac is marked This Mac (Этот Mac).
6. To drop another device from the list, click the ellipsis (…) on its row and confirm Disconnect (Отключить). The device loses its access at once.
7. Add iPhone or iPad (Добавить iPhone или iPad), the cream button at the foot of the card, opens the connect wizard with the QR code for the phone to scan, at once and without a server to choose. In the background the wizard turns the phone access on for every connected server that can take it; one quiet line under the code says so, or which server did not turn on, with Try again (Повторить). Use a pairing code instead (Использовать код подключения) takes the older path: it asks which server only when there are several, and shows a code to type. When the iPhone connects it says Done, the iPhone is connected (Готово, iPhone подключён). Under the code, a line says the iPhone app is in closed testing (Bandito для iPhone пока в закрытом тестировании) and opens a letter to ask for an invitation. It needs a signed-in account and a connected server that is up to date.
8. This Mac's verification code: click This Mac's verification code (Код проверки этого Mac) to open it; the icon next to the code copies it. Compare it when you approve a new device.
9. In the sync line, Sync now (Синхронизировать сейчас) sends your server list and photo at once. If it fails, the dot turns red and the reason is on the same line.
10. Reset account (Сбросить аккаунт) signs the other devices out and erases the sync settings. Your servers and the agents on them stay as they are.
11. The round ? in the head of the sheet opens an email to hello@bandito.dev.
12. Close the sheet with the cross (Закрыть) in its head.

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
Где: Settings (⌘,) → Account (Аккаунт) → intro text; first-run introduction → Account → privacy line
1. Read the privacy line on the Account step. It says code, API keys and conversations stay on your servers.

## Device key error (Could not read this Mac's device key)

<!-- id: acc-device-key; covers: -->
Sign-in needs a key that identifies this Mac. If the key cannot be read, the step shows Could not read this Mac's device key. Try again.
Где: First-run introduction → Account → message
1. Click Try again (Ещё раз). If it keeps failing, see [troubleshooting.md](troubleshooting.md).
## Device approval after sign-in

<!-- id: acc-approval; covers: -->
A new device must be approved before it gets your servers. After the sign-in, a Mac that no other device has approved waits on the Approval step: Confirm this Mac on another device. The same screen appears in the account sheet when the account asks for it.
Где: First-run introduction → Account → Approval (Подтверждение)
1. On the other device, compare the codes: They match (They match) or They differ (They differ).
2. On the other device, approve the request or reject it. Reject (Reject) refuses this Mac.

## Devices of a server (Devices)

<!-- id: acc-devices; covers: -->
The phones and Macs that connect to a server. Adding and revoking are on the server, not in the account screen. See [server.md](server.md).
Где: Server (⌘7) → Devices (Устройства)
1. To pair a new device, click Add device (Добавить устройство) and enter the code on the device.
2. To cut one device off, click Revoke (Отозвать) in its row.
## Sign out

<!-- id: acc-sign-out; covers: -->
Sign out (Sign out) in the account sheet signs this Mac out of the account. Sync stops on this Mac until you sign in again. To remove a server from this Mac, use Settings → Servers → Delete (see [settings.md](settings.md)).
Где: Settings (⌘,) → Account (Аккаунт) → Sign out (Sign out)
1. Click Sign out (Sign out) and confirm.

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
