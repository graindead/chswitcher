; Clone Hero -> OBS scene switcher, x64 MASM, small GUI.
;
; Watches Clone Hero's currentsong.txt and switches OBS scenes through the
; OBS WebSocket server (v5 protocol, OBS 28+):
;   file gets text (song started)  -> song scene
;   file emptied (song ended/quit) -> menu scene, after an optional delay
;
; Three threads:
;   UI thread     - the dialog (chss.rc) and the tray icon. Never touches the network.
;   worker thread - connects to OBS, watches the file and switches scenes, so a slow
;                   or unreachable OBS never freezes the window.
;   request thread - while the Requests page is on screen, reads the song request
;                   queue from Ouvert (ouvert.dev), so a slow connection there can't
;                   delay scene switching. Also runs Next song and the Twitch sign-in.
; They share settings and status text under g_cs. The UI posts requests by setting
; g_want/g_reconnect and signalling g_hEvent; the worker reports back with
; WM_APP_STATUS / WM_APP_SCENES.
;
; Settings live in %APPDATA%\CH Scene Switcher\settings.ini (settings.json from
; the Python version is imported once) and are saved as soon as they change.
;
; Uses only what ships with Windows 10/11: WinHTTP for the WebSocket, BCrypt for
; SHA-256 and Crypt32 for base64. Build with build.bat.

option casemap:none

IMP macro n
    extern __imp_&n:qword
endm

IMP ExitProcess
IMP SetDefaultDllDirectories
IMP GetModuleHandleA
IMP CreateFileA
IMP ReadFile
IMP CloseHandle
IMP GetFileTime
IMP GetFileAttributesA
IMP CreateDirectoryA
IMP GetEnvironmentVariableA
IMP GetPrivateProfileStringA
IMP WritePrivateProfileStringA
IMP GetTickCount64
IMP GetLastError
IMP MultiByteToWideChar
IMP WideCharToMultiByte
IMP CreateThread
IMP CreateEventA
IMP SetEvent
IMP WaitForSingleObject
IMP InitializeCriticalSection
IMP EnterCriticalSection
IMP LeaveCriticalSection
IMP DialogBoxParamA
IMP EndDialog
IMP SetDlgItemTextA
IMP SetDlgItemTextW
IMP GetDlgItemTextA
IMP GetDlgItemTextW
IMP SendDlgItemMessageW
IMP PostMessageA
IMP ShowWindow
IMP SetForegroundWindow
IMP LoadIconA
IMP CreatePopupMenu
IMP AppendMenuA
IMP TrackPopupMenu
IMP DestroyMenu
IMP GetCursorPos
IMP Shell_NotifyIconA
IMP GetOpenFileNameA
IMP InitCommonControls
IMP GetDlgItem
IMP MoveWindow
IMP GetWindowPlacement
IMP SetWindowPlacement
IMP SetWindowPos
IMP EnableWindow
IMP ShellExecuteA
IMP WinHttpQueryHeaders
IMP Sleep
IMP GetClientRect
IMP GetWindowRect
IMP MapWindowPoints
IMP GetDlgCtrlID
IMP MapDialogRect
IMP FillRect
IMP DrawTextW
IMP SetTextColor
IMP SetBkMode
IMP SetBkColor
IMP SetWindowTheme
IMP DwmSetWindowAttribute
IMP CreateSolidBrush
IMP WinHttpOpen
IMP WinHttpSetTimeouts
IMP WinHttpConnect
IMP WinHttpOpenRequest
IMP WinHttpSetOption
IMP WinHttpSendRequest
IMP WinHttpReceiveResponse
IMP WinHttpWebSocketCompleteUpgrade
IMP WinHttpWebSocketSend
IMP WinHttpWebSocketReceive
IMP WinHttpWebSocketQueryCloseStatus
IMP WinHttpCloseHandle
IMP WinHttpReadData
IMP IsWindowVisible
IMP IsIconic
IMP BCryptHash
IMP CryptBinaryToStringA
IMP CryptStringToBinaryA
IMP CryptProtectData
IMP CryptUnprotectData
IMP LocalFree

CS_ENTER macro
    lea rcx, g_cs
    call [__imp_EnterCriticalSection]
endm

CS_LEAVE macro
    lea rcx, g_cs
    call [__imp_LeaveCriticalSection]
endm

RBUF_SIZE   equ 262144
TEXTSIZE    equ 4096
MAXSCENES   equ 256
NSET        equ 20
REQ_POLL_MS equ 5000
REQ_MAX     equ 100             ; requests shown
RESP_SIZE   equ 131072
PAGE_REQUESTS equ 0
PAGE_SETTINGS equ 3
POLL_MS     equ 250
RETRY_MS    equ 5000

; dialog control ids (match chss.rc)
IDC_HOST    equ 101
IDC_PORT    equ 102
IDC_PASS    equ 103
IDC_CONNECT equ 104
IDC_SONG    equ 105
IDC_MENU    equ 106
IDC_DELAY   equ 107
IDC_FILE    equ 108
IDC_BROWSE  equ 109
IDC_CONN    equ 110
IDC_NAV     equ 112
IDC_USEMODE equ 113
IDC_ACTIVE  equ 114
IDC_DOT     equ 115
IDC_STATUS  equ 116
IDC_DIVIDER equ 117
IDC_OUVERT  equ 118
IDC_REQLIST equ 119
IDL_HOST    equ 120             ; page labels
IDL_PORT    equ 121
IDL_PASS    equ 122
IDL_SONG    equ 123
IDL_MENU    equ 124
IDL_FILE    equ 125
IDL_DELAY   equ 126
IDL_OUVERT  equ 127
IDC_OUVERTP equ 128
IDL_OUVERTP equ 129
IDC_NEXT    equ 130
IDC_NEXTMSG equ 131
IDC_TWSTAT  equ 132
IDC_TWBTN   equ 133
IDL_CHATCMD equ 134
IDC_CHATCMD equ 135
IDC_ONTOP   equ 136
IDL_ONTOP   equ 137
IDC_TRAY    equ 138
IDL_TRAY    equ 139
ID_SHOW     equ 200
ID_EXIT     equ 201

WM_APP_STATUS equ 8000h
CLR_BG      equ 00202020h       ; window background (dark)
CLR_FIELD   equ 002D2D2Dh       ; text box and dropdown background
CLR_SELBG   equ 007C440Ch       ; selected page background
CLR_DIVIDER equ 003C3C3Ch       ; line between the page list and the page
CLR_TEXT    equ 00EDEDEDh       ; text in text boxes and dropdowns
CLR_MUTED   equ 00A8A8A8h       ; labels, status, unselected pages
CLR_ACCENT  equ 00EBB785h       ; selected page text
CLR_DOTOFF  equ 00707070h       ; status dot: not connected
CLR_DOTOK   equ 006EC24Ch       ;   connected
CLR_DOTERR  equ 004B53E5h       ;   can't connect
WM_APP_SCENES equ 8001h
WM_APP_REQS   equ 8002h
WM_APP_NEXTDONE equ 8003h
WM_APP_TWITCH equ 8004h

; build with /DCHSS_TEST to read requests from a local test server over plain HTTP
ifdef CHSS_TEST
OUVERT_PORT  equ 4467
OUVERT_FLAGS equ 0
TWITCH_PORT  equ 4468
TWITCH_FLAGS equ 0
else
OUVERT_PORT  equ 443
OUVERT_FLAGS equ 800000h        ; WINHTTP_FLAG_SECURE
TWITCH_PORT  equ 443
TWITCH_FLAGS equ 800000h
endif
WM_APP_TRAY   equ 800Ah

; ---------------------------------------------------------------------------
; Load configuration (IMAGE_LOAD_CONFIG_DIRECTORY64), normally supplied by the C
; runtime. Its DependentLoadFlags make Windows load this exe's imported DLLs
; (uxtheme, dwmapi, ...) from System32 only, never from the exe's own folder.
CONST SEGMENT READONLY ALIGN(8) 'CONST'
public _load_config_used
_load_config_used label qword
    dd 140h                         ; Size
    db 4Ah dup(0)
    dw 800h                         ; DependentLoadFlags = LOAD_LIBRARY_SEARCH_SYSTEM32
    db 140h - 50h dup(0)
CONST ENDS

.data

s_section   db 'settings',0
k_host      db 'host',0
k_port      db 'port',0
k_pass      db 'password',0
k_song      db 'song_scene',0
k_menu      db 'menu_scene',0
k_delay     db 'menu_delay',0
k_file      db 'song_file',0
k_mpsong    db 'mp_song_scene',0
k_mpmenu    db 'mp_menu_scene',0
k_mode      db 'mode',0
k_ouvert    db 'ouvert_key',0
k_ouvertp   db 'ouvert_private_key',0
k_twaccess  db 'twitch_access_token',0
k_twrefresh db 'twitch_refresh_token',0
k_twid      db 'twitch_user_id',0
k_twlogin   db 'twitch_login',0
k_chatcmd   db 'next_chat_command',0
k_ontop     db 'keep_on_top',0
k_winpos    db 'window',0
k_tray      db 'minimize_to_tray',0
d_one       db '1',0
d_chatcmd   db '!playnext',0
d_host      db 'localhost',0
d_port      db '4455',0
d_delay     db '0',0
s_empty     db 0

; settings.json keys as written by the Python version (json.dumps, indent=2)
m_host      db '"host": "',0
m_port      db '"port": ',0
m_pass      db '"password": "',0
m_song      db '"song_scene": "',0
m_menu      db '"menu_scene": "',0
m_delay     db '"menu_delay": ',0
m_file      db '"song_file": "',0

s_APPDATA   db 'APPDATA',0
s_USERPROF  db 'USERPROFILE',0
s_appname   db '\CH Scene Switcher',0
s_ininame   db '\settings.ini',0
s_jsonname  db '\settings.json',0
sfx1        db '\Documents\Clone Hero\PlayerData\currentsong.txt',0
sfx2        db '\Documents\Clone Hero\currentsong.txt',0
sfx3        db '\OneDrive\Documents\Clone Hero\PlayerData\currentsong.txt',0

s_ident1    db '{"op":1,"d":{"rpcVersion":1,"eventSubscriptions":0',0
s_identauth db ',"authentication":"',0
s_quote     db '"',0
s_close2    db '}}',0
s_challenge db '"challenge":"',0
s_salt      db '"salt":"',0
s_op2       db '"op":2',0
s_op7       db '"op":7',0
s_req1      db '{"op":6,"d":{"requestType":"',0
s_req2      db '","requestId":"1","requestData":',0
s_restrue   db '"result":true',0
s_GetScenes db 'GetSceneList',0
s_emptyobj  db '{}',0
s_SetScene  db 'SetCurrentProgramScene',0
s_scn1      db '{"sceneName":"',0
s_scn2      db '"}',0
s_sceneName db '"sceneName":"',0
s_noresp    db 'no response from ',0
s_errcode   db ' (error ',0
s_rparen    db ')',0
s_closed    db 'OBS closed the connection',0
s_colon     db ': ',0
s_noscenes  db "OBS didn't send its scene list",0

w_agent     dw 'c','h','s','s',0
w_get       dw 'G','E','T',0
w_slash     dw '/',0
ifdef CHSS_TEST
w_ohost     dw '1','2','7','.','0','.','0','.','1',0
else
w_ohost     dw 'o','u','v','e','r','t','.','d','e','v',0
endif
w_opath     dw '/','A','P','I','/','S','o','n','g','R','e','q','u','e','s','t','s',0
ifdef CHSS_TEST
w_twid      dw '1','2','7','.','0','.','0','.','1',0
w_twapi     dw '1','2','7','.','0','.','0','.','1',0
else
w_twid      dw 'i','d','.','t','w','i','t','c','h','.','t','v',0
w_twapi     dw 'a','p','i','.','t','w','i','t','c','h','.','t','v',0
endif
w_post      dw 'P','O','S','T',0
w_pdevice   dw '/','o','a','u','t','h','2','/','d','e','v','i','c','e',0
w_ptoken    dw '/','o','a','u','t','h','2','/','t','o','k','e','n',0
w_prevoke   dw '/','o','a','u','t','h','2','/','r','e','v','o','k','e',0
w_pusers    dw '/','h','e','l','i','x','/','u','s','e','r','s',0
w_pchat     dw '/','h','e','l','i','x','/','c','h','a','t','/','m','e','s','s','a','g','e','s',0
w_onext     dw '/','A','P','I','/','S','o','n','g','R','e','q','u','e','s','t','s','/','N','e','x','t',0

s_title     db 'CH Scene Switcher',0
s_show      db 'Show',0
s_exit      db 'Exit',0
s_noneitem  db '(none)',0
s_sp        db 'Singleplayer',0
s_mp        db 'Multiplayer',0
s_navset    db 'Settings',0
s_navreq    db 'Requests',0
s_keyhdr    db 'X-API-KEY: ',0
s_rstatus   db '"status":true',0
s_rdata     db '"data":[',0
s_rreq      db '"request":"',0
s_rname     db '"requester_name":"',0
s_rlen      db '"length":',0
s_rsep      db '   -   ',0
s_ropen     db '   (',0
s_rnokey    db 'Enter your Ouvert public API key on the Settings page.',0
s_rempty    db 'The queue is empty.',0
s_rbad      db "Ouvert didn't accept that key, or sent something unexpected.",0
s_rneterr   db "Can't reach Ouvert (error ",0
s_rretry    db '). Retrying...',0
s_rmsg      db '"message":"',0
s_nnokey    db 'Enter your private API key on the Settings page.',0
s_nok       db 'Moved to the next song.',0
s_nbad      db 'Ouvert refused that.',0
; The app's public Twitch Client ID (not a secret): dev.twitch.tv/console
ifdef CHSS_TEST
s_twclient  db 'testclient',0
else
s_twclient  db '0f04ohpjdjce8fktpx6wjnsx05g5sh',0
endif
s_open      db 'open',0
s_secprefix db 22h,'dpapi:',0
s_twurl     db 'https://www.twitch.tv/',0
s_hform     db 'Content-Type: application/x-www-form-urlencoded',0
s_hbearer   db 'Authorization: Bearer ',0
s_hclient   db 13,10,'Client-Id: ',0
s_hjson     db 13,10,'Content-Type: application/json',0
s_fclient   db 'client_id=',0
s_fscopes   db '&scopes=user%3Awrite%3Achat',0
s_fdevice   db '&device_code=',0
s_fgrant    db '&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code',0
s_frefresh  db 'grant_type=refresh_token&refresh_token=',0
s_ftoken    db '&token=',0
s_fclient2  db '&client_id=',0
s_jdevice   db '"device_code"',0
s_jucode    db '"user_code"',0
s_jverif    db '"verification_uri"',0
s_jinterval db '"interval"',0
s_jexpires  db '"expires_in"',0
s_jaccess   db '"access_token"',0
s_jrefresh  db '"refresh_token"',0
s_jid       db '"id"',0
s_jlogin    db '"login"',0
s_jmessage  db '"message"',0
s_jpending  db 'authorization_pending',0
s_jsent     db '"is_sent"',0
s_cbroad    db '{"broadcaster_id":"',0
s_csender   db '","sender_id":"',0
s_cmessage  db '","message":"',0
s_cend      db '"}',0
s_twbsignin db 'Sign in to Twitch',0
s_twbcancel db 'Cancel',0
s_twbsignout db 'Sign out',0
s_twoff     db 'Twitch: not signed in',0
s_twas      db 'Twitch: signed in as ',0
s_twcode1   db 'Twitch code: ',0
s_twfail    db 'Twitch sign-in failed. Try again.',0
s_twexpired db 'Twitch sign-in expired. Sign in again on Settings.',0
s_twnocmd   db 'Set a chat command on the Settings page.',0
s_twsent1   db 'Sent ',0
s_twsent2   db ' to chat',0
s_twsenderr db "Couldn't send to Twitch (error ",0
s_dot       db 0E2h, 97h, 8Fh, 0        ; U+25CF black circle
s_notconn   db 'Not connected',0
s_connecting db 'Connecting...',0
s_connectd  db 'Connected',0
s_cantconn  db "Can't connect",0
s_filter    db 'Text files',0,'*.txt',0,'All files',0,'*.*',0,0

st_enter      db 'Enter your OBS WebSocket details and click Connect.',0
st_badport    db 'Port must be a number from 1 to 65535.',0
st_connecting db 'Connecting to ',0
st_dots       db '...',0
st_connected  db 'Connected to OBS at ',0
st_cant       db "Can't connect: ",0
st_retry      db ' - retrying every 5s',0
st_lost       db 'Connection to OBS lost - reconnecting...',0
ev_pick       db 'Pick the scene to show while a song is playing.',0
ev_wait       db 'Waiting for a song...',0
ev_song       db 'Song: ',0
ev_ended      db 'Song ended',0
ev_arrow      db '   ->  ',0
ev_fail1      db "   (couldn't switch to '",0
ev_fail2      db "')",0
ev_missing    db "A saved scene isn't in OBS anymore - pick it again.",0

align 8
; key, buffer, buffer size, default
settings_tbl dq k_host,  g_host,  256,  d_host
             dq k_port,  g_port,  16,   d_port
             dq k_pass,  g_pass,  256,  s_empty
             dq k_song,  g_song,  512,  s_empty
             dq k_menu,  g_menu,  512,  s_empty
             dq k_delay, g_delay, 32,   d_delay
             dq k_file,  g_file,  1024, s_empty
             dq k_mpsong, g_mpsong, 512, s_empty
             dq k_mpmenu, g_mpmenu, 512, s_empty
             dq k_mode,  g_modestr, 4,  d_delay      ; "0" = singleplayer, "1" = multiplayer
; the next 4 rows are secrets: encrypted in the file (see secret_encode)
settings_secret label qword
             dq k_ouvert, g_ouvert, 128, s_empty
             dq k_ouvertp, g_ouvertp, 128, s_empty
             dq k_twaccess, g_twaccess, 256, s_empty
             dq k_twrefresh, g_twrefresh, 256, s_empty
             dq k_twid, g_twid, 32, s_empty
             dq k_twlogin, g_twlogin, 64, s_empty
             dq k_chatcmd, g_chatcmd, 64, d_chatcmd
             dq k_ontop, g_ontop, 4, d_delay       ; "1" = keep the window on top
             dq k_winpos, g_winpos, 64, s_empty    ; x,y,width,height,maximized
             dq k_tray, g_tray, 4, d_one           ; "1" = minimizing hides to the tray
