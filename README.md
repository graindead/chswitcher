# CH Scene Switcher

Switches OBS scenes automatically while you play [Clone Hero](https://clonehero.net/):
one scene while a song is playing, another in the menus.

It watches the `currentsong.txt` file Clone Hero writes. When the file gets text a song has started,
and when it is emptied the song has ended. Scenes are switched through OBS's built-in WebSocket server.

The main program is a 17 KB Windows app written in x64 assembly, with no installer and no runtime to install.

## Use

1. In OBS, open **Tools → WebSocket Server Settings**, tick **Enable WebSocket server**, and note the
   server IP, port and password (**Show Connect Info**).
2. Run `CH Scene Switcher.exe`, enter those details and click **Connect**.
3. Pick the scene for **Song playing**, and optionally one for **In menus** plus a delay before switching back.
4. Check that **Song file** points at Clone Hero's `currentsong.txt`. It is usually
   `Documents\Clone Hero\PlayerData\currentsong.txt`, and the app finds it there by itself.

Settings are saved as you change them, in `%APPDATA%\CH Scene Switcher\settings.ini`. The next time you start the app it
connects and starts watching by itself. Minimizing hides it to the system tray. Click the tray icon to bring it back,
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
| `asm/` | The GUI app: `chss.asm` (code), `chss.rc` (window layout and version info), `chss.manifest`, `build.bat` |
| `asm/console/` | The earlier console version of the app, also in assembly |

## How it works

- **OBS connection:** WebSocket protocol v5 through Windows' WinHTTP. The password login uses SHA-256 (BCrypt) and base64 (Crypt32).
- **Threads:** a background thread connects to OBS, polls the song file every 250 ms and switches scenes,
  so the window never freezes while OBS is slow or unreachable. If the connection drops, it retries every 5 seconds.
- **Libraries:** only DLLs that ship with Windows 10/11 are used. There's no C runtime.
