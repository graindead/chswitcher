; Clone Hero -> OBS scene switcher, x64 MASM, small GUI.
;
; Watches Clone Hero's currentsong.txt and switches OBS scenes through the
; OBS WebSocket server (v5 protocol, OBS 28+):
;   file gets text (song started)  -> song scene
;   file emptied (song ended/quit) -> menu scene, after an optional delay
;
; Two threads:
;   UI thread     - the dialog (chss.rc) and the tray icon. Never touches the network.
;   worker thread - connects to OBS, watches the file and switches scenes, so a slow
;                   or unreachable OBS never freezes the window.
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
IMP BCryptHash
IMP CryptBinaryToStringA

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
NSET        equ 7
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
IDC_EVENT   equ 111
ID_SHOW     equ 200
ID_EXIT     equ 201

WM_APP_STATUS equ 8000h
WM_APP_SCENES equ 8001h
WM_APP_TRAY   equ 800Ah

; ---------------------------------------------------------------------------
.data

s_section   db 'settings',0
k_host      db 'host',0
k_port      db 'port',0
k_pass      db 'password',0
k_song      db 'song_scene',0
k_menu      db 'menu_scene',0
k_delay     db 'menu_delay',0
k_file      db 'song_file',0
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

s_title     db 'CH Scene Switcher',0
s_show      db 'Show',0
s_exit      db 'Exit',0
s_noneitem  db '(none)',0
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
; settings.json patterns, in settings_tbl order (ending in " = string value, else number)
mig_tbl      dq m_host, m_port, m_pass, m_song, m_menu, m_delay, m_file, 0
sfx_tbl      dq sfx1, sfx2, sfx3, 0

; ---------------------------------------------------------------------------
.data?

align 8
g_hInst     dq ?
g_hDlg      dq ?
g_hEvent    dq ?
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
g_digits    db 24 dup(?)
; settings (written by the UI thread under g_cs)
g_host      db 256 dup(?)
g_port      db 16 dup(?)
g_pass      db 256 dup(?)
g_song      db 512 dup(?)
g_menu      db 512 dup(?)
g_delay     db 32 dup(?)
g_file      db 1024 dup(?)
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

; rcx = str: turn JSON escapes \x into x, in place
unescape PROC
    mov rdx, rcx
ue_l:
    mov al, [rdx]
    cmp al, 5Ch
    jne ue_put
    inc rdx
    mov al, [rdx]
ue_put:
    mov [rcx], al
    test al, al
    jz ue_e
    inc rcx
    inc rdx
    jmp ue_l
ue_e:
    ret
unescape ENDP

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

; rcx = value, rdx = dst -> rax = pointer to dst's terminating zero (worker thread only)
utoa PROC
    mov rax, rcx
    mov r8, rdx
    lea r9, g_digits+23
    mov byte ptr [r9], 0
    mov r10, 10
ut_l:
    xor edx, edx
    div r10
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz ut_l
    mov rcx, r8
    mov rdx, r9
    jmp stpcpy
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
    mov [rsp+20h], rax
    lea rax, g_ini
    mov [rsp+28h], rax
    call [__imp_GetPrivateProfileStringA]
    add rbx, 32
    dec esi
    jnz ls_l
    add rsp, 38h
    pop rsi
    pop rbx
    ret
load_settings ENDP

; UI thread only (it is the only writer of the settings)
save_settings PROC
    push rbx
    push rsi
    sub rsp, 28h
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
    lea rcx, s_section
    mov rdx, [rbx]
    lea r8, g_uitmp2
    lea r9, g_ini
    call [__imp_WritePrivateProfileStringA]
    add rbx, 32
    dec esi
    jnz sv_l
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

; Copy the settings the watcher needs
wk_sync PROC
    sub rsp, 28h
    CS_ENTER
    lea rcx, w_song
    lea rdx, g_song
    call stpcpy
    lea rcx, w_menu
    lea rdx, g_menu
    call stpcpy
    lea rcx, w_file
    lea rdx, g_file
    call stpcpy
    mov rax, g_delayms
    mov w_delayms, rax
    CS_LEAVE
    add rsp, 28h
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

; ecx = combo id, rdx = UTF-8 item text
combo_add PROC
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
    mov ecx, ebx
    mov edx, 143h                   ; CB_ADDSTRING
    xor r8d, r8d
    lea r9, g_wtmp
    call send_dlg
    add rsp, 30h
    pop rbx
    ret
combo_add ENDP

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
    lea rdx, s_noneitem
    call combo_add
    xor ebx, ebx
fc_l:
    cmp ebx, g_nscenes
    jae fc_sel
    lea rax, g_scenes
    mov rdx, [rax+rbx*8]
    mov ecx, IDC_SONG
    call combo_add
    lea rax, g_scenes
    mov rdx, [rax+rbx*8]
    mov ecx, IDC_MENU
    call combo_add
    inc ebx
    jmp fc_l
fc_sel:
    lea rcx, g_song
    call scene_index
    cmp eax, -1
    jne fc_song
    cmp byte ptr g_song, 0
    je fc_menu
    mov byte ptr g_song, 0
    mov esi, 1
    jmp fc_menu
fc_song:
    mov r8d, eax
    mov ecx, IDC_SONG
    mov edx, 14Eh                   ; CB_SETCURSEL
    xor r9d, r9d
    call send_dlg
fc_menu:
    lea rcx, g_menu
    call scene_index
    inc eax                         ; "(none)" is item 0; missing -> 0 too
    jnz fc_msel
    cmp byte ptr g_menu, 0
    je fc_msel
    mov byte ptr g_menu, 0
    mov esi, 1
fc_msel:
    mov r8d, eax
    mov ecx, IDC_MENU
    mov edx, 14Eh
    xor r9d, r9d
    call send_dlg
    CS_LEAVE
    test esi, esi
    jz fc_ret
    mov ecx, IDC_EVENT
    lea rdx, ev_missing
    call set_text_u8
fc_ret:
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
    mov ecx, IDC_HOST
    lea rdx, g_host
    call set_text_u8
    mov ecx, IDC_PORT
    lea rdx, g_port
    call set_text_u8
    mov ecx, IDC_PASS
    lea rdx, g_pass
    call set_text_u8
    mov rcx, rbx
    mov edx, IDC_DELAY
    lea r8, g_delay
    call [__imp_SetDlgItemTextA]
    mov rcx, rbx
    mov edx, IDC_FILE
    lea r8, g_file
    call [__imp_SetDlgItemTextA]
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
    xor ecx, ecx                    ; NIM_ADD
    call tray_icon
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
    ; saved settings: connect straight away
    cmp byte ptr g_song, 0
    je di_new
    call request_connect
    jmp dp_true
di_new:
    mov ecx, IDC_CONN
    lea rdx, st_enter
    call set_text_u8
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
    jmp dp_true                     ; swallow Enter/Esc (IDOK/IDCANCEL)

dc_connect:
    test r12d, r12d
    jnz dp_true
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
    lea rax, g_scenes
    mov rdx, [rax+r12*8]
    lea rcx, g_song
    call stpcpy
    mov ecx, IDC_EVENT              ; drop the "pick a scene" hint
    lea rdx, s_empty
    call set_text_u8
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
    mov byte ptr g_menu, 0
    test r12d, r12d                 ; item 0 = "(none)"
    jz dc_unlock
    dec r12d
    cmp r12d, g_nscenes
    jae dc_unlock
    lea rax, g_scenes
    mov rdx, [rax+r12*8]
    lea rcx, g_menu
    call stpcpy
dc_unlock:
    CS_LEAVE
    call save_settings
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
    cmp eax, 0F020h                 ; SC_MINIMIZE: hide to the tray instead
    jne dp_false
    mov rcx, rbx
    xor edx, edx                    ; SW_HIDE
    call [__imp_ShowWindow]
    jmp dp_true

dp_close:
    mov ecx, 2                      ; NIM_DELETE
    call tray_icon
    mov rcx, rbx
    xor edx, edx
    call [__imp_EndDialog]
    jmp dp_true

dp_status:
    CS_ENTER
    mov ecx, IDC_CONN
    lea rdx, g_stat_conn
    call set_text_u8
    mov ecx, IDC_EVENT
    lea rdx, g_stat_event
    call set_text_u8
    CS_LEAVE
    jmp dp_true

dp_scenes:
    call fill_scenes
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
    jmp dp_true
DlgProc ENDP

; ---- entry point -------------------------------------------------------------

main PROC
    sub rsp, 38h
    call [__imp_InitCommonControls]
    xor ecx, ecx
    call [__imp_GetModuleHandleA]
    mov g_hInst, rax
    call init_paths
    call load_settings
    call migrate
    call load_settings
    call find_song_file
    lea rcx, g_delay
    call parse_ms
    cmp rax, -1
    jne mn_dl
    xor eax, eax
mn_dl:
    mov g_delayms, rax
    lea rcx, g_cs
    call [__imp_InitializeCriticalSection]
    xor ecx, ecx
    xor edx, edx                    ; auto-reset
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_CreateEventA]
    mov g_hEvent, rax
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