; settings.json patterns, in settings_tbl order (ending in " = string value, else number)
mig_tbl      dq m_host, m_port, m_pass, m_song, m_menu, m_delay, m_file, 0
sfx_tbl      dq sfx1, sfx2, sfx3, 0
; what each control does when the window resizes: 1 = move with the right edge,
; 2 = move with the bottom edge, 4 = widen with the window, 8 = grow taller with it
layout_tbl   dw IDC_NAV, 8, IDC_DIVIDER, 8, IDC_REQLIST, 12, IDC_NEXT, 2, IDC_NEXTMSG, 6
             dw IDL_HOST, 4, IDC_HOST, 4, IDL_PORT, 1, IDC_PORT, 1, IDC_PASS, 4, IDL_PASS, 4
             dw IDC_CONNECT, 1, IDC_CONN, 4, IDL_OUVERT, 4, IDC_OUVERT, 4, IDL_OUVERTP, 4, IDC_OUVERTP, 4
             dw IDL_FILE, 4, IDC_FILE, 4, IDC_BROWSE, 1, IDC_DELAY, 1
             dw IDL_SONG, 4, IDC_SONG, 4, IDL_MENU, 4, IDC_MENU, 4
             dw IDC_TWSTAT, 4, IDC_TWBTN, 1, IDC_CHATCMD, 1, IDC_ONTOP, 1, IDC_TRAY, 1
             dw IDC_DOT, 2, IDC_STATUS, 6, IDC_USEMODE, 3, IDC_ACTIVE, 3, 0
; brushes made in main, in g_hBgBrush order
brush_clr    dd CLR_BG, CLR_FIELD, CLR_SELBG, CLR_DIVIDER
; controls drawn with Windows' dark styles: 0 = DarkMode_CFD (fields), 1 = DarkMode_Explorer (buttons)
theme_tbl    dw IDC_HOST, 0, IDC_PORT, 0, IDC_PASS, 0, IDC_FILE, 0, IDC_DELAY, 0
             dw IDC_SONG, 0, IDC_MENU, 0, IDC_OUVERT, 0, IDC_OUVERTP, 0, IDC_REQLIST, 1, IDC_NEXT, 1, IDC_TWBTN, 1, IDC_ONTOP, 1, IDC_TRAY, 1, IDC_CHATCMD, 0, IDC_CONNECT, 1, IDC_BROWSE, 1, IDC_USEMODE, 1, 0
w_darkcfd    dw 'D','a','r','k','M','o','d','e','_','C','F','D',0
w_darkexp    dw 'D','a','r','k','M','o','d','e','_','E','x','p','l','o','r','e','r',0
align 4
g_one        dd 1                ; Windows rejects a misaligned value
; control, pages it shows on: bit 0 Requests, 1 Singleplayer, 2 Multiplayer,
; 3 Settings; 80h = "Use this mode" and 40h = "This mode is active" (see show_page)
page_tbl     dw IDL_HOST, 8, IDC_HOST, 8, IDL_PORT, 8, IDC_PORT, 8
             dw IDL_PASS, 8, IDC_PASS, 8, IDC_CONNECT, 8, IDC_CONN, 8
             dw IDL_OUVERT, 8, IDC_OUVERT, 8, IDL_OUVERTP, 8, IDC_OUVERTP, 8
             dw IDL_FILE, 8, IDC_FILE, 8, IDC_BROWSE, 8
             dw IDL_DELAY, 8, IDC_DELAY, 8, IDC_TWSTAT, 8, IDC_TWBTN, 8, IDL_CHATCMD, 8, IDC_CHATCMD, 8, IDL_ONTOP, 8, IDC_ONTOP, 8, IDL_TRAY, 8, IDC_TRAY, 8
             dw IDL_SONG, 6, IDC_SONG, 6, IDL_MENU, 6, IDC_MENU, 6
             dw IDC_REQLIST, 1, IDC_NEXT, 1, IDC_NEXTMSG, 1
             dw IDC_USEMODE, 80h, IDC_ACTIVE, 40h, 0

; ---------------------------------------------------------------------------
.data?

align 8
g_hInst     dq ?
g_hDlg      dq ?
g_hEvent    dq ?
g_hReqEvent dq ?            ; wakes the request thread
r_hSession  dq ?            ; request thread's WinHTTP session
r_path      dq ?            ; http_req: address asked for
r_host      dq ?            ;   server (UTF-16)
r_verb      dq ?            ;   GET or POST
r_body      dq ?            ;   body, or 0
g_blobin    dq 2 dup(?)     ; DATA_BLOB
g_blobout   dq 2 dup(?)
r_twdue     dq ?            ; when to next ask Twitch if sign-in finished
r_twend     dq ?            ; when the sign-in code expires
g_hSession  dq ?
g_hConnect  dq ?
g_hWs       dq ?
g_mtime     dq ?
g_delayms   dq ?            ; shared, under g_cs
w_delayms   dq ?            ; worker's copy
g_cs        dq 6 dup(?)     ; CRITICAL_SECTION (40 bytes)
g_scenes    dq MAXSCENES dup(?)
g_tmpptrs   dq MAXSCENES dup(?)
g_ofn       dq 19 dup(?)    ; OPENFILENAMEA (152 bytes)
g_nid       dq 66 dup(?)    ; NOTIFYICONDATAA (528 bytes)
g_pt        dq ?
g_reqnext   dd ?            ; set by the UI when Next song is clicked
g_nextbusy  dd ?            ; waiting for Ouvert's answer (UI thread)
g_twaction  dd ?            ; set by the UI: 1 sign in, 2 sign out, 3 cancel
g_cchui     dd ?
g_resave    dd ?            ; a secret was in plain text: save it encrypted
g_twstate   dd ?            ; 0 signed out, 1 signing in, 2 signed in
r_port      dd ?            ; http_req: port
r_flags     dd ?            ;   WinHTTP flags
r_status    dd ?            ;   HTTP status of the answer
r_stlen     dd ?
r_interval  dd ?            ; ms between sign-in checks
r_chatsent  dd ?
r_read      dd ?
r_err       dd ?
r_secs      dd ?
g_mode      dd ?            ; active mode: 0 = singleplayer, 1 = multiplayer
g_view      dd ?            ; mode whose page is shown (UI thread)
g_page      dd ?            ; 0 Requests, 1 Singleplayer, 2 Multiplayer, 3 Settings
g_modechg   dd ?            ; set by the UI when the active mode changes
g_connstate dd ?            ; 0 not connected, 1 connecting, 2 connected, 3 can't connect
g_cw0       dd ?            ; client size the controls were laid out for
g_ch0       dd ?
g_pl        dd 11 dup(?)    ; WINDOWPLACEMENT (44 bytes)
g_minw      dd ?            ; smallest window size
g_minh      dd ?
g_laydone   dd ?
g_navpad    dd ?            ; page list text inset, in pixels
g_rc        dd 4 dup(?)     ; RECT
g_lay       dq 5*32 dup(?)  ; per layout_tbl entry: control, then x, y, width, height (dwords)
g_hBgBrush  dq ?            ; brushes, in brush_clr order
g_hFieldBrush dq ?
g_hSelBrush dq ?
g_hDivBrush dq ?
g_want      dd ?
g_reconnect dd ?
g_read      dd ?
g_rlen      dd ?
g_rtype     dd ?
g_cch       dd ?
g_reasonlen dd ?
g_nscenes   dd ?
g_closecode dw ?
g_whost     dw 256 dup(?)
g_wtmp      dw 1024 dup(?)
; settings (written by the UI thread under g_cs)
g_host      db 256 dup(?)
g_port      db 16 dup(?)
g_pass      db 256 dup(?)
g_song      db 512 dup(?)
g_menu      db 512 dup(?)
g_delay     db 32 dup(?)
g_file      db 1024 dup(?)
g_mpsong    db 512 dup(?)   ; multiplayer scenes (g_song/g_menu are singleplayer)
g_mpmenu    db 512 dup(?)
g_modestr   db 4 dup(?)
; worker's copies
c_host      db 256 dup(?)
c_port      db 16 dup(?)
c_pass      db 256 dup(?)
w_song      db 512 dup(?)
w_menu      db 512 dup(?)
w_file      db 1024 dup(?)
w_msg       db 1024 dup(?)
w_cmsg      db 1024 dup(?)
; status lines (written by the worker under g_cs)
g_stat_conn  db 512 dup(?)
g_stat_event db 512 dup(?)
; UI scratch
g_uitmp     db 1024 dup(?)
g_uitmp2    db 2048 dup(?)
g_ofnfile   db 1024 dup(?)
g_dir       db 512 dup(?)
g_ini       db 512 dup(?)
g_json      db 512 dup(?)
g_home      db 512 dup(?)
; worker scratch
g_tmp       db 2048 dup(?)
g_data      db 1200 dup(?)
g_chal      db 128 dup(?)
g_salt      db 128 dup(?)
g_secret    db 64 dup(?)
g_auth      db 64 dup(?)
g_hash      db 32 dup(?)
g_err       db 512 dup(?)
g_reason    db 128 dup(?)
g_text      db TEXTSIZE dup(?)
g_last      db TEXTSIZE dup(?)
g_sbuf      db 2048 dup(?)
; Ouvert request queue
g_ouvert    db 128 dup(?)   ; public API key (written by the UI thread under g_cs)
g_ouvertp   db 128 dup(?)   ; private API key, used only for Next song
g_twaccess  db 256 dup(?)   ; Twitch sign-in (under g_cs; never shown)
g_twrefresh db 256 dup(?)
g_twid      db 32 dup(?)
g_twlogin   db 64 dup(?)
g_chatcmd   db 64 dup(?)
g_ontop     db 4 dup(?)
g_tray      db 4 dup(?)
g_winpos    db 64 dup(?)
g_twstat    db 512 dup(?)
g_nextmsg   db 512 dup(?)   ; result of Next song (under g_cs)
r_nmsg      db 512 dup(?)
g_reqtext   db 65536 dup(?) ; lines shown on the Requests page (under g_cs)
r_key       db 128 dup(?)   ; request thread's scratch
r_hdr       db 1024 dup(?)
r_whdr      dw 1024 dup(?)
r_form      db 2048 dup(?)
r_devcode   db 256 dup(?)
r_usercode  db 64 dup(?)
r_verif     db 512 dup(?)
r_twaccess  db 256 dup(?)
r_twrefresh db 256 dup(?)
r_twid      db 32 dup(?)
r_twlogin   db 64 dup(?)
r_chatcmd   db 64 dup(?)
r_title     db 400 dup(?)
r_name      db 64 dup(?)
r_list      db 65536 dup(?)
r_buf       db RESP_SIZE dup(?)
g_rbuf      db RBUF_SIZE dup(?)
g_pool      db MAXSCENES*512 dup(?)

; ---------------------------------------------------------------------------
.code

; ---- string helpers (leaf) -------------------------------------------------

; rcx = str -> rax = length
strlen PROC
    mov rax, rcx
sl_l:
    cmp byte ptr [rax], 0
    je sl_e
    inc rax
    jmp sl_l
sl_e:
    sub rax, rcx
    ret
strlen ENDP

; rcx = dst, rdx = src -> rax = pointer to dst's terminating zero
stpcpy PROC
sc_l:
    mov al, [rdx]
    mov [rcx], al
    test al, al
    jz sc_e
    inc rcx
    inc rdx
    jmp sc_l
sc_e:
    mov rax, rcx
    ret
stpcpy ENDP

; rcx = dst, rdx = src, r8 = dst size: bounded copy, always terminated
strncpy0 PROC
    dec r8
sn_l:
    test r8, r8
    jz sn_e
    mov al, [rdx]
    test al, al
    jz sn_e
    mov [rcx], al
    inc rcx
    inc rdx
    dec r8
    jmp sn_l
sn_e:
    mov byte ptr [rcx], 0
    ret
strncpy0 ENDP

; rcx = a, rdx = b -> eax = 1 if equal
streq PROC
se_l:
    mov al, [rcx]
    cmp al, [rdx]
    jne se_no
    test al, al
    jz se_yes
    inc rcx
    inc rdx
    jmp se_l
se_yes:
    mov eax, 1
    ret
se_no:
    xor eax, eax
    ret
streq ENDP

; rcx = haystack, rdx = needle -> rax = pointer just past the first match, or 0
strfind PROC
    push rsi
    push rdi
    mov r8, rcx
sf_outer:
    cmp byte ptr [r8], 0
    je sf_none
    mov rsi, r8
    mov rdi, rdx
sf_inner:
    mov al, [rdi]
    test al, al
    jz sf_found
    cmp al, [rsi]
    jne sf_next
    inc rsi
    inc rdi
    jmp sf_inner
sf_next:
    inc r8
    jmp sf_outer
sf_found:
    mov rax, rsi
    jmp sf_ret
sf_none:
    xor eax, eax
sf_ret:
    pop rdi
    pop rsi
    ret
strfind ENDP

; rcx = JSON string body (just after the opening quote), rdx = dst, r8 = dst size.
; Copies up to the closing quote, keeping escapes as-is. rax = closing quote.
copy_jstr PROC
    dec r8
cj_l:
    mov al, [rcx]
    test al, al
    jz cj_e
    cmp al, 22h
    je cj_e
    cmp al, 5Ch
    jne cj_put
    test r8, r8
    jz cj_s1
    mov [rdx], al
    inc rdx
    dec r8
cj_s1:
    inc rcx
    mov al, [rcx]
    test al, al
    jz cj_e
cj_put:
    test r8, r8
    jz cj_s2
    mov [rdx], al
    inc rdx
    dec r8
cj_s2:
    inc rcx
    jmp cj_l
cj_e:
    mov byte ptr [rdx], 0
    mov rax, rcx
    ret
copy_jstr ENDP

; rcx = str: decode JSON escapes in place (\uXXXX becomes UTF-8, line breaks a space)
unescape PROC
    mov rdx, rcx
ue_l:
    mov al, [rdx]
    cmp al, 5Ch
    je ue_esc
ue_put:
    mov [rcx], al
    test al, al
    jz ue_e
    inc rcx
    inc rdx
    jmp ue_l
ue_esc:
    inc rdx
    mov al, [rdx]
    cmp al, 'u'
    je ue_u
    cmp al, 'n'
    je ue_sp
    cmp al, 'r'
    je ue_sp
    cmp al, 't'
    jne ue_put
ue_sp:
    mov al, ' '
    jmp ue_put
ue_u:
    inc rdx
    call ue_hex4
    cmp eax, 0D800h                 ; high surrogate: combine with the \u that follows
    jb ue_enc
    cmp eax, 0DBFFh
    ja ue_enc
    cmp word ptr [rdx], 755Ch       ; "\u"
    jne ue_enc
    mov r8d, eax
    add rdx, 2
    call ue_hex4
    sub eax, 0DC00h
    and eax, 3FFh
    sub r8d, 0D800h
    shl r8d, 10
    lea eax, [rax+r8+10000h]
ue_enc:
    cmp eax, 20h                    ; control characters become a space
    jae ue_e1
    mov eax, ' '
ue_e1:
    cmp eax, 80h
    jae ue_e2
    mov [rcx], al
    inc rcx
    jmp ue_l
ue_e2:
    cmp eax, 800h
    jae ue_e3
    mov r8d, eax
    shr r8d, 6
    or r8b, 0C0h
    mov [rcx], r8b
    inc rcx
    jmp ue_last
ue_e3:
    cmp eax, 10000h
    jae ue_e4
    mov r8d, eax
    shr r8d, 12
    or r8b, 0E0h
    mov [rcx], r8b
    inc rcx
    jmp ue_mid
ue_e4:
    mov r8d, eax
    shr r8d, 18
    or r8b, 0F0h
    mov [rcx], r8b
    inc rcx
    mov r8d, eax
    shr r8d, 12
    and r8b, 3Fh
    or r8b, 80h
    mov [rcx], r8b
    inc rcx
ue_mid:
    mov r8d, eax
    shr r8d, 6
    and r8b, 3Fh
    or r8b, 80h
    mov [rcx], r8b
    inc rcx
ue_last:
    and al, 3Fh
    or al, 80h
    mov [rcx], al
    inc rcx
    jmp ue_l
ue_e:
    ret
unescape ENDP

; rdx = four hex digits -> eax = value, rdx moved past them; '?' if they aren't hex
ue_hex4 PROC
    xor eax, eax
    mov r9d, 4
uh_l:
    movzx r10d, byte ptr [rdx]
    sub r10d, '0'
    cmp r10d, 9
    jbe uh_add
    movzx r10d, byte ptr [rdx]
    or r10d, 20h
    sub r10d, 'a'
    cmp r10d, 5
    ja uh_bad
    add r10d, 10
uh_add:
    shl eax, 4
    or eax, r10d
    inc rdx
    dec r9d
    jnz uh_l
    ret
uh_bad:
    mov eax, '?'
    ret
ue_hex4 ENDP

; rcx = dst, rdx = src: copy, escaping " and \ for JSON -> rax = dst's terminating zero
json_escape PROC
je_l:
    mov al, [rdx]
    test al, al
    jz je_e
    cmp al, 22h
    je je_esc
    cmp al, 5Ch
    jne je_put
je_esc:
    mov byte ptr [rcx], 5Ch
    inc rcx
je_put:
    mov [rcx], al
    inc rcx
    inc rdx
    jmp je_l
je_e:
    mov byte ptr [rcx], 0
    mov rax, rcx
    ret
json_escape ENDP

; rcx = str: strip surrounding whitespace in place -> rax = new length
trim PROC
    mov rdx, rcx
tr_lead:
    mov al, [rdx]
    cmp al, 20h
    je tr_skip
    cmp al, 09h
    je tr_skip
    cmp al, 0Dh
    je tr_skip
    cmp al, 0Ah
    jne tr_copy
tr_skip:
    inc rdx
    jmp tr_lead
tr_copy:
    mov r8, rcx
    mov r9, rcx
tr_cl:
    mov al, [rdx]
    mov [r8], al
    test al, al
    jz tr_fin
    inc rdx
    inc r8
    cmp al, 20h
    je tr_cl
    cmp al, 09h
    je tr_cl
    cmp al, 0Dh
    je tr_cl
    cmp al, 0Ah
    je tr_cl
    mov r9, r8
    jmp tr_cl
tr_fin:
    mov byte ptr [r9], 0
    mov rax, r9
    sub rax, rcx
    ret
trim ENDP

; rcx = str: remove one leading and one trailing double quote, in place
strip_quotes PROC
    cmp byte ptr [rcx], 22h
    jne sq_end
    lea rdx, [rcx+1]
    mov r8, rcx
sq_c:
    mov al, [rdx]
    mov [r8], al
    inc rdx
    inc r8
    test al, al
    jnz sq_c
sq_end:
    mov rdx, rcx
sq_f:
    cmp byte ptr [rdx], 0
    je sq_t
    inc rdx
    jmp sq_f
sq_t:
    cmp rdx, rcx
    je sq_r
    cmp byte ptr [rdx-1], 22h
    jne sq_r
    mov byte ptr [rdx-1], 0
sq_r:
    ret
strip_quotes ENDP

; rcx = dst, rdx = text: copy the text's first line -> rax = dst's terminating zero
first_line PROC
fl_l:
    mov al, [rdx]
    cmp al, 0Dh
    je fl_e
    cmp al, 0Ah
    je fl_e
    mov [rcx], al
    test al, al
    jz fl_z
    inc rcx
    inc rdx
    jmp fl_l
fl_e:
    mov byte ptr [rcx], 0
fl_z:
    mov rax, rcx
    ret
first_line ENDP

; rcx = value, rdx = dst -> rax = pointer to dst's terminating zero
utoa PROC
    mov r8, rdx
    mov rax, rcx
    mov r10, 10
ut_n:
    inc r8
    xor edx, edx
    div r10
    test rax, rax
    jnz ut_n
    mov byte ptr [r8], 0
    mov r9, r8
    mov rax, rcx
ut_w:
    xor edx, edx
    div r10
    add dl, '0'
    dec r8
    mov [r8], dl
    test rax, rax
    jnz ut_w
    mov rax, r9
    ret
utoa ENDP

; rcx = str -> rax = unsigned value, or -1 if empty/invalid/over 32 bits
atou PROC
    xor eax, eax
    cmp byte ptr [rcx], 0
    je at_bad
at_l:
    movzx edx, byte ptr [rcx]
    test edx, edx
    jz at_ok
    sub edx, '0'
    cmp edx, 9
    ja at_bad
    imul rax, rax, 10
    add rax, rdx
    cmp rax, 0FFFFFFFFh
    ja at_bad
    inc rcx
    jmp at_l
at_ok:
    ret
at_bad:
    mov rax, -1
    ret
atou ENDP

; rcx = seconds as text ("2", "0.5", "1.25") -> rax = milliseconds, or -1
parse_ms PROC
    xor eax, eax
    xor r8d, r8d
pm_int:
    movzx edx, byte ptr [rcx]
    cmp edx, '.'
    je pm_dot
    test edx, edx
    jz pm_whole
    sub edx, '0'
    cmp edx, 9
    ja pm_bad
    imul rax, rax, 10
    add rax, rdx
    cmp rax, 1000000
    ja pm_bad
    inc r8d
    inc rcx
    jmp pm_int
pm_whole:
    imul rax, rax, 1000
    jmp pm_check
pm_dot:
    imul rax, rax, 1000
    inc rcx
    mov r9d, 100
pm_frac:
    movzx edx, byte ptr [rcx]
    test edx, edx
    jz pm_check
    sub edx, '0'
    cmp edx, 9
    ja pm_bad
    inc r8d
    imul edx, r9d
    add rax, rdx
    mov r10d, r9d
    xor r9d, r9d
    cmp r10d, 100
    jne pm_f1
    mov r9d, 10
pm_f1:
    cmp r10d, 10
    jne pm_f2
    mov r9d, 1
pm_f2:
    inc rcx
    jmp pm_frac
pm_check:
    test r8d, r8d
    jz pm_bad
    ret
pm_bad:
    mov rax, -1
    ret
parse_ms ENDP

; ---- files and settings ----------------------------------------------------

; rcx = path -> eax = 1 if it is an existing file
file_exists PROC
    sub rsp, 28h
    call [__imp_GetFileAttributesA]
    cmp eax, -1
    je fe_no
    test eax, 10h
    jnz fe_no
    mov eax, 1
    jmp fe_ret
fe_no:
    xor eax, eax
fe_ret:
    add rsp, 28h
    ret
file_exists ENDP

; rcx = path, rdx = buf, r8d = buf size, r9 = where to store the last-write time (or 0)
; -> eax = 1 if the file was opened. buf is always zero-terminated.
read_file PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 38h
    mov rsi, rdx
    mov edi, r8d
    mov r12, r9
    mov byte ptr [rsi], 0
    mov edx, 80000000h              ; GENERIC_READ
    mov r8d, 7                      ; share read/write/delete
    xor r9d, r9d
    mov qword ptr [rsp+20h], 3      ; OPEN_EXISTING
    and qword ptr [rsp+28h], 0
    and qword ptr [rsp+30h], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je rf_fail
    mov rbx, rax
    test r12, r12
    jz rf_read
    mov rcx, rbx
    xor edx, edx
    xor r8d, r8d
    mov r9, r12
    call [__imp_GetFileTime]
rf_read:
    mov rcx, rbx
    mov rdx, rsi
    lea r8d, [edi-1]
    lea r9, g_read
    and qword ptr [rsp+20h], 0
    call [__imp_ReadFile]
    test eax, eax
    jz rf_bad
    mov eax, g_read
    mov byte ptr [rsi+rax], 0
    jmp rf_close
rf_bad:
    mov byte ptr [rsi], 0
rf_close:
    mov rcx, rbx
    call [__imp_CloseHandle]
    mov eax, 1
    jmp rf_ret
rf_fail:
    xor eax, eax
rf_ret:
    add rsp, 38h
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
read_file ENDP

init_paths PROC
    sub rsp, 28h
    lea rcx, s_APPDATA
    lea rdx, g_dir
    mov r8d, 400
    call [__imp_GetEnvironmentVariableA]
    lea rcx, s_USERPROF
    lea rdx, g_home
    mov r8d, 400
    call [__imp_GetEnvironmentVariableA]
    lea rcx, g_dir
    call strlen
    lea rcx, g_dir
    add rcx, rax
    lea rdx, s_appname
    call stpcpy
    lea rcx, g_ini
    lea rdx, g_dir
    call stpcpy
    mov rcx, rax
    lea rdx, s_ininame
    call stpcpy
    lea rcx, g_json
    lea rdx, g_dir
    call stpcpy
    mov rcx, rax
    lea rdx, s_jsonname
    call stpcpy
    add rsp, 28h
    ret
init_paths ENDP

; rcx = secret: writes "dpapi:<base64>" to g_uitmp2, encrypted with Windows DPAPI so only
; this Windows user can read it. If that fails it writes "", never the plain text.
secret_encode PROC
    push rbx
    sub rsp, 40h
    mov rbx, rcx
    call strlen
    mov dword ptr g_blobin, eax
    mov qword ptr g_blobin+8, rbx
    lea rcx, g_blobin
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    mov qword ptr [rsp+28h], 1      ; CRYPTPROTECT_UI_FORBIDDEN
    lea rax, g_blobout
    mov [rsp+30h], rax
    call [__imp_CryptProtectData]
    test eax, eax
    jz se2_empty
    lea rcx, g_uitmp2
    lea rdx, s_secprefix
    call stpcpy
    mov rbx, rax
    mov g_cchui, 1900
    lea rax, g_cchui
    mov [rsp+20h], rax
    mov rcx, qword ptr g_blobout+8
    mov edx, dword ptr g_blobout
    mov r8d, 40000001h              ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
    mov r9, rbx
    call [__imp_CryptBinaryToStringA]
    mov rcx, qword ptr g_blobout+8
    mov rbx, rax                    ; result
    call [__imp_LocalFree]
    test rbx, rbx
    jz se2_empty
    lea rcx, g_uitmp2
    call strlen
    lea rcx, g_uitmp2
    mov word ptr [rcx+rax], 0022h
    jmp se2_ret
se2_empty:
    lea rcx, g_uitmp2
    mov word ptr [rcx], 2222h
    mov byte ptr [rcx+2], 0
se2_ret:
    add rsp, 40h
    pop rbx
    ret
secret_encode ENDP

; rcx = dst, edx = dst size: g_uitmp2 holds the saved value. Decrypts "dpapi:..."; plain
; text from an older version is kept and flagged to be saved encrypted. dst ends up
; empty if it can't be decrypted (another PC or Windows user).
secret_decode PROC
    push rbx
    push rsi
    sub rsp, 48h
    mov rbx, rcx
    mov esi, edx
    mov byte ptr [rbx], 0
    cmp dword ptr g_uitmp2, 70617064h   ; "dpap"
    jne sd_plain
    cmp word ptr g_uitmp2+4, 3A69h      ; "i:"
    jne sd_plain
    mov g_cchui, 1024
    lea rcx, g_uitmp2+6
    xor edx, edx                    ; zero-terminated
    mov r8d, 1                      ; CRYPT_STRING_BASE64
    lea r9, g_uitmp
    lea rax, g_cchui
    mov [rsp+20h], rax
    and qword ptr [rsp+28h], 0
    and qword ptr [rsp+30h], 0
    call [__imp_CryptStringToBinaryA]
    test eax, eax
    jz sd_ret
    mov eax, g_cchui
    mov dword ptr g_blobin, eax
    lea rax, g_uitmp
    mov qword ptr g_blobin+8, rax
    lea rcx, g_blobin
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    mov qword ptr [rsp+28h], 1      ; CRYPTPROTECT_UI_FORBIDDEN
    lea rax, g_blobout
    mov [rsp+30h], rax
    call [__imp_CryptUnprotectData]
    test eax, eax
    jz sd_ret
    mov ecx, dword ptr g_blobout
    lea eax, [rsi-1]
    cmp ecx, eax
    jbe sd_len
    mov ecx, eax
sd_len:
    mov rdx, qword ptr g_blobout+8
    mov r8, rbx
sd_c:
    test ecx, ecx
    jz sd_end
    mov al, [rdx]
    mov [r8], al
    inc rdx
    inc r8
    dec ecx
    jmp sd_c
sd_end:
    mov byte ptr [r8], 0
    mov rcx, qword ptr g_blobout+8
    call [__imp_LocalFree]
    jmp sd_ret
sd_plain:
    cmp byte ptr g_uitmp2, 0
    je sd_ret
    mov g_resave, 1
    mov rcx, rbx
    lea rdx, g_uitmp2
    mov r8d, esi
    call strncpy0
sd_ret:
    add rsp, 48h
    pop rsi
    pop rbx
    ret
secret_decode ENDP

load_settings PROC
    push rbx
    push rsi
    sub rsp, 38h
    lea rbx, settings_tbl
    mov esi, NSET
ls_l:
    lea rcx, s_section
    mov rdx, [rbx]
    mov r8, [rbx+24]
    mov r9, [rbx+8]
    mov rax, [rbx+16]
    lea rcx, settings_secret
    mov r10, rbx
    sub r10, rcx
    lea rcx, s_section
    cmp r10, 4*32
    jae ls_read
    lea r9, g_uitmp2                ; a secret: read it here, then decrypt it
    mov eax, 2048
ls_read:
    mov [rsp+20h], rax
    lea rax, g_ini
    mov [rsp+28h], rax
    call [__imp_GetPrivateProfileStringA]
    lea rcx, settings_secret
    mov rax, rbx
    sub rax, rcx
    cmp rax, 4*32
    jae ls_next
    mov rcx, [rbx+8]
    mov edx, [rbx+16]
    call secret_decode
ls_next:
    add rbx, 32
    dec esi
    jnz ls_l
    add rsp, 38h
    pop rsi
    pop rbx
    ret
load_settings ENDP

save_settings PROC
    push rbx
    push rsi
    sub rsp, 28h
    CS_ENTER                        ; the request thread updates the Twitch sign-in
    lea rcx, g_dir
    xor edx, edx
    call [__imp_CreateDirectoryA]
    lea rbx, settings_tbl
    mov esi, NSET
sv_l:
    ; quote the value so leading/trailing spaces and quotes survive
    lea rcx, g_uitmp2
    mov byte ptr [rcx], 22h
    inc rcx
    mov rdx, [rbx+8]
    call stpcpy
    mov word ptr [rax], 0022h
    lea rcx, settings_secret
    mov rax, rbx
    sub rax, rcx
    cmp rax, 4*32
    jae sv_write
    mov rcx, [rbx+8]
    cmp byte ptr [rcx], 0
    je sv_write
    call secret_encode
sv_write:
    lea rcx, s_section
    mov rdx, [rbx]
    lea r8, g_uitmp2
    lea r9, g_ini
    call [__imp_WritePrivateProfileStringA]
    add rbx, 32
    dec esi
    jnz sv_l
    CS_LEAVE
    add rsp, 28h
    pop rsi
    pop rbx
    ret
save_settings ENDP

; Import settings.json from the Python version if there is no settings.ini yet
migrate PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    lea rcx, g_ini
    call file_exists
    test eax, eax
    jnz mg_ret
    lea rcx, g_json
    lea rdx, g_rbuf
    mov r8d, 65536
    xor r9d, r9d
    call read_file
    test eax, eax
    jz mg_ret
    cmp byte ptr g_rbuf, 0
    je mg_ret
    lea rbx, settings_tbl
    lea rdi, mig_tbl
mg_l:
    mov rdx, [rdi]
    test rdx, rdx
    jz mg_save
    lea rcx, g_rbuf
    call strfind
    test rax, rax
    jz mg_next
    mov rsi, [rbx+8]
    cmp byte ptr [rax-1], 22h
    jne mg_num
    mov rcx, rax
    mov rdx, rsi
    mov r8, [rbx+16]
    call copy_jstr
    mov rcx, rsi
    call unescape
    jmp mg_next
mg_num:
    mov rdx, rsi
mg_nl:
    mov cl, [rax]
    cmp cl, '.'
    je mg_nput
    cmp cl, '0'
    jb mg_nend
    cmp cl, '9'
    ja mg_nend
mg_nput:
    mov [rdx], cl
    inc rdx
    inc rax
    jmp mg_nl
mg_nend:
    mov byte ptr [rdx], 0
mg_next:
    add rbx, 32
    add rdi, 8
    jmp mg_l
mg_save:
    call save_settings
mg_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
migrate ENDP

; Keep g_file if it exists, else use the first Clone Hero location that does
find_song_file PROC
    push rbx
    sub rsp, 20h
    cmp byte ptr g_file, 0
    je fs_cand
    lea rcx, g_file
    call file_exists
    test eax, eax
    jnz fs_ret
fs_cand:
    lea rbx, sfx_tbl
fs_l:
    cmp qword ptr [rbx], 0
    je fs_none
    lea rcx, g_uitmp2
    lea rdx, g_home
    call stpcpy
    mov rcx, rax
    mov rdx, [rbx]
    call stpcpy
    lea rcx, g_uitmp2
    call file_exists
    test eax, eax
    jnz fs_found
    add rbx, 8
    jmp fs_l
fs_found:
    lea rcx, g_file
    lea rdx, g_uitmp2
    call stpcpy
    jmp fs_ret
fs_none:
    cmp byte ptr g_file, 0
    jne fs_ret
    lea rcx, g_file
    lea rdx, g_home
    call stpcpy
    mov rcx, rax
    mov rdx, qword ptr sfx_tbl
    call stpcpy
fs_ret:
    add rsp, 20h
    pop rbx
    ret
find_song_file ENDP

; ---- OBS WebSocket (worker thread) -------------------------------------------

; rcx = zero-terminated input, rdx = out: base64(sha256(input))
sha_b64 PROC
    push rbx
    push rsi
    sub rsp, 48h
    mov rbx, rcx
    mov rsi, rdx
    call strlen
    mov [rsp+20h], rax
    lea rax, g_hash
    mov [rsp+28h], rax
    mov qword ptr [rsp+30h], 32
    mov ecx, 41h                    ; BCRYPT_SHA256_ALG_HANDLE
    xor edx, edx
    xor r8d, r8d
    mov r9, rbx
    call [__imp_BCryptHash]
    mov g_cch, 64
    lea rax, g_cch
    mov [rsp+20h], rax
    lea rcx, g_hash
    mov edx, 32
    mov r8d, 40000001h              ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
    mov r9, rsi
    call [__imp_CryptBinaryToStringA]
    add rsp, 48h
    pop rsi
    pop rbx
    ret
sha_b64 ENDP

ws_close PROC
    sub rsp, 28h
    mov rcx, g_hWs
    test rcx, rcx
    jz wc_1
    call [__imp_WinHttpCloseHandle]
    mov g_hWs, 0
wc_1:
    mov rcx, g_hConnect
    test rcx, rcx
    jz wc_2
    call [__imp_WinHttpCloseHandle]
    mov g_hConnect, 0
wc_2:
    add rsp, 28h
    ret
ws_close ENDP

; rcx = zero-terminated text message -> eax = 1 if sent
ws_send_z PROC
    push rbx
    sub rsp, 20h
    mov rbx, rcx
    call strlen
    mov rcx, g_hWs
    mov edx, 2                      ; UTF8 message
    mov r8, rbx
    mov r9d, eax
    call [__imp_WinHttpWebSocketSend]
    test eax, eax
    setz al
    movzx eax, al
    add rsp, 20h
    pop rbx
    ret
ws_send_z ENDP

; Receives one whole message into g_rbuf -> eax = 1, or 0 on error/close
ws_recv PROC
    push rbx
    sub rsp, 30h
    xor ebx, ebx
wr_l:
    mov rcx, g_hWs
    lea rdx, g_rbuf
    add rdx, rbx
    mov r8d, RBUF_SIZE-1
    sub r8d, ebx
    jz wr_fail
    lea r9, g_rlen
    lea rax, g_rtype
    mov [rsp+20h], rax
    call [__imp_WinHttpWebSocketReceive]
    test eax, eax
    jnz wr_fail
    cmp g_rtype, 4                  ; close
    je wr_fail
    add ebx, g_rlen
    cmp g_rtype, 1                  ; binary fragment
    je wr_l
    cmp g_rtype, 3                  ; UTF8 fragment
    je wr_l
    lea rcx, g_rbuf
    mov byte ptr [rcx+rbx], 0
    mov eax, 1
    jmp wr_ret
wr_fail:
    xor eax, eax
wr_ret:
    add rsp, 30h
    pop rbx
    ret
ws_recv ENDP

; Connects and logs in to OBS using c_host/c_port/c_pass
; -> eax = 1, or 0 with the reason in g_err
ws_connect PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 40h
    call ws_close
    cmp g_hSession, 0
    jne cn_sess
    lea rcx, w_agent
    mov edx, 1                      ; WINHTTP_ACCESS_TYPE_NO_PROXY
    xor r8d, r8d
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    call [__imp_WinHttpOpen]
    mov g_hSession, rax
    test rax, rax
    jz cn_err
    mov rcx, rax
    mov edx, 3000
    mov r8d, 3000
    mov r9d, 3000
    mov qword ptr [rsp+20h], 3000
    call [__imp_WinHttpSetTimeouts]
cn_sess:
    lea rcx, c_port
    call atou
    mov rbx, rax
    mov ecx, 65001
    xor edx, edx
    lea r8, c_host
    mov r9d, -1
    lea rax, g_whost
    mov [rsp+20h], rax
    mov qword ptr [rsp+28h], 256
    call [__imp_MultiByteToWideChar]
    mov rcx, g_hSession
    lea rdx, g_whost
    movzx r8d, bx
    xor r9d, r9d
    call [__imp_WinHttpConnect]
    mov g_hConnect, rax
    test rax, rax
    jz cn_err
    mov rcx, rax
    lea rdx, w_get
    lea r8, w_slash
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    and qword ptr [rsp+28h], 0
    and qword ptr [rsp+30h], 0
    call [__imp_WinHttpOpenRequest]
    mov rsi, rax
    test rax, rax
    jz cn_err
    mov rcx, rsi
    mov edx, 114                    ; WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_WinHttpSetOption]
    test eax, eax
    jz cn_reqerr
    mov rcx, rsi
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    and qword ptr [rsp+28h], 0
    and qword ptr [rsp+30h], 0
    call [__imp_WinHttpSendRequest]
    test eax, eax
    jz cn_reqerr
    mov rcx, rsi
    xor edx, edx
    call [__imp_WinHttpReceiveResponse]
    test eax, eax
    jz cn_reqerr
    mov rcx, rsi
    xor edx, edx
    call [__imp_WinHttpWebSocketCompleteUpgrade]
    mov g_hWs, rax
    test rax, rax
    jz cn_reqerr
    mov rcx, rsi
    call [__imp_WinHttpCloseHandle]

    ; Hello -> Identify, with authentication if OBS asks for it
    call ws_recv
    test eax, eax
    jz cn_closed
    lea rcx, g_sbuf
    lea rdx, s_ident1
    call stpcpy
    mov rdi, rax
    lea rcx, g_rbuf
    lea rdx, s_challenge
    call strfind
    test rax, rax
    jz cn_noauth
    mov rcx, rax
    lea rdx, g_chal
    mov r8d, 128
    call copy_jstr
    lea rcx, g_rbuf
    lea rdx, s_salt
    call strfind
    test rax, rax
    jz cn_noauth
    mov rcx, rax
    lea rdx, g_salt
    mov r8d, 128
    call copy_jstr
    ; secret = base64(sha256(password + salt))
    lea rcx, g_tmp
    lea rdx, c_pass
    call stpcpy
    mov rcx, rax
    lea rdx, g_salt
    call stpcpy
    lea rcx, g_tmp
    lea rdx, g_secret
    call sha_b64
    ; auth = base64(sha256(secret + challenge))
    lea rcx, g_tmp
    lea rdx, g_secret
    call stpcpy
    mov rcx, rax
    lea rdx, g_chal
    call stpcpy
    lea rcx, g_tmp
    lea rdx, g_auth
    call sha_b64
    mov rcx, rdi
    lea rdx, s_identauth
    call stpcpy
    mov rcx, rax
    lea rdx, g_auth
    call stpcpy
    mov rcx, rax
    lea rdx, s_quote
    call stpcpy
    mov rdi, rax
