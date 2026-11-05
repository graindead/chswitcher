# CH Scene Switcher

THIS IS AI GENERATED SLUDGE

Switches OBS scenes automatically while you play [Clone Hero](https://clonehero.net/):
one scene while a song is playing, another in the menus.

It watches the `currentsong.txt` file Clone Hero writes. When the file gets text a song has started,
and when it is emptied the song has ended. Scenes are switched through OBS's built-in WebSocket server.

The main program is a 22 KB Windows app written in x64 assembly, with no installer and no runtime to install.

## Use

1. In OBS, open **Tools → WebSocket Server Settings**, tick **Enable WebSocket server**, and note the
   server IP, port and password (**Show Connect Info**).
2. Run `CH Scene Switcher.exe`. On the **Settings** page, enter those details and click **Connect**.
3. On the **Singleplayer** page, pick the scene for **Song playing**, and optionally one for **In menus**.
4. Also on **Settings**, check that **Current Song File** points at Clone Hero's `currentsong.txt`. It is usually
   `Documents\Clone Hero\PlayerData\currentsong.txt`, and the app finds it there by itself. You can also set a
   delay before switching back to the menu scene.

The status row at the bottom shows the connection (green dot when connected) and the latest song and scene switch.

### Song requests

If you use [Ouvert](https://ouvert.dev/) for song requests, paste your **public** API key from your Ouvert dashboard
into the **Settings** page. The box hides the key from view. The **Requests** page shows your queue with each song, its requester and its length.
The app only contacts Ouvert while that page is on screen, every 5 seconds.

The **Next song** button moves the queue on, two possible ways:

- **Signed in to Twitch** (on **Settings**): it posts your bot's Next song command (`!playnext` by default) to your chat as you, so the
  bot moves the queue and announces the song. The Ouvert bot must be in your chat, and the command must match your Ouvert settings.
- **Not signed in:** it uses your **private** Ouvert API key, also entered on **Settings**. The queue moves on, but Ouvert doesn't announce it in chat.

Your Ouvert keys and Twitch sign-in are encrypted in `settings.ini` with Windows DPAPI, so they only work for your Windows account on
your PC; on another PC you'd enter them again. Other programs running as you could still decrypt them. The Twitch sign-in only has the
`user:write:chat` permission, so it can post in chat as you and nothing else. The OBS password is stored as plain text, so don't share that file. Ouvert's API isn't
officially documented, so an Ouvert update could break this page.

### Singleplayer and multiplayer

The **Singleplayer** and **Multiplayer** pages each have their own scenes. The mode in use says **Active mode**
on its page. Looking at a page doesn't change anything in OBS; click **Use this mode** to switch. OBS then
switches straight away: to that mode's song scene if a song is playing, or to its menu scene if you're in the menus.

Settings are saved as you change them, in `%APPDATA%\CH Scene Switcher\settings.ini`. The next time you start the app it
connects and starts watching by itself. Minimizing hides it to the system tray, unless you turn that off on **Settings**. Click the tray icon to bring it back,
or right-click it to exit.

The OBS password is stored in plain text in `settings.ini`, so don't share that file.

## Build

Needs the Visual Studio C++ build tools (for `ml64`, `rc` and `link`).

```bat
asm\build.bat
```

This produces `asm\CH Scene Switcher.exe`.

## Layout

| Path | What |
|---|---|
| `asm/` | The app: `chss.asm` (code), `chss.rc` (window layout and version info), `chss.manifest`, `build.bat` |

## How it works

- **OBS connection:** WebSocket protocol v5 through Windows' WinHTTP. The password login uses SHA-256 (BCrypt) and base64 (Crypt32).
- **Threads:** a background thread connects to OBS, polls the song file every 250 ms and switches scenes,
  so the window never freezes while OBS is slow or unreachable. If the connection drops, it retries every 5 seconds.
- **Libraries:** only DLLs that ship with Windows 10/11 are used. There's no C runtime.