cn_noauth:
    mov rcx, rdi
    lea rdx, s_close2
    call stpcpy
    lea rcx, g_sbuf
    call ws_send_z
    test eax, eax
    jz cn_closed
    call ws_recv
    test eax, eax
    jz cn_closed
    lea rcx, g_rbuf
    lea rdx, s_op2                  ; Identified
    call strfind
    test rax, rax
    jz cn_closed
    mov eax, 1
    jmp cn_ret

cn_reqerr:
    call [__imp_GetLastError]
    mov ebx, eax
    mov rcx, rsi
    call [__imp_WinHttpCloseHandle]
    jmp cn_code
cn_err:
    call [__imp_GetLastError]
    mov ebx, eax
cn_code:
    lea rcx, g_err
    lea rdx, s_noresp
    call stpcpy
    mov rcx, rax
    call append_hostport
    mov rcx, rax
    lea rdx, s_errcode
    call stpcpy
    mov ecx, ebx
    mov rdx, rax
    call utoa
    mov rcx, rax
    lea rdx, s_rparen
    call stpcpy
    jmp cn_fail
cn_closed:
    lea rcx, g_err
    lea rdx, s_closed
    call stpcpy
    mov rdi, rax
    mov rcx, g_hWs
    test rcx, rcx
    jz cn_fail
    lea rdx, g_closecode
    lea r8, g_reason
    mov r9d, 123
    lea rax, g_reasonlen
    mov [rsp+20h], rax
    call [__imp_WinHttpWebSocketQueryCloseStatus]
    test eax, eax
    jnz cn_fail
    mov eax, g_reasonlen
    test eax, eax
    jz cn_fail
    lea rcx, g_reason
    mov byte ptr [rcx+rax], 0
    mov rcx, rdi
    lea rdx, s_colon
    call stpcpy
    mov rcx, rax
    lea rdx, g_reason
    call stpcpy
cn_fail:
    call ws_close
    xor eax, eax
cn_ret:
    add rsp, 40h
    pop rdi
    pop rsi
    pop rbx
    ret
ws_connect ENDP

; rcx = dst: append "host:port" -> rax = dst's terminating zero
append_hostport PROC
    sub rsp, 28h
    lea rdx, c_host
    call stpcpy
    mov byte ptr [rax], ':'
    lea rcx, [rax+1]
    lea rdx, c_port
    call stpcpy
    add rsp, 28h
    ret
append_hostport ENDP

; rcx = requestType, rdx = requestData JSON -> eax = 1 if OBS reports success.
; The response is left in g_rbuf.
obs_request PROC
    push rbx
    push rsi
    sub rsp, 28h
    mov rbx, rcx
    mov rsi, rdx
    lea rcx, g_sbuf
    lea rdx, s_req1
    call stpcpy
    mov rcx, rax
    mov rdx, rbx
    call stpcpy
    mov rcx, rax
    lea rdx, s_req2
    call stpcpy
    mov rcx, rax
    mov rdx, rsi
    call stpcpy
    mov rcx, rax
    lea rdx, s_close2
    call stpcpy
    lea rcx, g_sbuf
    call ws_send_z
    test eax, eax
    jz or_fail
or_wait:
    call ws_recv
    test eax, eax
    jz or_fail
    lea rcx, g_rbuf
    lea rdx, s_op7                  ; RequestResponse
    call strfind
    test rax, rax
    jz or_wait
    lea rcx, g_rbuf
    lea rdx, s_restrue
    call strfind
    test rax, rax
    setnz al
    movzx eax, al
    jmp or_ret
or_fail:
    xor eax, eax
or_ret:
    add rsp, 28h
    pop rsi
    pop rbx
    ret
obs_request ENDP

; Fills g_scenes/g_nscenes in the order of OBS's Scenes dock -> eax = 1 if ok
get_scenes PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    lea rcx, s_GetScenes
    lea rdx, s_emptyobj
    call obs_request
    test eax, eax
    jz gs_ret
    CS_ENTER                        ; the UI reads the list too
    lea rsi, g_rbuf
    lea rdi, g_pool
    xor ebx, ebx
gs_l:
    cmp ebx, MAXSCENES
    jae gs_rev
    mov rcx, rsi
    lea rdx, s_sceneName
    call strfind
    test rax, rax
    jz gs_rev
    lea rcx, g_tmpptrs
    mov [rcx+rbx*8], rdi
    inc ebx
    mov rcx, rax
    mov rdx, rdi
    mov r8d, 512
    call copy_jstr
    mov rsi, rax
    mov rcx, rdi
    call unescape
    mov rcx, rdi
    call strlen
    lea rdi, [rdi+rax+1]
    jmp gs_l
gs_rev:
    ; OBS lists scenes bottom-to-top, so reverse to match the Scenes dock
    mov g_nscenes, ebx
    xor ecx, ecx
    lea r8, g_tmpptrs
    lea r9, g_scenes
gs_r:
    cmp ecx, ebx
    jae gs_ok
    mov edx, ebx
    sub edx, ecx
    dec edx
    mov rax, [r8+rdx*8]
    mov [r9+rcx*8], rax
    inc ecx
    jmp gs_r
gs_ok:
    CS_LEAVE
    mov eax, 1
gs_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
get_scenes ENDP

; rcx = scene name -> eax = 1 if switched
sw_try PROC
    push rbx
    sub rsp, 20h
    mov rbx, rcx
    lea rcx, g_data
    lea rdx, s_scn1
    call stpcpy
    mov rcx, rax
    mov rdx, rbx
    call json_escape
    mov rcx, rax
    lea rdx, s_scn2
    call stpcpy
    lea rcx, s_SetScene
    lea rdx, g_data
    call obs_request
    add rsp, 20h
    pop rbx
    ret
sw_try ENDP

; ---- worker thread -------------------------------------------------------------

; ecx = 0 for the connection line, 1 for the event line; rdx = UTF-8 text
post_status PROC
    push rbx
    push rsi
    sub rsp, 28h
    mov ebx, ecx
    mov rsi, rdx
    CS_ENTER
    lea rcx, g_stat_conn
    test ebx, ebx
    jz ps_cpy
    lea rcx, g_stat_event
ps_cpy:
    mov rdx, rsi
    mov r8d, 512
    call strncpy0
    CS_LEAVE
    mov rcx, g_hDlg
    mov edx, WM_APP_STATUS
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_PostMessageA]
    add rsp, 28h
    pop rsi
    pop rbx
    ret
post_status ENDP

post_connected PROC
    sub rsp, 28h
    mov g_connstate, 2
    lea rcx, w_cmsg
    lea rdx, st_connected
    call stpcpy
    mov rcx, rax
    call append_hostport
    xor ecx, ecx
    lea rdx, w_cmsg
    call post_status
    add rsp, 28h
    ret
post_connected ENDP

; -> rax = song scene buffer, rdx = menu scene buffer for the selected tab
active_bufs PROC
    lea rax, g_song
    lea rdx, g_menu
    cmp g_mode, 0
    je ab_ret
    lea rax, g_mpsong
    lea rdx, g_mpmenu
ab_ret:
    ret
active_bufs ENDP

; -> rax = song scene buffer, rdx = menu scene buffer for the mode page being viewed
view_bufs PROC
    lea rax, g_song
    lea rdx, g_menu
    cmp g_view, 0
    je vb_ret
    lea rax, g_mpsong
    lea rdx, g_mpmenu
vb_ret:
    ret
view_bufs ENDP

; Copy the settings the watcher needs
wk_sync PROC
    push rbx
    push rsi
    sub rsp, 28h
    CS_ENTER
    call active_bufs
    mov rbx, rax
    mov rsi, rdx
    lea rcx, w_song
    mov rdx, rbx
    call stpcpy
    lea rcx, w_menu
    mov rdx, rsi
    call stpcpy
    lea rcx, w_file
    lea rdx, g_file
    call stpcpy
    mov rax, g_delayms
    mov w_delayms, rax
    CS_LEAVE
    add rsp, 28h
    pop rsi
    pop rbx
    ret
wk_sync ENDP

; Reads currentsong.txt into g_text (trimmed) and its last-write time into g_mtime
read_state PROC
    sub rsp, 28h
    mov g_mtime, 0
    lea rcx, w_file
    lea rdx, g_text
    mov r8d, TEXTSIZE
    lea r9, g_mtime
    call read_file
    lea rcx, g_text
    call trim
    add rsp, 28h
    ret
read_state ENDP

; One connection attempt with the current settings -> eax = 1 if connected
wk_connect PROC
    sub rsp, 28h
    CS_ENTER
    lea rcx, c_host
    lea rdx, g_host
    call stpcpy
    lea rcx, c_port
    lea rdx, g_port
    call stpcpy
    lea rcx, c_pass
    lea rdx, g_pass
    call stpcpy
    CS_LEAVE
    lea rcx, w_cmsg
    lea rdx, st_connecting
    call stpcpy
    mov rcx, rax
    call append_hostport
    mov rcx, rax
    lea rdx, st_dots
    call stpcpy
    mov g_connstate, 1
    xor ecx, ecx
    lea rdx, w_cmsg
    call post_status
    call ws_connect
    test eax, eax
    jz kc_fail
    call get_scenes
    test eax, eax
    jz kc_noscenes
    mov rcx, g_hDlg
    mov edx, WM_APP_SCENES
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_PostMessageA]
    call post_connected
    mov eax, 1
    jmp kc_ret
kc_noscenes:
    lea rcx, g_err
    lea rdx, s_noscenes
    call stpcpy
    call ws_close
kc_fail:
    lea rcx, w_cmsg
    lea rdx, st_cant
    call stpcpy
    mov rcx, rax
    lea rdx, g_err
    call stpcpy
    mov rcx, rax
    lea rdx, st_retry
    call stpcpy
    mov g_connstate, 3
    xor ecx, ecx
    lea rdx, w_cmsg
    call post_status
    xor eax, eax
kc_ret:
    add rsp, 28h
    ret
wk_connect ENDP

; rcx = scene name (empty = no switch), rdx = end of the event text in w_msg.
; Switches (reconnecting once if needed), appends the result and posts the
; event line -> eax = 0 if the connection is gone.
wk_switch PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov rbx, rcx
    mov rsi, rdx
    cmp byte ptr [rbx], 0
    je ks_post
    mov rcx, rbx
    call sw_try
    test eax, eax
    jnz ks_ok
    mov g_connstate, 1
    xor ecx, ecx
    lea rdx, st_lost
    call post_status
    call ws_connect
    test eax, eax
    jz ks_fail
    call post_connected
    mov rcx, rbx
    call sw_try
    test eax, eax
    jnz ks_ok
ks_fail:
    mov rcx, rsi
    lea rdx, ev_fail1
    call stpcpy
    mov rcx, rax
    mov rdx, rbx
    call stpcpy
    mov rcx, rax
    lea rdx, ev_fail2
    call stpcpy
    mov ecx, 1
    lea rdx, w_msg
    call post_status
    call ws_close
    xor eax, eax
    jmp ks_ret
ks_ok:
    mov rcx, rsi
    lea rdx, ev_arrow
    call stpcpy
    mov rcx, rax
    mov rdx, rbx
    call stpcpy
ks_post:
    mov ecx, 1
    lea rdx, w_msg
    call post_status
    mov eax, 1
ks_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
wk_switch ENDP

; Thread: rbx = connected, rsi = next retry tick, r12 = last mtime,
; r13d = song playing, r14d = menu switch pending, r15 = when it is due
worker PROC
    sub rsp, 28h
    xor ebx, ebx
    xor esi, esi
wk_loop:
    mov rcx, g_hEvent
    mov edx, POLL_MS
    call [__imp_WaitForSingleObject]
    xor eax, eax
    xchg eax, g_reconnect
    test eax, eax
    jz wk_noreq
    call ws_close
    xor ebx, ebx
    xor esi, esi
wk_noreq:
    ; tab changed: move OBS to the new tab's scene for where we are now
    xor eax, eax
    xchg eax, g_modechg
    test eax, eax
    jz wk_nomode
    test ebx, ebx
    jz wk_nomode
    call wk_sync
    lea rcx, w_msg
    lea rdx, s_sp
    cmp g_mode, 0
    je wk_mname
    lea rdx, s_mp
wk_mname:
    call stpcpy
    mov rdx, rax
    lea rcx, w_song
    test r13d, r13d
    jnz wk_mswitch
    test r14d, r14d                 ; menu switch still pending: it uses the new scene
    jnz wk_nomode
    lea rcx, w_menu
wk_mswitch:
    call wk_switch
    test eax, eax
    jnz wk_nomode
    xor ebx, ebx
    xor esi, esi
wk_nomode:
    test ebx, ebx
    jnz wk_watch
    cmp g_want, 0
    je wk_loop
    call [__imp_GetTickCount64]
    cmp rax, rsi
    jb wk_loop
    call wk_connect
    test eax, eax
    jnz wk_up
    call [__imp_GetTickCount64]
    add rax, RETRY_MS
    mov rsi, rax
    jmp wk_loop

wk_up:
    ; take the file's current state as the starting point, without switching
    mov ebx, 1
    call wk_sync
    call read_state
    lea rcx, g_last
    lea rdx, g_text
    call stpcpy
    mov r12, g_mtime
    xor r13d, r13d
    xor r14d, r14d
    lea rdx, ev_pick
    cmp byte ptr w_song, 0
    je wk_upmsg
    lea rdx, ev_wait
    cmp byte ptr g_text, 0
    je wk_upmsg
    mov r13d, 1
    lea rcx, w_msg
    lea rdx, ev_song
    call stpcpy
    mov rcx, rax
    lea rdx, g_text
    call first_line
    lea rdx, w_msg
wk_upmsg:
    mov ecx, 1
    call post_status
    jmp wk_loop

wk_watch:
    call wk_sync
    call read_state
    cmp r12, g_mtime
    jne wk_changed
    lea rcx, g_text
    lea rdx, g_last
    call streq
    test eax, eax
    jnz wk_pending
wk_changed:
    mov r12, g_mtime
    lea rcx, g_last
    lea rdx, g_text
    call stpcpy
    cmp byte ptr g_text, 0
    je wk_empty
    lea rcx, w_msg
    lea rdx, ev_song
    call stpcpy
    mov rcx, rax
    lea rdx, g_text
    call first_line
    xor r14d, r14d
    test r13d, r13d
    jnz wk_same
    mov r13d, 1
    mov rdx, rax
    lea rcx, w_song
    call wk_switch
    jmp wk_result
wk_same:
    ; already on the song scene: just show the new song
    mov ecx, 1
    lea rdx, w_msg
    call post_status
    jmp wk_pending
wk_empty:
    test r13d, r13d
    jz wk_pending
    xor r13d, r13d
    mov r14d, 1
    call [__imp_GetTickCount64]
    add rax, w_delayms
    mov r15, rax
    mov ecx, 1
    lea rdx, ev_ended
    call post_status
wk_pending:
    test r14d, r14d
    jz wk_loop
    call [__imp_GetTickCount64]
    cmp rax, r15
    jb wk_loop
    xor r14d, r14d
    lea rcx, w_msg
    lea rdx, ev_ended
    call stpcpy
    mov rdx, rax
    lea rcx, w_menu
    call wk_switch
wk_result:
    test eax, eax
    jnz wk_loop
    xor ebx, ebx                    ; connection lost: reconnect now
    xor esi, esi
    jmp wk_loop
worker ENDP

; ---- request thread ------------------------------------------------------------

; Sends the request described by r_host, r_port, r_flags, r_verb, r_path, r_hdr and
; r_body. The answer goes in r_buf and its status in r_status -> eax = 1, or 0 with r_err
http_req PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48h
    xor ebx, ebx                    ; connection
    xor esi, esi                    ; request
    xor r12d, r12d                  ; result
    cmp r_hSession, 0
    jne rq_sess
    lea rcx, w_agent
    mov edx, 4                      ; WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
    xor r8d, r8d
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    call [__imp_WinHttpOpen]
    mov r_hSession, rax
    test rax, rax
    jz rq_err
    mov rcx, rax
    mov edx, 5000
    mov r8d, 5000
    mov r9d, 5000
    mov qword ptr [rsp+20h], 5000
    call [__imp_WinHttpSetTimeouts]
rq_sess:
    mov rcx, r_hSession
    mov rdx, r_host
    mov r8d, r_port
    xor r9d, r9d
    call [__imp_WinHttpConnect]
    mov rbx, rax
    test rax, rax
    jz rq_err
    mov rcx, rbx
    mov rdx, r_verb
    mov r8, r_path
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    and qword ptr [rsp+28h], 0
    mov eax, r_flags
    mov [rsp+30h], rax
    call [__imp_WinHttpOpenRequest]
    mov rsi, rax
    test rax, rax
    jz rq_err
    mov ecx, 65001
    xor edx, edx
    lea r8, r_hdr
    mov r9d, -1
    lea rax, r_whdr
    mov [rsp+20h], rax
    mov qword ptr [rsp+28h], 1024
    call [__imp_MultiByteToWideChar]
    xor eax, eax
    mov rcx, r_body
    test rcx, rcx
    jz rq_len
    call strlen
rq_len:
    mov [rsp+20h], rax
    mov [rsp+28h], rax
    and qword ptr [rsp+30h], 0
    mov rcx, rsi
    lea rdx, r_whdr
    mov r8d, -1
    mov r9, r_body
    call [__imp_WinHttpSendRequest]
    test eax, eax
    jz rq_err
    mov rcx, rsi
    xor edx, edx
    call [__imp_WinHttpReceiveResponse]
    test eax, eax
    jz rq_err
    mov r_status, 0
    mov r_stlen, 4
    mov rcx, rsi
    mov edx, 20000013h              ; WINHTTP_QUERY_STATUS_CODE | FLAG_NUMBER
    xor r8d, r8d
    lea r9, r_status
    lea rax, r_stlen
    mov [rsp+20h], rax
    and qword ptr [rsp+28h], 0
    call [__imp_WinHttpQueryHeaders]
    xor edi, edi                    ; bytes so far
rq_read:
    mov r8d, RESP_SIZE-1
    sub r8d, edi
    jz rq_done
    mov rcx, rsi
    lea rdx, r_buf
    add rdx, rdi
    lea r9, r_read
    call [__imp_WinHttpReadData]
    test eax, eax
    jz rq_err
    cmp r_read, 0
    je rq_done
    add edi, r_read
    jmp rq_read
rq_done:
    lea rcx, r_buf
    mov byte ptr [rcx+rdi], 0
    mov r12d, 1
    jmp rq_close
rq_err:
    call [__imp_GetLastError]
    mov r_err, eax
rq_close:
    test rsi, rsi
    jz rq_c1
    mov rcx, rsi
    call [__imp_WinHttpCloseHandle]
rq_c1:
    test rbx, rbx
    jz rq_c2
    mov rcx, rbx
    call [__imp_WinHttpCloseHandle]
rq_c2:
    mov eax, r12d
    add rsp, 48h
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
http_req ENDP

; GET r_path from Ouvert with the key in r_key -> eax = 1, or 0 with r_err
req_fetch PROC
    sub rsp, 28h
    lea rax, w_ohost
    mov r_host, rax
    mov r_port, OUVERT_PORT
    mov r_flags, OUVERT_FLAGS
    lea rax, w_get
    mov r_verb, rax
    mov r_body, 0
    lea rcx, r_hdr
    lea rdx, s_keyhdr
    call stpcpy
    mov rcx, rax
    lea rdx, r_key
    call stpcpy
    call http_req
    add rsp, 28h
    ret
req_fetch ENDP

; rcx = '{' -> rax = its matching '}', or 0 if the text ends first (leaf)
obj_end PROC
    xor edx, edx                    ; depth
    xor r8d, r8d                    ; inside a string
oe_l:
    mov al, [rcx]
    test al, al
    jz oe_none
    test r8d, r8d
    jz oe_out
    cmp al, 5Ch
    jne oe_q
    inc rcx                         ; skip the escaped character
    cmp byte ptr [rcx], 0
    je oe_none
    jmp oe_next
oe_q:
    cmp al, 22h
    jne oe_next
    xor r8d, r8d
    jmp oe_next
oe_out:
    cmp al, 22h
    jne oe_o1
    mov r8d, 1
    jmp oe_next
oe_o1:
    cmp al, '{'
    jne oe_o2
    inc edx
    jmp oe_next
oe_o2:
    cmp al, '}'
    jne oe_next
    dec edx
    jz oe_found
oe_next:
    inc rcx
    jmp oe_l
oe_found:
    mov rax, rcx
    ret
oe_none:
    xor eax, eax
    ret
obj_end ENDP

; Turns the response in r_buf into display lines in r_list -> eax = 0 if it isn't a queue
req_parse PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 20h
    lea rcx, r_buf
    lea rdx, s_rstatus
    call strfind
    test rax, rax
    jz rp_bad
    lea rcx, r_buf
    lea rdx, s_rdata
    call strfind
    test rax, rax
    jz rp_bad
    mov rsi, rax                    ; read position
    lea rdi, r_list                 ; write position
    mov byte ptr [rdi], 0
    xor ebx, ebx                    ; requests so far
rp_scan:
    mov al, [rsi]
    test al, al
    jz rp_end
    cmp al, ']'
    je rp_end
    cmp al, '{'
    je rp_obj
    inc rsi
    jmp rp_scan
rp_obj:
    cmp ebx, REQ_MAX
    jae rp_end
    mov r12, rsi
    mov rcx, rsi
    call obj_end
    test rax, rax
    jz rp_end                       ; cut off: show what arrived
    mov r13, rax
    mov byte ptr [r13], 0           ; search this request only
    mov byte ptr r_title, 0
    mov byte ptr r_name, 0
    mov rcx, r12
    lea rdx, s_rreq
    call strfind
    test rax, rax
    jz rp_noreq
    mov rcx, rax
    lea rdx, r_title
    mov r8d, 400
    call copy_jstr
    lea rcx, r_title
    call unescape
rp_noreq:
    mov rcx, r12
    lea rdx, s_rname
    call strfind
    test rax, rax
    jz rp_noname
    mov rcx, rax
    lea rdx, r_name
    mov r8d, 64
    call copy_jstr
    lea rcx, r_name
    call unescape
rp_noname:
    ; "1. Artist: Song   -   requester   (2:19)"
    inc ebx
    mov ecx, ebx
    mov rdx, rdi
    call utoa
    mov word ptr [rax], 202Eh       ; ". "
    lea rcx, [rax+2]
    lea rdx, r_title
    call stpcpy
    mov rdi, rax
    cmp byte ptr r_name, 0
    je rp_len
    mov rcx, rdi
    lea rdx, s_rsep
    call stpcpy
    mov rcx, rax
    lea rdx, r_name
    call stpcpy
    mov rdi, rax
rp_len:
    mov rcx, r12
    lea rdx, s_rlen
    call strfind
    test rax, rax
    jz rp_eol
    cmp byte ptr [rax], 22h         ; a number or a quoted number
    jne rp_digits
    inc rax
rp_digits:
    xor ecx, ecx
    xor r8d, r8d                    ; digits seen
rp_dl:
    movzx edx, byte ptr [rax]
    sub edx, '0'
    cmp edx, 9
    ja rp_dd
    cmp ecx, 1000000
    jae rp_eol
    imul ecx, ecx, 10
    add ecx, edx
    inc r8d
    inc rax
    jmp rp_dl
rp_dd:
    test r8d, r8d
    jz rp_eol
    mov eax, ecx
    xor edx, edx
    mov ecx, 60
    div ecx
    mov r_secs, edx
    mov r12d, eax                   ; minutes
    mov rcx, rdi
    lea rdx, s_ropen
    call stpcpy
    mov rdx, rax
    mov ecx, r12d
    call utoa
    mov byte ptr [rax], ':'
    mov rdi, rax
    inc rdi
    mov eax, r_secs
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    add dl, '0'
    mov [rdi], al
    mov [rdi+1], dl
    mov byte ptr [rdi+2], ')'
    add rdi, 3
rp_eol:
    mov word ptr [rdi], 000Ah
    inc rdi
    lea rsi, [r13+1]
    jmp rp_scan
rp_end:
    test ebx, ebx
    jnz rp_ok
    lea rcx, r_list
    lea rdx, s_rempty
    call stpcpy
rp_ok:
    mov eax, 1
    jmp rp_ret
rp_bad:
    xor eax, eax
rp_ret:
    add rsp, 20h
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
req_parse ENDP

; Hands r_list to the UI if it changed
req_publish PROC
    push rbx
    sub rsp, 20h
    CS_ENTER
    lea rcx, r_list
    lea rdx, g_reqtext
    call streq
    mov ebx, eax
    test eax, eax
    jnz rb_same
    lea rcx, g_reqtext
    lea rdx, r_list
    call stpcpy
rb_same:
    CS_LEAVE
    test ebx, ebx
    jnz rb_ret
    mov rcx, g_hDlg
    mov edx, WM_APP_REQS
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_PostMessageA]
rb_ret:
    add rsp, 20h
    pop rbx
    ret
req_publish ENDP

; rcx = dst, rdx = src: copy, percent-encoding for a form body (leaf)
; -> rax = dst's terminating zero
url_enc PROC
ug_l:
    mov al, [rdx]
    test al, al
    jz ug_e
    inc rdx
    cmp al, '-'
    je ug_put
    cmp al, '_'
    je ug_put
    cmp al, '.'
    je ug_put
    cmp al, '~'
    je ug_put
    mov r8b, al
    sub r8b, '0'
    cmp r8b, 9
    jbe ug_put
    mov r8b, al
    or r8b, 20h
    sub r8b, 'a'
    cmp r8b, 25
    jbe ug_put
    mov byte ptr [rcx], '%'
    movzx r8d, al
    shr r8d, 4
    add r8b, '0'
    cmp r8b, '9'
    jbe ug_1
    add r8b, 7
ug_1:
    mov [rcx+1], r8b
    and al, 0Fh
    add al, '0'
    cmp al, '9'
    jbe ug_2
    add al, 7
ug_2:
    mov [rcx+2], al
    add rcx, 3
    jmp ug_l
ug_put:
    mov [rcx], al
    inc rcx
    jmp ug_l
ug_e:
    mov byte ptr [rcx], 0
    mov rax, rcx
    ret
url_enc ENDP

; rcx = key with its quotes -> rax = start of that key's value in r_buf, or 0
json_val PROC
    sub rsp, 28h
    mov rdx, rcx
    lea rcx, r_buf
    call strfind
    test rax, rax
    jz jv_ret
jv_ws:
    mov cl, [rax]
    cmp cl, ':'
    je jv_next
    cmp cl, ' '
    je jv_next
    cmp cl, 9
    je jv_next
    cmp cl, 13
    je jv_next
    cmp cl, 10
    jne jv_ret
jv_next:
    inc rax
    jmp jv_ws
jv_ret:
    add rsp, 28h
    ret
json_val ENDP

; rcx = key with its quotes, rdx = dst, r8d = dst size: copies that string value
; from r_buf -> eax = 1 if it was there and not empty
json_copy PROC
    push rbx
    push rsi
    sub rsp, 28h
    mov rbx, rdx
    mov esi, r8d
    mov byte ptr [rbx], 0
    call json_val
    test rax, rax
    jz jc_no
    cmp byte ptr [rax], 22h
    jne jc_no
    lea rcx, [rax+1]
    mov rdx, rbx
    mov r8d, esi
    call copy_jstr
    mov rcx, rbx
    call unescape
    cmp byte ptr [rbx], 0
    je jc_no
    mov eax, 1
    jmp jc_ret
jc_no:
    xor eax, eax
jc_ret:
    add rsp, 28h
    pop rsi
    pop rbx
    ret
json_copy ENDP

; rcx = key with its quotes, edx = default -> eax = that number from r_buf
json_num PROC
    push rbx
    sub rsp, 20h
    mov ebx, edx
    call json_val
    test rax, rax
    jz jn_def
    xor ecx, ecx
    xor r8d, r8d
jn_l:
    movzx edx, byte ptr [rax]
    sub edx, '0'
    cmp edx, 9
    ja jn_end
    cmp ecx, 100000000
    jae jn_end
    imul ecx, ecx, 10
    add ecx, edx
    inc r8d
    inc rax
    jmp jn_l
jn_end:
    test r8d, r8d
    jz jn_def
    mov ebx, ecx
jn_def:
    mov eax, ebx
    add rsp, 20h
    pop rbx
    ret
json_num ENDP

; rcx = server, rdx = address, r8 = GET or POST, r9 = body or 0; headers already in r_hdr
tw_call PROC
    sub rsp, 28h
    mov r_host, rcx
    mov r_path, rdx
    mov r_verb, r8
    mov r_body, r9
    mov r_port, TWITCH_PORT
    mov r_flags, TWITCH_FLAGS
    call http_req
    lea rcx, w_opath                ; everything else talks to Ouvert
    mov r_path, rcx
    add rsp, 28h
    ret
tw_call ENDP

; r_hdr = bearer token and Client ID, plus JSON type if ecx isn't 0
tw_authhdr PROC
    push rbx
    sub rsp, 20h
    mov ebx, ecx
    lea rcx, r_hdr
    lea rdx, s_hbearer
    call stpcpy
    mov rcx, rax
    lea rdx, r_twaccess
    call stpcpy
    mov rcx, rax
    lea rdx, s_hclient
    call stpcpy
    mov rcx, rax
    lea rdx, s_twclient
    call stpcpy
    test ebx, ebx
    jz ta_ret
    mov rcx, rax
    lea rdx, s_hjson
    call stpcpy
ta_ret:
    add rsp, 20h
    pop rbx
    ret
tw_authhdr ENDP

; Copies the sign-in from the settings
tw_load PROC
    sub rsp, 28h
    CS_ENTER
    lea rcx, r_twaccess
    lea rdx, g_twaccess
    call stpcpy
    lea rcx, r_twrefresh
    lea rdx, g_twrefresh
    call stpcpy
    lea rcx, r_twid
    lea rdx, g_twid
    call stpcpy
    lea rcx, r_twlogin
    lea rdx, g_twlogin
    call stpcpy
    lea rcx, r_chatcmd
    lea rdx, g_chatcmd
    call stpcpy
    CS_LEAVE
    add rsp, 28h
    ret
tw_load ENDP

; Stores the sign-in and tells the UI: ecx = new g_twstate, rdx = status text,
; r8d = 1 to also open the sign-in page. The UI saves the settings.
tw_store PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov ebx, ecx
    mov rsi, rdx
    mov edi, r8d
    CS_ENTER
    mov g_twstate, ebx
    lea rcx, g_twaccess
    lea rdx, r_twaccess
    call stpcpy
    lea rcx, g_twrefresh
    lea rdx, r_twrefresh
    call stpcpy
    lea rcx, g_twid
    lea rdx, r_twid
    call stpcpy
    lea rcx, g_twlogin
    lea rdx, r_twlogin
    call stpcpy
    lea rcx, g_twstat
    mov rdx, rsi
    call stpcpy
    CS_LEAVE
    mov rcx, g_hDlg
    mov edx, WM_APP_TWITCH
    mov r8d, edi
    xor r9d, r9d
    call [__imp_PostMessageA]
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
tw_store ENDP

tw_clear PROC
    mov byte ptr r_twaccess, 0
    mov byte ptr r_twrefresh, 0
    mov byte ptr r_twid, 0
    mov byte ptr r_twlogin, 0
    ret
tw_clear ENDP

; rcx = status text: back to signed out
tw_fail PROC
    push rbx
    sub rsp, 20h
    mov rbx, rcx
    call tw_clear
    xor ecx, ecx
    mov rdx, rbx
    xor r8d, r8d
    call tw_store
    add rsp, 20h
    pop rbx
    ret
tw_fail ENDP

; Sign in clicked: asks Twitch for a code, then opens the page to approve it
tw_start PROC
    sub rsp, 28h
    call tw_clear
    lea rcx, r_hdr
    lea rdx, s_hform
    call stpcpy
    lea rcx, r_form
    lea rdx, s_fclient
    call stpcpy
    mov rcx, rax
    lea rdx, s_twclient
    call url_enc
    mov rcx, rax
    lea rdx, s_fscopes
    call stpcpy
    lea rcx, w_twid
    lea rdx, w_pdevice
    lea r8, w_post
    lea r9, r_form
    call tw_call
    test eax, eax
    jz ts_fail
    cmp r_status, 200
    jne ts_fail
    lea rcx, s_jdevice
    lea rdx, r_devcode
    mov r8d, 256
    call json_copy
    test eax, eax
    jz ts_fail
    lea rcx, s_jucode
    lea rdx, r_usercode
    mov r8d, 64
    call json_copy
    test eax, eax
    jz ts_fail
    lea rcx, s_jverif
    lea rdx, r_verif
    mov r8d, 512
    call json_copy
    test eax, eax
    jz ts_fail
    lea rcx, s_jinterval
    mov edx, 5
    call json_num
    cmp eax, 5                      ; never faster than Twitch's documented 5 seconds
    jae ts_int
    mov eax, 5
ts_int:
    imul eax, eax, 1000
    mov r_interval, eax
    lea rcx, s_jexpires
    mov edx, 1800
    call json_num
    imul eax, eax, 1000
    mov r_twend, rax
    call [__imp_GetTickCount64]
    add r_twend, rax
    mov ecx, r_interval
    add rax, rcx
    mov r_twdue, rax
    lea rcx, r_nmsg
    lea rdx, s_twcode1
    call stpcpy
    mov rcx, rax
    lea rdx, r_usercode
    call stpcpy
    ; only ever open Twitch's own site
    lea rcx, r_verif
    lea rdx, s_twurl
    call strfind
    lea rcx, r_verif
    add rcx, 22
    xor r8d, r8d
    cmp rax, rcx
    jne ts_show
    mov r8d, 1
ts_show:
    mov ecx, 1
    lea rdx, r_nmsg
    call tw_store
    jmp ts_ret
ts_fail:
    lea rcx, s_twfail
    call tw_fail
ts_ret:
    add rsp, 28h
    ret
tw_start ENDP

; Fetches the signed-in account's ID and name -> eax = 1
tw_getuser PROC
    sub rsp, 28h
    xor ecx, ecx
    call tw_authhdr
    lea rcx, w_twapi
    lea rdx, w_pusers
    lea r8, w_get
    xor r9d, r9d
    call tw_call
    test eax, eax
    jz tu_no
    cmp r_status, 200
    jne tu_no
    lea rcx, s_jid
    lea rdx, r_twid
    mov r8d, 32
    call json_copy
    test eax, eax
    jz tu_no
    lea rcx, s_jlogin
    lea rdx, r_twlogin
    mov r8d, 64
    call json_copy
    test eax, eax
    jnz tu_ret
tu_no:
    xor eax, eax
tu_ret:
    add rsp, 28h
    ret
tw_getuser ENDP

; Asks Twitch whether the code has been approved yet
tw_poll PROC
    sub rsp, 28h
    call [__imp_GetTickCount64]
    cmp rax, r_twend
    jae tp_fail
    mov ecx, r_interval
    add rax, rcx
    mov r_twdue, rax
    lea rcx, r_hdr
    lea rdx, s_hform
    call stpcpy
    lea rcx, r_form
    lea rdx, s_fclient
    call stpcpy
    mov rcx, rax
    lea rdx, s_twclient
    call url_enc
    mov rcx, rax
    lea rdx, s_fscopes
    call stpcpy
    mov rcx, rax
    lea rdx, s_fdevice
    call stpcpy
    mov rcx, rax
    lea rdx, r_devcode
    call url_enc
    mov rcx, rax
    lea rdx, s_fgrant
    call stpcpy
    lea rcx, w_twid
    lea rdx, w_ptoken
    lea r8, w_post
    lea r9, r_form
    call tw_call
    test eax, eax
    jz tp_ret                       ; network trouble: try again next time
    cmp r_status, 200
    je tp_ok
    lea rcx, r_buf
    lea rdx, s_jpending
    call strfind
    test rax, rax
    jnz tp_ret                      ; not approved yet
    jmp tp_fail
tp_ok:
    lea rcx, s_jaccess
    lea rdx, r_twaccess
    mov r8d, 256
    call json_copy
    test eax, eax
    jz tp_fail
    lea rcx, s_jrefresh
    lea rdx, r_twrefresh
    mov r8d, 256
    call json_copy
    call tw_getuser
    test eax, eax
    jz tp_fail
    lea rcx, r_nmsg
    lea rdx, s_twas
    call stpcpy
    mov rcx, rax
    lea rdx, r_twlogin
    call stpcpy
    mov ecx, 2
    lea rdx, r_nmsg
    xor r8d, r8d
    call tw_store
    jmp tp_ret
tp_fail:
    lea rcx, s_twfail
    call tw_fail
tp_ret:
    add rsp, 28h
    ret
tw_poll ENDP

; Swaps the refresh token for a new access token -> eax = 1. The old refresh token
; only works once, so the new pair is saved straight away.
tw_refresh PROC
    sub rsp, 28h
    cmp byte ptr r_twrefresh, 0
    je tr_no
    lea rcx, r_hdr
    lea rdx, s_hform
    call stpcpy
    lea rcx, r_form
    lea rdx, s_frefresh
    call stpcpy
    mov rcx, rax
    lea rdx, r_twrefresh
    call url_enc
    mov rcx, rax
    lea rdx, s_fclient2
    call stpcpy
    mov rcx, rax
    lea rdx, s_twclient
    call url_enc
    lea rcx, w_twid
    lea rdx, w_ptoken
    lea r8, w_post
    lea r9, r_form
    call tw_call
    test eax, eax
    jz tr_no
    cmp r_status, 200
    jne tr_no
    lea rcx, s_jaccess
    lea rdx, r_twaccess
    mov r8d, 256
    call json_copy
    test eax, eax
    jz tr_no
    lea rcx, s_jrefresh
    lea rdx, r_twrefresh
    mov r8d, 256
    call json_copy
    lea rcx, r_nmsg
    lea rdx, s_twas
    call stpcpy
    mov rcx, rax
    lea rdx, r_twlogin
    call stpcpy
    mov ecx, 2
    lea rdx, r_nmsg
    xor r8d, r8d
    call tw_store
    mov eax, 1
    jmp tr_ret
tr_no:
    xor eax, eax
tr_ret:
    add rsp, 28h
    ret
tw_refresh ENDP

; Posts the command once -> eax = 0 if the request itself failed
tw_post_chat PROC
    sub rsp, 28h
    mov ecx, 1
    call tw_authhdr
    lea rcx, r_form
    lea rdx, s_cbroad
    call stpcpy
    mov rcx, rax
    lea rdx, r_twid
    call stpcpy
    mov rcx, rax
    lea rdx, s_csender
    call stpcpy
    mov rcx, rax
    lea rdx, r_twid
    call stpcpy
    mov rcx, rax
    lea rdx, s_cmessage
    call stpcpy
    mov rcx, rax
    lea rdx, r_chatcmd
    call json_escape
    mov rcx, rax
    lea rdx, s_cend
    call stpcpy
    lea rcx, w_twapi
    lea rdx, w_pchat
    lea r8, w_post
    lea r9, r_form
    call tw_call
    add rsp, 28h
    ret
tw_post_chat ENDP

; Sends the Next song command to chat; the result goes in r_nmsg
tw_chat PROC
    sub rsp, 28h
    cmp byte ptr r_chatcmd, 0
    jne tc_go
    lea rcx, r_nmsg
    lea rdx, s_twnocmd
    call stpcpy
    jmp tc_ret
tc_go:
    call tw_post_chat
    test eax, eax
    jz tc_net
    cmp r_status, 401               ; access tokens last about 4 hours
    jne tc_check
    call tw_refresh
    test eax, eax
    jnz tc_again
    lea rcx, s_twexpired
    call tw_fail
    lea rcx, r_nmsg
    lea rdx, s_twexpired
    call stpcpy
    jmp tc_ret
tc_again:
    call tw_post_chat
    test eax, eax
    jz tc_net
tc_check:
    cmp r_status, 200
    jne tc_err
    lea rcx, s_jsent
    call json_val
    test rax, rax
    jz tc_err
    cmp byte ptr [rax], 't'         ; true
    jne tc_err
    mov r_chatsent, 1
    lea rcx, r_nmsg
    lea rdx, s_twsent1
    call stpcpy
    mov rcx, rax
    lea rdx, r_chatcmd
    call stpcpy
    mov rcx, rax
    lea rdx, s_twsent2
    call stpcpy
    jmp tc_ret
tc_err:
    lea rcx, s_jmessage             ; Twitch's reason, including dropped messages
    lea rdx, r_nmsg
    mov r8d, 512
    call json_copy
    test eax, eax
    jnz tc_ret
    mov eax, r_status
    mov r_err, eax
tc_net:
    lea rcx, r_nmsg
    lea rdx, s_twsenderr
    call stpcpy
    mov ecx, r_err
    mov rdx, rax
    call utoa
    mov rcx, rax
    lea rdx, s_rparen
    call stpcpy
tc_ret:
    add rsp, 28h
    ret
tw_chat ENDP

; Sign out clicked: tells Twitch to cancel the token, then forgets it
tw_signout PROC
    sub rsp, 28h
    call tw_load
    cmp byte ptr r_twaccess, 0
    je to_done
    lea rcx, r_hdr
    lea rdx, s_hform
    call stpcpy
    lea rcx, r_form
    lea rdx, s_fclient
    call stpcpy
    mov rcx, rax
    lea rdx, s_twclient
    call url_enc
    mov rcx, rax
    lea rdx, s_ftoken
    call stpcpy
    mov rcx, rax
    lea rdx, r_twaccess
    call url_enc
    lea rcx, w_twid
    lea rdx, w_prevoke
    lea r8, w_post
    lea r9, r_form
    call tw_call
to_done:
    lea rcx, s_twoff
    call tw_fail
    add rsp, 28h
    ret
tw_signout ENDP

; Next song was clicked: asks Ouvert once, with the private key, and never retries,
; since the request may have worked even if the answer got lost. Always reports
; back, which re-enables the button.
req_next PROC
    sub rsp, 28h
    mov r_chatsent, 0
    call tw_load
    cmp byte ptr r_twaccess, 0      ; signed in to Twitch: use the bot's chat command,
    je rn2_api                      ; so the bot announces the song
    call tw_chat
    jmp rn2_done
rn2_api:
    CS_ENTER
    lea rcx, r_key
    lea rdx, g_ouvertp
    call stpcpy
    CS_LEAVE
    cmp byte ptr r_key, 0
    jne rn2_go
    lea rcx, r_nmsg
    lea rdx, s_nnokey
    call stpcpy
    jmp rn2_done
rn2_go:
    lea rax, w_onext
    mov r_path, rax
    call req_fetch
    lea rcx, w_opath
    mov r_path, rcx
    test eax, eax
    jnz rn2_got
    lea rcx, r_nmsg
    lea rdx, s_rneterr
    call stpcpy
    mov ecx, r_err
    mov rdx, rax
    call utoa
    mov rcx, rax
    lea rdx, s_rparen
    call stpcpy
    jmp rn2_done
rn2_got:
    mov byte ptr r_nmsg, 0
    lea rcx, r_buf
    lea rdx, s_rmsg
    call strfind
    test rax, rax
    jz rn2_nomsg
    mov rcx, rax
    lea rdx, r_nmsg
    mov r8d, 512
    call copy_jstr
    lea rcx, r_nmsg
    call unescape
    cmp byte ptr r_nmsg, 0
    jne rn2_done
rn2_nomsg:
    lea rcx, r_buf
    lea rdx, s_rstatus
    call strfind
    lea rdx, s_nok
    test rax, rax
    jnz rn2_set
    lea rdx, s_nbad
rn2_set:
    lea rcx, r_nmsg
    call stpcpy
rn2_done:
    CS_ENTER
    lea rcx, g_nextmsg
    lea rdx, r_nmsg
    call stpcpy
    CS_LEAVE
    mov rcx, g_hDlg
    mov edx, WM_APP_NEXTDONE
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_PostMessageA]
    cmp r_chatsent, 0               ; give the bot a moment before refreshing the queue
    je rn2_ret
    mov ecx, 1500
    call [__imp_Sleep]
rn2_ret:
    add rsp, 28h
    ret
req_next ENDP

; Thread: only contacts Ouvert while the Requests page is on screen
req_thread PROC
    sub rsp, 28h
    lea rax, w_opath
    mov r_path, rax
rt_loop:
    mov rcx, g_hReqEvent
    mov edx, REQ_POLL_MS
    call [__imp_WaitForSingleObject]
    xor eax, eax
    xchg eax, g_twaction
    cmp eax, 1
    jne rt_a2
    call tw_start
    jmp rt_tw
rt_a2:
    cmp eax, 2
    jne rt_a3
    call tw_signout
    jmp rt_tw
rt_a3:
    cmp eax, 3
    jne rt_tw
    lea rcx, s_twoff
    call tw_fail
rt_tw:
    cmp g_twstate, 1                ; waiting for the code to be approved
    jne rt_next
    call [__imp_GetTickCount64]
    cmp rax, r_twdue
    jb rt_next
    call tw_poll
rt_next:
    xor eax, eax
    xchg eax, g_reqnext
    test eax, eax
    jz rt_page
    call req_next
rt_page:
    cmp g_page, PAGE_REQUESTS
    jne rt_loop
    mov rcx, g_hDlg
    call [__imp_IsWindowVisible]
    test eax, eax
    jz rt_loop
    mov rcx, g_hDlg
    call [__imp_IsIconic]           ; minimized to the taskbar
    test eax, eax
    jnz rt_loop
    CS_ENTER
    lea rcx, r_key
    lea rdx, g_ouvert
    call stpcpy
    CS_LEAVE
    cmp byte ptr r_key, 0
    jne rt_fetch
    lea rcx, r_list
    lea rdx, s_rnokey
    call stpcpy
    jmp rt_pub
rt_fetch:
    call req_fetch
    test eax, eax
    jnz rt_parse
    lea rcx, r_list
    lea rdx, s_rneterr
    call stpcpy
    mov ecx, r_err
    mov rdx, rax
    call utoa
    mov rcx, rax
    lea rdx, s_rretry
    call stpcpy
    jmp rt_pub
rt_parse:
    call req_parse
    test eax, eax
    jnz rt_pub
    lea rcx, r_list
    lea rdx, s_rbad
    call stpcpy
rt_pub:
    call req_publish
    jmp rt_loop
req_thread ENDP

; ---- UI thread -------------------------------------------------------------------

; ecx = control id, rdx = UTF-8 text
set_text_u8 PROC
    push rbx
    sub rsp, 30h
    mov ebx, ecx
    mov r8, rdx
    mov ecx, 65001
    xor edx, edx
    mov r9d, -1
    lea rax, g_wtmp
    mov [rsp+20h], rax
    mov qword ptr [rsp+28h], 1024
    call [__imp_MultiByteToWideChar]
    mov rcx, g_hDlg
    mov edx, ebx
    lea r8, g_wtmp
    call [__imp_SetDlgItemTextW]
    add rsp, 30h
    pop rbx
    ret
set_text_u8 ENDP

; ecx = control id, rdx = dst, r8d = dst size: read the control's text as UTF-8
get_text_u8 PROC
    push rbx
    push rsi
    sub rsp, 48h
    mov rbx, rdx
    mov esi, r8d
    mov edx, ecx
    mov rcx, g_hDlg
    lea r8, g_wtmp
    mov r9d, 1024
    call [__imp_GetDlgItemTextW]
    mov ecx, 65001
    xor edx, edx
    lea r8, g_wtmp
    mov r9d, -1
    mov [rsp+20h], rbx
    mov [rsp+28h], rsi
    and qword ptr [rsp+30h], 0
    and qword ptr [rsp+38h], 0
    call [__imp_WideCharToMultiByte]
    mov byte ptr [rbx+rsi-1], 0     ; terminated even if it was cut short
    mov rcx, rbx
    call trim
    add rsp, 48h
    pop rsi
    pop rbx
    ret
get_text_u8 ENDP

; ecx = control id, edx = message, r8 = wParam, r9 = lParam -> rax = result
send_dlg PROC
    sub rsp, 38h
    mov [rsp+20h], r9
    mov r9, r8
    mov r8d, edx
    mov edx, ecx
    mov rcx, g_hDlg
    call [__imp_SendDlgItemMessageW]
    add rsp, 38h
    ret
send_dlg ENDP

; ecx = control id, edx = message (CB_ADDSTRING, LB_ADDSTRING), r8 = UTF-8 text
add_string PROC
    push rbx
    push rsi
    sub rsp, 38h
    mov ebx, ecx
    mov esi, edx
    mov ecx, 65001
    xor edx, edx
    mov r9d, -1
    lea rax, g_wtmp
    mov [rsp+20h], rax
    mov qword ptr [rsp+28h], 1024
    call [__imp_MultiByteToWideChar]
    mov ecx, ebx
    mov edx, esi
    xor r8d, r8d
    lea r9, g_wtmp
    call send_dlg
    add rsp, 38h
    pop rsi
    pop rbx
    ret
add_string ENDP

; rcx = name -> eax = its index in g_scenes, or -1 (call with g_cs held)
scene_index PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov rdi, rcx
    xor ebx, ebx
    lea rsi, g_scenes
    cmp byte ptr [rdi], 0
    je sx_no
sx_l:
    cmp ebx, g_nscenes
    jae sx_no
    mov rcx, rdi
    mov rdx, [rsi+rbx*8]
    call streq
    test eax, eax
    jnz sx_yes
    inc ebx
    jmp sx_l
sx_yes:
    mov eax, ebx
    jmp sx_ret
sx_no:
    mov eax, -1
sx_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
scene_index ENDP

request_connect PROC
    sub rsp, 28h
    mov g_want, 1
    mov g_reconnect, 1
    mov rcx, g_hEvent
    call [__imp_SetEvent]
    add rsp, 28h
    ret
request_connect ENDP

; ecx = NIM_ADD (0) or NIM_DELETE (2)
tray_icon PROC
    sub rsp, 28h
    lea rdx, g_nid
    call [__imp_Shell_NotifyIconA]
    add rsp, 28h
    ret
tray_icon ENDP

; rcx = scene buffer: empty it if that scene isn't in OBS -> eax = 1 if emptied
; (call with g_cs held)
drop_missing PROC
    push rbx
    sub rsp, 20h
    mov rbx, rcx
    call scene_index
    cmp eax, -1
    jne dm_keep
    cmp byte ptr [rbx], 0
    je dm_keep
    mov byte ptr [rbx], 0
    mov eax, 1
    jmp dm_ret
dm_keep:
    xor eax, eax
dm_ret:
    add rsp, 20h
    pop rbx
    ret
drop_missing ENDP

; Select the viewed mode's scenes in the dropdowns (call with g_cs held)
select_scenes PROC
    push rbx
    sub rsp, 20h
    call view_bufs
    mov rbx, rdx
    mov rcx, rax
    call scene_index
    movsxd r8, eax                  ; -1 clears the selection
    mov ecx, IDC_SONG
    mov edx, 14Eh                   ; CB_SETCURSEL
    xor r9d, r9d
    call send_dlg
    mov rcx, rbx
    call scene_index
    inc eax                         ; "(none)" is item 0; missing -> 0 too
    mov r8d, eax
    mov ecx, IDC_MENU
    mov edx, 14Eh
    xor r9d, r9d
    call send_dlg
    add rsp, 20h
    pop rbx
    ret
select_scenes ENDP

; Shows the connection text (Connection page) and the status row: the dot,
; recolored by WM_CTLCOLORSTATIC, and the latest event or connection state
update_status PROC
    sub rsp, 28h
    CS_ENTER
    mov ecx, IDC_CONN
    lea rdx, g_stat_conn
    call set_text_u8
    mov eax, g_connstate
    lea rdx, s_notconn
    cmp eax, 1
    jne us_2
    lea rdx, s_connecting
us_2:
    cmp eax, 3
    jne us_3
    lea rdx, s_cantconn
us_3:
    cmp eax, 2
    jne us_set
    lea rdx, s_connectd
    cmp byte ptr g_stat_event, 0
    je us_set
    lea rdx, g_stat_event
us_set:
    mov ecx, IDC_STATUS
    call set_text_u8
    CS_LEAVE
    mov ecx, IDC_DOT
    lea rdx, s_dot
    call set_text_u8
    add rsp, 28h
    ret
update_status ENDP

; Shows the lines in g_reqtext on the Requests page
req_show PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 28h
    xor r12d, r12d                  ; longest line
    mov ecx, IDC_REQLIST
    mov edx, 18Eh                   ; LB_GETTOPINDEX
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    mov rbx, rax
    CS_ENTER
    mov ecx, IDC_REQLIST
    mov edx, 184h                   ; LB_RESETCONTENT
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    lea rsi, g_reqtext
rs_line:
    cmp byte ptr [rsi], 0
    je rs_done
    lea rdi, g_uitmp2
rs_c:
    mov al, [rsi]
    test al, al
    jz rs_add
    inc rsi
    cmp al, 0Ah
    je rs_add
    mov [rdi], al
    inc rdi
    jmp rs_c
rs_add:
    mov byte ptr [rdi], 0
    lea rax, g_uitmp2
    sub rdi, rax
    cmp rdi, r12
    jbe rs_add2
    mov r12, rdi
rs_add2:
    mov ecx, IDC_REQLIST
    mov edx, 180h                   ; LB_ADDSTRING
    lea r8, g_uitmp2
    call add_string
    jmp rs_line
rs_done:
    CS_LEAVE
    ; scrollbar for long lines: an average character is 4 dialog units wide
    and qword ptr g_rc, 0
    and qword ptr g_rc+8, 0
    lea eax, [r12*4+8]
    mov dword ptr g_rc+8, eax
    mov rcx, g_hDlg
    lea rdx, g_rc
    call [__imp_MapDialogRect]
    mov ecx, IDC_REQLIST
    mov edx, 194h                   ; LB_SETHORIZONTALEXTENT
    mov r8d, dword ptr g_rc+8
    xor r9d, r9d
    call send_dlg
    mov ecx, IDC_REQLIST
    mov edx, 197h                   ; LB_SETTOPINDEX
    mov r8, rbx
    xor r9d, r9d
    call send_dlg
    add rsp, 28h
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
req_show ENDP

; Records the layout from chss.rc, which resizing is measured against
layout_init PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov rcx, g_hDlg
    lea rdx, g_rc
    call [__imp_GetClientRect]
    mov eax, dword ptr g_rc+8
    mov g_cw0, eax
    mov eax, dword ptr g_rc+12
    mov g_ch0, eax
    mov rcx, g_hDlg
    lea rdx, g_rc
    call [__imp_GetWindowRect]
    mov eax, dword ptr g_rc+8
    sub eax, dword ptr g_rc
    mov g_minw, eax
    mov eax, dword ptr g_rc+12
    sub eax, dword ptr g_rc+4
    mov g_minh, eax
    lea rsi, layout_tbl
    lea rdi, g_lay
li_l:
    movzx edx, word ptr [rsi]
    test edx, edx
    jz li_done
    mov rcx, g_hDlg
    call [__imp_GetDlgItem]
    mov [rdi], rax
    mov rcx, rax
    lea rdx, g_rc
    call [__imp_GetWindowRect]
    xor ecx, ecx                    ; from the screen...
    mov rdx, g_hDlg                 ; ...to the window
    lea r8, g_rc
    mov r9d, 2
    call [__imp_MapWindowPoints]
    mov eax, dword ptr g_rc
    mov [rdi+8], eax
    mov ecx, dword ptr g_rc+4
    mov [rdi+12], ecx
    mov edx, dword ptr g_rc+8
    sub edx, eax
    mov [rdi+16], edx
    mov edx, dword ptr g_rc+12
    sub edx, ecx
    mov [rdi+20], edx
    add rsi, 4
    add rdi, 32
    jmp li_l
li_done:
    mov g_laydone, 1
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
layout_init ENDP

; ecx = client width, edx = client height: moves the controls to fit
layout_apply PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 30h
    mov r12d, ecx
    sub r12d, g_cw0
    mov r13d, edx
    sub r13d, g_ch0
    lea rsi, layout_tbl
    lea rdi, g_lay
la_l:
    movzx ebx, word ptr [rsi+2]
    cmp word ptr [rsi], 0
    je la_done
    mov rcx, [rdi]
    mov edx, [rdi+8]
    mov r8d, [rdi+12]
    mov r9d, [rdi+16]
    mov eax, [rdi+20]
    test ebx, 1
    jz la_1
    add edx, r12d
la_1:
    test ebx, 2
    jz la_2
    add r8d, r13d
la_2:
    test ebx, 4
    jz la_3
    add r9d, r12d
la_3:
    test ebx, 8
    jz la_4
    add eax, r13d
la_4:
    mov [rsp+20h], rax
    mov qword ptr [rsp+28h], 1      ; repaint
    call [__imp_MoveWindow]
    add rsi, 4
    add rdi, 32
    jmp la_l
la_done:
    add rsp, 30h
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
layout_apply ENDP

; Shows the Twitch status and the matching button label
tw_ui PROC
    sub rsp, 28h
    CS_ENTER
    mov ecx, IDC_TWSTAT
    lea rdx, g_twstat
    call set_text_u8
    lea r8, s_twbsignin
    mov eax, g_twstate
    cmp eax, 1
    jne tu2_a
    lea r8, s_twbcancel
tu2_a:
    cmp eax, 2
    jne tu2_b
    lea r8, s_twbsignout
tu2_b:
    mov rcx, g_hDlg
    mov edx, IDC_TWBTN
    call [__imp_SetDlgItemTextA]
    CS_LEAVE
    mov rcx, g_hDlg
    mov edx, IDC_TWBTN
    call [__imp_GetDlgItem]
    mov rcx, rax
    mov edx, 1
    call [__imp_EnableWindow]
    add rsp, 28h
    ret
tw_ui ENDP

; Puts the window on top of other windows, or back among them, per g_ontop
apply_ontop PROC
    sub rsp, 48h
    mov rcx, g_hDlg
    mov rdx, -2                     ; HWND_NOTOPMOST
    cmp byte ptr g_ontop, '1'
    jne ao_set
    mov rdx, -1                     ; HWND_TOPMOST
ao_set:
    xor r8d, r8d
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    and qword ptr [rsp+28h], 0
    mov qword ptr [rsp+30h], 13h    ; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    call [__imp_SetWindowPos]
    add rsp, 48h
    ret
apply_ontop ENDP

; ecx = signed value, rdx = dst -> rax = dst's terminating zero
itoa_s PROC
    test ecx, ecx
    jns is_pos
    mov byte ptr [rdx], '-'
    inc rdx
    neg ecx
is_pos:
    mov ecx, ecx
    jmp utoa
itoa_s ENDP

; rcx = text: reads a signed number and the comma after it -> eax = value,
; rcx moved past them, r8d = digits read (leaf)
atoi_s PROC
    xor eax, eax
    xor r8d, r8d
    xor r9d, r9d                    ; negative
    cmp byte ptr [rcx], '-'
    jne as_l
    inc r9d
    inc rcx
as_l:
    movzx edx, byte ptr [rcx]
    sub edx, '0'
    cmp edx, 9
    ja as_end
    cmp r8d, 7                      ; far beyond any screen
    jae as_end
    imul eax, eax, 10
    add eax, edx
    inc r8d
    inc rcx
    jmp as_l
as_end:
    test r9d, r9d
    jz as_com
    neg eax
as_com:
    cmp byte ptr [rcx], ','
    jne as_ret
    inc rcx
as_ret:
    ret
atoi_s ENDP

; Records the window's normal position and size, and whether it's maximized, in g_winpos
win_capture PROC
    push rbx
    sub rsp, 20h
    mov dword ptr g_pl, 44
    mov rcx, g_hDlg
    lea rdx, g_pl
    call [__imp_GetWindowPlacement]
    test eax, eax
    jz wc2_ret
    lea rbx, g_winpos
    mov ecx, dword ptr g_pl+28      ; rcNormalPosition.left
    mov rdx, rbx
    call itoa_s
    mov byte ptr [rax], ','
    lea rbx, [rax+1]
    mov ecx, dword ptr g_pl+32      ; .top
    mov rdx, rbx
    call itoa_s
    mov byte ptr [rax], ','
    lea rbx, [rax+1]
    mov ecx, dword ptr g_pl+36      ; .right
    sub ecx, dword ptr g_pl+28
    mov rdx, rbx
    call itoa_s
    mov byte ptr [rax], ','
    lea rbx, [rax+1]
    mov ecx, dword ptr g_pl+40      ; .bottom
    sub ecx, dword ptr g_pl+32
    mov rdx, rbx
    call itoa_s
    mov byte ptr [rax], ','
    xor ecx, ecx
    cmp dword ptr g_pl+8, 3         ; SW_SHOWMAXIMIZED
    sete cl
    add cl, '0'
    mov [rax+1], cl
    mov byte ptr [rax+2], 0
wc2_ret:
    add rsp, 20h
    pop rbx
    ret
win_capture ENDP

; Puts the window where g_winpos says, if it holds five numbers. Windows pulls it back
; on screen if that place no longer exists, e.g. after unplugging a monitor.
win_restore PROC
    sub rsp, 28h
    lea rcx, g_winpos
    call atoi_s
    test r8d, r8d
    jz wr_ret
    mov dword ptr g_pl+28, eax
    call atoi_s
    test r8d, r8d
    jz wr_ret
    mov dword ptr g_pl+32, eax
    call atoi_s
    test r8d, r8d
    jz wr_ret
    cmp eax, g_minw                 ; never smaller than the layout needs
    jge wr_w
    mov eax, g_minw
wr_w:
    add eax, dword ptr g_pl+28
    mov dword ptr g_pl+36, eax
    call atoi_s
    test r8d, r8d
    jz wr_ret
    cmp eax, g_minh
    jge wr_h
    mov eax, g_minh
wr_h:
    add eax, dword ptr g_pl+32
    mov dword ptr g_pl+40, eax
    call atoi_s
    test r8d, r8d
    jz wr_ret
    mov edx, 1                      ; SW_SHOWNORMAL
    cmp eax, 1
    jne wr_set
    mov edx, 3                      ; SW_SHOWMAXIMIZED
wr_set:
    mov dword ptr g_pl, 44
    and dword ptr g_pl+4, 0
    mov dword ptr g_pl+8, edx
    mov dword ptr g_pl+12, -1       ; ptMinPosition, ptMaxPosition: default
    mov dword ptr g_pl+16, -1
    mov dword ptr g_pl+20, -1
    mov dword ptr g_pl+24, -1
    mov rcx, g_hDlg
    lea rdx, g_pl
    call [__imp_SetWindowPlacement]
wr_ret:
    add rsp, 28h
    ret
win_restore ENDP

; Fill the page list
refresh_nav PROC
    push rbx
    sub rsp, 20h
    mov ecx, IDC_NAV
    mov edx, 184h                   ; LB_RESETCONTENT
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    mov ecx, IDC_NAV
    mov edx, 180h                   ; LB_ADDSTRING
    lea r8, s_navreq
    call add_string
    mov ecx, IDC_NAV
    mov edx, 180h
    lea r8, s_sp
    call add_string
    mov ecx, IDC_NAV
    mov edx, 180h
    lea r8, s_mp
    call add_string
    mov ecx, IDC_NAV
    mov edx, 180h
    lea r8, s_navset
    call add_string
    mov ecx, IDC_NAV
    mov edx, 186h                   ; LB_SETCURSEL
    mov r8d, g_page
    xor r9d, r9d
    call send_dlg
    add rsp, 20h
    pop rbx
    ret
refresh_nav ENDP

; Show the controls of page g_page and hide the rest
show_page PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov ecx, g_page
    mov edi, 1
    shl edi, cl
    test edi, 6                     ; a mode page: "Use this mode" or "This mode is active"
    jz sp_go
    mov eax, g_view
    cmp eax, g_mode
    mov eax, 80h
    jne sp_btn
    mov eax, 40h
sp_btn:
    or edi, eax
sp_go:
    lea rsi, page_tbl
sp_l:
    movzx edx, word ptr [rsi]
    test edx, edx
    jz sp_ret
    mov rcx, g_hDlg
    call [__imp_GetDlgItem]
    xor edx, edx                    ; SW_HIDE
    test di, word ptr [rsi+2]
    jz sp_show
    mov edx, 5                      ; SW_SHOW
sp_show:
    mov rcx, rax
    call [__imp_ShowWindow]
    add rsi, 4
    jmp sp_l
sp_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
show_page ENDP

; Fill both scene dropdowns from g_scenes and select the saved scenes
fill_scenes PROC
    push rbx
    push rsi
    sub rsp, 28h
    xor esi, esi                    ; 1 = a saved scene is missing
    CS_ENTER
    mov ecx, IDC_SONG
    mov edx, 14Bh                   ; CB_RESETCONTENT
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    mov ecx, IDC_MENU
    mov edx, 14Bh
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    mov ecx, IDC_MENU
    mov edx, 143h                   ; CB_ADDSTRING
    lea r8, s_noneitem
    call add_string
    xor ebx, ebx
fc_l:
    cmp ebx, g_nscenes
    jae fc_sel
    lea rax, g_scenes
    mov r8, [rax+rbx*8]
    mov ecx, IDC_SONG
    mov edx, 143h
    call add_string
    lea rax, g_scenes
    mov r8, [rax+rbx*8]
    mov ecx, IDC_MENU
    mov edx, 143h
    call add_string
    inc ebx
    jmp fc_l
fc_sel:
    ; forget saved scenes that are no longer in OBS
    lea rcx, g_song
    call drop_missing
    or esi, eax
    lea rcx, g_menu
    call drop_missing
    or esi, eax
    lea rcx, g_mpsong
    call drop_missing
    or esi, eax
    lea rcx, g_mpmenu
    call drop_missing
    or esi, eax
    call select_scenes
    CS_LEAVE
    test esi, esi
    jz fc_ret
    CS_ENTER
    lea rcx, g_stat_event
    lea rdx, ev_missing
    call stpcpy
    CS_LEAVE
fc_ret:
    call update_status
    add rsp, 28h
    pop rsi
    pop rbx
    ret
fill_scenes ENDP

; Dialog procedure: rcx = hwnd, edx = message, r8 = wParam, r9 = lParam
DlgProc PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 48h
    mov rbx, rcx
    mov rsi, r8
    mov rdi, r9
    cmp edx, 110h                   ; WM_INITDIALOG
    je dp_init
    cmp edx, 111h                   ; WM_COMMAND
    je dp_cmd
    cmp edx, 112h                   ; WM_SYSCOMMAND
    je dp_syscmd
    cmp edx, 10h                    ; WM_CLOSE
    je dp_close
    cmp edx, WM_APP_STATUS
    je dp_status
    cmp edx, WM_APP_SCENES
    je dp_scenes
    cmp edx, WM_APP_TRAY
    je dp_tray
    cmp edx, WM_APP_REQS
    je dp_reqs
    cmp edx, 232h                   ; WM_EXITSIZEMOVE
    je dp_moved
    cmp edx, WM_APP_NEXTDONE
    je dp_nextdone
    cmp edx, WM_APP_TWITCH
    je dp_twitch
    cmp edx, 5                      ; WM_SIZE
    je dp_size
    cmp edx, 24h                    ; WM_GETMINMAXINFO
    je dp_minmax
    cmp edx, 138h                   ; WM_CTLCOLORSTATIC
    je dp_ctlstatic
    cmp edx, 136h                   ; WM_CTLCOLORDLG
    je dp_bg
    cmp edx, 135h                   ; WM_CTLCOLORBTN
    je dp_bg
    cmp edx, 133h                   ; WM_CTLCOLOREDIT
    je dp_ctledit
    cmp edx, 134h                   ; WM_CTLCOLORLISTBOX
    je dp_ctllist
    cmp edx, 2Bh                    ; WM_DRAWITEM
    je dp_drawitem
    cmp edx, 2Ch                    ; WM_MEASUREITEM
    je dp_measure
dp_false:
    xor eax, eax
    jmp dp_ret
dp_true:
    mov eax, 1
dp_ret:
    add rsp, 48h
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

dp_init:
    mov g_hDlg, rbx
    ; dark title bar and dark text boxes, dropdowns and buttons
    mov rcx, rbx
    mov edx, 20                     ; DWMWA_USE_IMMERSIVE_DARK_MODE
    lea r8, g_one
    mov r9d, 4
    call [__imp_DwmSetWindowAttribute]
    lea r12, theme_tbl
di_theme:
    movzx edx, word ptr [r12]
    test edx, edx
    jz di_themed
    mov rcx, rbx
    call [__imp_GetDlgItem]
    mov rcx, rax
    lea rdx, w_darkcfd
    cmp word ptr [r12+2], 0
    je di_settheme
    lea rdx, w_darkexp
di_settheme:
    xor r8d, r8d
    call [__imp_SetWindowTheme]
    add r12, 4
    jmp di_theme
di_themed:
    mov ecx, IDC_HOST
    lea rdx, g_host
    call set_text_u8
    mov ecx, IDC_PORT
    lea rdx, g_port
    call set_text_u8
    mov ecx, IDC_PASS
    lea rdx, g_pass
    call set_text_u8
    mov ecx, IDC_OUVERT
    lea rdx, g_ouvert
    call set_text_u8
    mov ecx, IDC_OUVERTP
    lea rdx, g_ouvertp
    call set_text_u8
    mov ecx, IDC_CHATCMD
    lea rdx, g_chatcmd
    call set_text_u8
    lea rcx, g_twstat
    lea rdx, s_twoff
    cmp byte ptr g_twaccess, 0
    je di_twoff
    mov g_twstate, 2
    lea rdx, s_twas
    call stpcpy
    mov rcx, rax
    lea rdx, g_twlogin
di_twoff:
    call stpcpy
    call tw_ui
    mov rcx, rbx
    mov edx, IDC_DELAY
    lea r8, g_delay
    call [__imp_SetDlgItemTextA]
    mov rcx, rbx
    mov edx, IDC_FILE
    lea r8, g_file
    call [__imp_SetDlgItemTextA]
    ; start on the active mode's page, or on Connection the first time
    mov eax, g_mode
    mov g_view, eax
    inc eax
    cmp byte ptr g_song, 0
    jne di_page
    cmp byte ptr g_mpsong, 0
    jne di_page
    mov eax, PAGE_SETTINGS
di_page:
    mov g_page, eax
    call refresh_nav
    call show_page
    call layout_init
    call win_restore
    xor r8d, r8d
    cmp byte ptr g_tray, '1'
    sete r8b
    mov ecx, IDC_TRAY
    mov edx, 0F1h                   ; BM_SETCHECK
    xor r9d, r9d
    call send_dlg
    xor r8d, r8d
    cmp byte ptr g_ontop, '1'
    sete r8b
    mov ecx, IDC_ONTOP
    mov edx, 0F1h                   ; BM_SETCHECK
    xor r9d, r9d
    call send_dlg
    call apply_ontop
    ; tray icon
    mov dword ptr g_nid, 528
    mov qword ptr g_nid+8, rbx
    mov dword ptr g_nid+16, 1
    mov dword ptr g_nid+20, 7       ; NIF_MESSAGE | NIF_ICON | NIF_TIP
    mov dword ptr g_nid+24, WM_APP_TRAY
    xor ecx, ecx
    mov edx, 32512                  ; IDI_APPLICATION
    call [__imp_LoadIconA]
    mov qword ptr g_nid+32, rax
    lea rcx, g_nid+40
    lea rdx, s_title
    call stpcpy
    cmp byte ptr g_tray, '1'
    jne di_notray
    xor ecx, ecx                    ; NIM_ADD
    call tray_icon
di_notray:
    ; worker thread
    xor ecx, ecx
    xor edx, edx
    lea r8, worker
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    and qword ptr [rsp+28h], 0
    call [__imp_CreateThread]
    mov rcx, rax
    call [__imp_CloseHandle]
    xor ecx, ecx
    xor edx, edx
    lea r8, req_thread
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    and qword ptr [rsp+28h], 0
    call [__imp_CreateThread]
    mov rcx, rax
    call [__imp_CloseHandle]
    ; saved settings: connect straight away
    cmp byte ptr g_song, 0
    jne di_auto
    cmp byte ptr g_mpsong, 0
    je di_new
di_auto:
    call update_status
    call request_connect
    jmp dp_true
di_new:
    lea rcx, g_stat_conn
    lea rdx, st_enter
    call stpcpy
    call update_status
    jmp dp_true

dp_cmd:
    movzx eax, si                   ; control id
    mov r12d, esi
    shr r12d, 16                    ; notification code
    cmp eax, IDC_CONNECT
    je dc_connect
    cmp eax, IDC_SONG
    je dc_song
    cmp eax, IDC_MENU
    je dc_menu
    cmp eax, IDC_DELAY
    je dc_delay
    cmp eax, IDC_FILE
    je dc_file
    cmp eax, IDC_BROWSE
    je dc_browse
    cmp eax, IDC_NAV
    je dc_nav
    cmp eax, IDC_USEMODE
    je dc_usemode
    cmp eax, IDC_OUVERT
    je dc_ouvert
    cmp eax, IDC_OUVERTP
    je dc_ouvertp
    cmp eax, IDC_NEXT
    je dc_next
    cmp eax, IDC_TWBTN
    je dc_twbtn
    cmp eax, IDC_CHATCMD
    je dc_chatcmd
    cmp eax, IDC_ONTOP
    je dc_ontop
    cmp eax, IDC_TRAY
    je dc_tray
    jmp dp_true                     ; swallow Enter/Esc (IDOK/IDCANCEL)

dc_ouvert:
    cmp r12d, 300h                  ; EN_CHANGE
    jne dp_true
    CS_ENTER
    mov ecx, IDC_OUVERT
    lea rdx, g_ouvert
    mov r8d, 128
    call get_text_u8
    jmp dc_unlock

dc_ouvertp:
    cmp r12d, 300h                  ; EN_CHANGE
    jne dp_true
    CS_ENTER
    mov ecx, IDC_OUVERTP
    lea rdx, g_ouvertp
    mov r8d, 128
    call get_text_u8
    jmp dc_unlock

dc_ontop:
    test r12d, r12d                 ; BN_CLICKED
    jnz dp_true
    mov ecx, IDC_ONTOP
    mov edx, 0F0h                   ; BM_GETCHECK
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    add al, '0'
    mov byte ptr g_ontop, al
    mov byte ptr g_ontop+1, 0
    call apply_ontop
    call save_settings
    jmp dp_true

dc_tray:
    test r12d, r12d                 ; BN_CLICKED
    jnz dp_true
    mov ecx, IDC_TRAY
    mov edx, 0F0h                   ; BM_GETCHECK
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    add al, '0'
    mov byte ptr g_tray, al
    mov byte ptr g_tray+1, 0
    mov ecx, 2                      ; NIM_DELETE
    cmp al, '1'
    jne dt_icon
    xor ecx, ecx                    ; NIM_ADD
dt_icon:
    call tray_icon
    call save_settings
    jmp dp_true

dc_chatcmd:
    cmp r12d, 300h                  ; EN_CHANGE
    jne dp_true
    CS_ENTER
    mov ecx, IDC_CHATCMD
    lea rdx, g_chatcmd
    mov r8d, 64
    call get_text_u8
    jmp dc_unlock

dc_twbtn:
    test r12d, r12d
    jnz dp_true
    ; state 0 -> sign in (1), 2 -> sign out (2), 1 -> cancel (3); disabled until it's done
    mov eax, 1
    mov ecx, g_twstate
    cmp ecx, 2
    jne dt_a1
    mov eax, 2
dt_a1:
    cmp ecx, 1
    jne dt_a2
    mov eax, 3
dt_a2:
    mov g_twaction, eax
    mov rcx, rbx
    mov edx, IDC_TWBTN
    call [__imp_GetDlgItem]
    mov rcx, rax
    xor edx, edx
    call [__imp_EnableWindow]
    mov rcx, g_hReqEvent
    call [__imp_SetEvent]
    jmp dp_true

dc_next:
    test r12d, r12d
    jnz dp_true
    ; one request at a time until Ouvert answers, so a double click can't skip two songs
    cmp g_nextbusy, 0
    jne dp_true
    mov g_nextbusy, 1
    mov rcx, rbx
    mov edx, IDC_NEXT
    call [__imp_GetDlgItem]
    mov rcx, rax
    xor edx, edx
    call [__imp_EnableWindow]
    mov ecx, IDC_NEXTMSG
    lea rdx, s_empty
    call set_text_u8
    mov g_reqnext, 1
    mov rcx, g_hReqEvent
    call [__imp_SetEvent]
    jmp dp_true

dc_nav:
    cmp r12d, 1                     ; LBN_SELCHANGE
    jne dp_true
    mov ecx, IDC_NAV
    mov edx, 188h                   ; LB_GETCURSEL
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    cmp eax, PAGE_SETTINGS
    ja dp_true
    mov g_page, eax
    mov r12d, eax
    dec eax                         ; a mode page -> the mode being viewed
    cmp eax, 1
    ja dn_show
    mov g_view, eax
    CS_ENTER
    call select_scenes
    CS_LEAVE
dn_show:
    call show_page
    cmp r12d, PAGE_REQUESTS
    jne dp_true
    mov rcx, g_hReqEvent            ; fetch the queue now
    call [__imp_SetEvent]
    jmp dp_true

dc_usemode:
    test r12d, r12d
    jnz dp_true
    mov r12d, g_view
    CS_ENTER
    mov g_mode, r12d
    lea eax, [r12+'0']
    mov byte ptr g_modestr, al
    mov byte ptr g_modestr+1, 0
    CS_LEAVE
    call save_settings
    mov g_modechg, 1                ; the worker moves OBS to the new mode's scene
    mov rcx, g_hEvent
    call [__imp_SetEvent]
    call show_page
    jmp dp_true

dc_connect:
    test r12d, r12d
    jnz dp_true
    cmp g_page, PAGE_SETTINGS       ; Enter on another page
    jne dp_true
    mov ecx, IDC_PORT
    lea rdx, g_uitmp
    mov r8d, 16
    call get_text_u8
    lea rcx, g_uitmp
    call atou
    test rax, rax
    jz dc_badport
    cmp rax, 65535
    ja dc_badport
    CS_ENTER
    lea rcx, g_port
    lea rdx, g_uitmp
    call stpcpy
    mov ecx, IDC_HOST
    lea rdx, g_host
    mov r8d, 256
    call get_text_u8
    mov ecx, IDC_PASS
    lea rdx, g_pass
    mov r8d, 256
    call get_text_u8
    CS_LEAVE
    call save_settings
    call request_connect
    jmp dp_true
dc_badport:
    mov ecx, IDC_CONN
    lea rdx, st_badport
    call set_text_u8
    jmp dp_true

dc_song:
    cmp r12d, 1                     ; CBN_SELCHANGE
    jne dp_true
    mov ecx, IDC_SONG
    mov edx, 147h                   ; CB_GETCURSEL
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    mov r12d, eax
    CS_ENTER
    cmp r12d, g_nscenes
    jae dc_unlock
    call view_bufs
    mov rcx, rax
    lea rax, g_scenes
    mov rdx, [rax+r12*8]
    call stpcpy
    mov byte ptr g_stat_event, 0    ; drop the "pick a scene" hint
    jmp dc_unlock

dc_menu:
    cmp r12d, 1
    jne dp_true
    mov ecx, IDC_MENU
    mov edx, 147h
    xor r8d, r8d
    xor r9d, r9d
    call send_dlg
    mov r12d, eax
    CS_ENTER
    call view_bufs
    mov rdi, rdx
    mov byte ptr [rdi], 0
    test r12d, r12d                 ; item 0 = "(none)"
    jz dc_unlock
    dec r12d
    cmp r12d, g_nscenes
    jae dc_unlock
    lea rax, g_scenes
    mov rdx, [rax+r12*8]
    mov rcx, rdi
    call stpcpy
dc_unlock:
    CS_LEAVE
    call save_settings
    call update_status
    jmp dp_true

dc_delay:
    cmp r12d, 300h                  ; EN_CHANGE
    jne dp_true
    mov rcx, rbx
    mov edx, IDC_DELAY
    lea r8, g_uitmp
    mov r9d, 32
    call [__imp_GetDlgItemTextA]
    lea rcx, g_uitmp
    call parse_ms
    cmp rax, -1
    je dp_true                      ; ignore until it is a valid number
    mov r12, rax
    CS_ENTER
    mov g_delayms, r12
    lea rcx, g_delay
    lea rdx, g_uitmp
    call stpcpy
    jmp dc_unlock

dc_file:
    cmp r12d, 300h
    jne dp_true
    mov rcx, rbx
    mov edx, IDC_FILE
    lea r8, g_uitmp
    mov r9d, 1024
    call [__imp_GetDlgItemTextA]
    lea rcx, g_uitmp
    call trim
    lea rcx, g_uitmp
    call strip_quotes
    CS_ENTER
    lea rcx, g_file
    lea rdx, g_uitmp
    call stpcpy
    jmp dc_unlock

dc_browse:
    test r12d, r12d
    jnz dp_true
    mov byte ptr g_ofnfile, 0
    lea rcx, g_file
    call file_exists
    test eax, eax
    jz db_open
    lea rcx, g_ofnfile
    lea rdx, g_file
    call stpcpy
db_open:
    mov dword ptr g_ofn, 152
    mov qword ptr g_ofn+8, rbx
    lea rax, s_filter
    mov qword ptr g_ofn+24, rax
    lea rax, g_ofnfile
    mov qword ptr g_ofn+48, rax
    mov dword ptr g_ofn+56, 1024
    mov dword ptr g_ofn+96, 100Ch   ; FILEMUSTEXIST | NOCHANGEDIR | HIDEREADONLY
    lea rcx, g_ofn
    call [__imp_GetOpenFileNameA]
    test eax, eax
    jz dp_true
    mov rcx, rbx                    ; EN_CHANGE then saves it
    mov edx, IDC_FILE
    lea r8, g_ofnfile
    call [__imp_SetDlgItemTextA]
    jmp dp_true

dp_syscmd:
    mov eax, esi
    and eax, 0FFF0h
    cmp eax, 0F020h                 ; SC_MINIMIZE: hide to the tray if that's turned on
    jne dp_false
    cmp byte ptr g_tray, '1'
    jne dp_false
    mov rcx, rbx
    xor edx, edx                    ; SW_HIDE
    call [__imp_ShowWindow]
    jmp dp_true

dp_close:
    call win_capture
    call save_settings
    mov ecx, 2                      ; NIM_DELETE
    call tray_icon
    mov rcx, rbx
    xor edx, edx
    call [__imp_EndDialog]
    jmp dp_true

dp_status:
    call update_status
    jmp dp_true

dp_scenes:
    call fill_scenes
    jmp dp_true

dp_reqs:
    call req_show
    jmp dp_true

dp_moved:
    call win_capture
    call save_settings
    jmp dp_true

dp_twitch:
    call save_settings
    call tw_ui
ifndef CHSS_TEST
    test rsi, rsi                   ; open the sign-in page
    jz dp_true
    xor ecx, ecx
    lea rdx, s_open
    lea r8, r_verif
    xor r9d, r9d
    and qword ptr [rsp+20h], 0
    mov qword ptr [rsp+28h], 1      ; SW_SHOWNORMAL
    call [__imp_ShellExecuteA]
endif
    jmp dp_true

dp_nextdone:
    mov g_nextbusy, 0
    CS_ENTER
    mov ecx, IDC_NEXTMSG
    lea rdx, g_nextmsg
    call set_text_u8
    CS_LEAVE
    mov rcx, rbx
    mov edx, IDC_NEXT
    call [__imp_GetDlgItem]
    mov rcx, rax
    mov edx, 1
    call [__imp_EnableWindow]
    jmp dp_true

dp_size:
    cmp rsi, 1                      ; SIZE_MINIMIZED
    je dp_false
    cmp g_laydone, 0
    je dp_false
    movzx ecx, di
    mov edx, edi
    shr edx, 16
    call layout_apply
    jmp dp_true

dp_minmax:
    mov eax, g_minw
    test eax, eax
    jz dp_false
    mov [rdi+24], eax               ; MINMAXINFO.ptMinTrackSize
    mov eax, g_minh
    mov [rdi+28], eax
    jmp dp_true

dp_ctlstatic:
    mov rcx, rdi
    call [__imp_GetDlgCtrlID]
    cmp eax, IDC_DIVIDER
    je dp_div
    mov edx, CLR_MUTED
    cmp eax, IDC_DOT
    jne cs_color
    mov eax, g_connstate
    mov edx, CLR_DOTOFF
    cmp eax, 2
    jne cs_dot3
    mov edx, CLR_DOTOK
cs_dot3:
    cmp eax, 3
    jne cs_color
    mov edx, CLR_DOTERR
cs_color:
    mov rcx, rsi
    call [__imp_SetTextColor]
    mov rcx, rsi
    mov edx, 1                      ; TRANSPARENT
    call [__imp_SetBkMode]
dp_bg:
    mov rax, g_hBgBrush
    jmp dp_ret
dp_div:
    mov rax, g_hDivBrush
    jmp dp_ret

dp_ctllist:
    mov rcx, rdi
    call [__imp_GetDlgCtrlID]
    cmp eax, IDC_NAV                ; the page list sits on the window background
    je dp_bg
dp_ctledit:                         ; text boxes and dropdown lists
    mov rcx, rsi
    mov edx, CLR_TEXT
    call [__imp_SetTextColor]
    mov rcx, rsi
    mov edx, CLR_FIELD
    call [__imp_SetBkColor]
    mov rax, g_hFieldBrush
    jmp dp_ret

dp_measure:
    cmp dword ptr [rdi+4], IDC_NAV  ; MEASUREITEMSTRUCT.CtlID
    jne dp_false
    and qword ptr g_rc, 0
    mov dword ptr g_rc+8, 7         ; text inset, dialog units
    mov dword ptr g_rc+12, 15       ; item height, dialog units
    mov rcx, rbx
    lea rdx, g_rc
    call [__imp_MapDialogRect]
    mov eax, dword ptr g_rc+8
    mov g_navpad, eax
    mov eax, dword ptr g_rc+12
    mov dword ptr [rdi+16], eax     ; itemHeight
    jmp dp_true

dp_drawitem:
    cmp dword ptr [rdi+4], IDC_NAV  ; DRAWITEMSTRUCT.CtlID
    jne dp_false
    cmp dword ptr [rdi+8], -1       ; itemID: empty list
    je dp_true
    mov r12d, dword ptr [rdi+16]    ; itemState
    and r12d, 1                     ; ODS_SELECTED
    mov r8, g_hSelBrush
    jnz dd_fill
    mov r8, g_hBgBrush
dd_fill:
    mov rcx, [rdi+32]               ; hDC
    lea rdx, [rdi+40]               ; rcItem
    call [__imp_FillRect]
    mov rcx, [rdi+32]
    mov edx, 1                      ; TRANSPARENT
    call [__imp_SetBkMode]
    mov edx, CLR_MUTED
    test r12d, r12d
    jz dd_text
    mov edx, CLR_ACCENT
dd_text:
    mov rcx, [rdi+32]
    call [__imp_SetTextColor]
    mov ecx, IDC_NAV
    mov edx, 189h                   ; LB_GETTEXT
    mov r8d, dword ptr [rdi+8]
    lea r9, g_wtmp
    call send_dlg
    mov rax, [rdi+40]
    mov qword ptr g_rc, rax
    mov rax, [rdi+48]
    mov qword ptr g_rc+8, rax
    mov eax, g_navpad
    add dword ptr g_rc, eax
    mov rcx, [rdi+32]
    lea rdx, g_wtmp
    mov r8d, -1
    lea r9, g_rc
    mov qword ptr [rsp+20h], 24h    ; DT_SINGLELINE | DT_VCENTER
    call [__imp_DrawTextW]
    jmp dp_true

dp_tray:
    cmp edi, 202h                   ; WM_LBUTTONUP
    je dt_show
    cmp edi, 203h                   ; WM_LBUTTONDBLCLK
    je dt_show
    cmp edi, 205h                   ; WM_RBUTTONUP
    jne dp_true
    call [__imp_CreatePopupMenu]
    mov r12, rax
    mov rcx, r12
    xor edx, edx                    ; MF_STRING
    mov r8d, ID_SHOW
    lea r9, s_show
    call [__imp_AppendMenuA]
    mov rcx, r12
    xor edx, edx
    mov r8d, ID_EXIT
    lea r9, s_exit
    call [__imp_AppendMenuA]
    lea rcx, g_pt
    call [__imp_GetCursorPos]
    mov rcx, rbx
    call [__imp_SetForegroundWindow]
    mov rcx, r12
    mov edx, 102h                   ; TPM_RETURNCMD | TPM_RIGHTBUTTON
    mov r8d, dword ptr g_pt
    mov r9d, dword ptr g_pt+4
    and qword ptr [rsp+20h], 0
    mov [rsp+28h], rbx
    and qword ptr [rsp+30h], 0
    call [__imp_TrackPopupMenu]
    mov esi, eax
    mov rcx, r12
    call [__imp_DestroyMenu]
    cmp esi, ID_EXIT
    je dp_close
    cmp esi, ID_SHOW
    jne dp_true
dt_show:
    mov rcx, rbx
    mov edx, 5                      ; SW_SHOW
    call [__imp_ShowWindow]
    mov rcx, rbx
    call [__imp_SetForegroundWindow]
    mov rcx, g_hReqEvent            ; back on screen: refresh the queue if it's showing
    call [__imp_SetEvent]
    jmp dp_true
DlgProc ENDP

; ---- entry point -------------------------------------------------------------

main PROC
    sub rsp, 38h
    ; DLLs loaded later (by Windows on the app's behalf) also come from System32 only
    mov ecx, 800h                   ; LOAD_LIBRARY_SEARCH_SYSTEM32
    call [__imp_SetDefaultDllDirectories]
    call [__imp_InitCommonControls]
    xor ecx, ecx
    call [__imp_GetModuleHandleA]
    mov g_hInst, rax
    lea rcx, g_cs
    call [__imp_InitializeCriticalSection]
    call init_paths
    call load_settings
    call migrate
    call load_settings
    call find_song_file
    cmp g_resave, 0                 ; replaces plain-text secrets from older versions
    je mn_saved
    call save_settings
mn_saved:
    xor eax, eax
    cmp byte ptr g_modestr, '1'
    sete al
    mov g_mode, eax
    lea rcx, g_delay
    call parse_ms
    cmp rax, -1
    jne mn_dl
    xor eax, eax
mn_dl:
    mov g_delayms, rax
    xor ebx, ebx
mn_br:
    lea rax, brush_clr
    mov ecx, [rax+rbx*4]
    call [__imp_CreateSolidBrush]
    lea rcx, g_hBgBrush
    mov [rcx+rbx*8], rax
    inc ebx
    cmp ebx, 4
    jb mn_br
    xor ecx, ecx
    xor edx, edx                    ; auto-reset
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_CreateEventA]
    mov g_hEvent, rax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_CreateEventA]
    mov g_hReqEvent, rax
    mov rcx, g_hInst
    mov edx, 1                      ; dialog resource id
    xor r8d, r8d
    lea r9, DlgProc
    and qword ptr [rsp+20h], 0
    call [__imp_DialogBoxParamA]
    xor ecx, ecx
    call [__imp_ExitProcess]
main ENDP

END
