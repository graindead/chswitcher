; Clone Hero -> OBS scene switcher, x64 MASM.
;
; Watches Clone Hero's currentsong.txt and switches OBS scenes through the
; OBS WebSocket server (v5 protocol, OBS 28+):
;   file gets text (song started)  -> song scene
;   file emptied (song ended/quit) -> menu scene, after an optional delay
;
; Settings live in %APPDATA%\CH Scene Switcher\settings.ini (settings.json from
; the Python version is imported once). Press S during the startup countdown,
; or run with --setup, to answer the setup questions again.
;
; Uses only what ships with Windows 10/11: WinHTTP for the WebSocket, BCrypt for
; SHA-256 and Crypt32 for base64. Build with build.bat.

option casemap:none

IMP macro n
    extern __imp_&n:qword
endm

IMP ExitProcess
IMP GetStdHandle
IMP WriteFile
IMP ReadFile
IMP CreateFileA
IMP CloseHandle
IMP GetFileTime
IMP GetFileAttributesA
IMP CreateDirectoryA
IMP GetEnvironmentVariableA
IMP GetPrivateProfileStringA
IMP WritePrivateProfileStringA
IMP GetCommandLineA
IMP SetConsoleOutputCP
IMP SetConsoleCP
IMP GetConsoleMode
IMP GetNumberOfConsoleInputEvents
IMP ReadConsoleInputA
IMP FlushConsoleInputBuffer
IMP Sleep
IMP GetTickCount64
IMP GetLastError
IMP MultiByteToWideChar
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

; print a zero-terminated string
PUTS macro s
    lea rcx, s
    call print
endm

RBUF_SIZE   equ 262144
TEXTSIZE    equ 4096
MAXSCENES   equ 256
NSET        equ 7
POLL_MS     equ 250

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
s_setupflag db '--setup',0

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

w_agent     dw 'c','h','s','s',0
w_get       dw 'G','E','T',0
w_slash     dw '/',0

s_hdr1      db '=== OBS WebSocket (OBS: Tools -> WebSocket Server Settings -> Show Connect Info) ===',13,10
            db 'Press Enter to keep the value in [brackets].',13,10,13,10,0
s_q_ip      db 'Server IP',0
s_q_port    db 'Server Port',0
s_q_pass    db 'Server Password (blank if auth is off)',0
s_portnum   db '  Port must be a number.',13,10,0
s_cc1       db 13,10,"Couldn't connect: ",0
s_cc2       db 13,10,'Make sure OBS is open and the WebSocket server is enabled, then try again.',13,10,13,10,0
s_connected db 'Connected!',13,10,13,10,0
s_hdr2      db '=== Scenes in OBS ===',13,10,0
s_q_song    db 'Scene while a SONG is playing',0
s_q_menu    db 'Scene while in MENUS',0
s_numname   db ' (number or name',0
s_none      db ", 0 = don't switch back",0
s_rparen    db ')',0
s_notscene  db "  That's not one of the scenes listed above.",13,10,0
s_q_delay   db 'Seconds to wait after a song ends before switching back',0
s_delaynum  db '  Enter a number, like 0 or 5.',13,10,0
s_q_path    db 'Path to currentsong.txt',0
s_notyet    db "  (File doesn't exist yet - it'll be picked up once Clone Hero creates it.)",13,10,0
s_gone      db 'A saved scene no longer exists in OBS - pick them again.',13,10,13,10,0
s_cd1       db 13,'Starting with saved settings in ',0
s_cd2       db 's... press S to change settings ',0
s_cant1     db "Can't connect to OBS: ",0
s_cant2     db '; retrying in 5s...',13,10
            db '  (Is OBS open? If the password/port changed, restart and press S to change settings.)',13,10,0
s_connto    db 'Connected to OBS at ',0
s_watching  db 13,10,'Watching: ',0
s_songarrow db 13,10,"Song -> '",0
s_menuarrow db "' | Menu -> '",0
s_after     db "' after ",0
s_secs      db 's',0
s_apos      db "'",0
s_leave     db 13,10,'Leave this window open while you play. Ctrl+C to stop.',13,10,13,10,0
s_songcolon db 'Song: ',0
s_swfail    db 'Scene switch failed; reconnecting...',13,10,0
s_still1    db "Still failed (does a scene named '",0
s_still2    db "' exist?)",13,10,0
s_arrow     db '-> ',0
s_crlf      db 13,10,0
s_crlf2     db 13,10,13,10,0
s_lbr       db ' [',0
s_rbr       db ']',0
s_colon     db ': ',0
s_colon1    db ':',0
s_indent    db '  ',0
s_dot       db '. ',0
s_zero      db '0',0
s_noresp    db 'no response from ',0
s_errcode   db ' (error ',0
s_closed    db 'OBS closed the connection',0
s_star      db '*',0

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
g_hOut      dq ?
g_hIn       dq ?
g_hSession  dq ?
g_hConnect  dq ?
g_hWs       dq ?
g_mtime     dq ?
g_delayms   dq ?
g_scenes    dq MAXSCENES dup(?)
g_tmpptrs   dq MAXSCENES dup(?)
g_written   dd ?
g_read      dd ?
g_inpos     dd ?
g_inlen     dd ?
g_rlen      dd ?
g_rtype     dd ?
g_cch       dd ?
g_nev       dd ?
g_mode      dd ?
g_reasonlen dd ?
g_nscenes   dd ?
g_closecode dw ?
g_whost     dw 256 dup(?)
g_inrec     db 32 dup(?)
g_digits    db 24 dup(?)
g_num       db 24 dup(?)
g_host      db 256 dup(?)
g_port      db 16 dup(?)
g_pass      db 256 dup(?)
g_song      db 512 dup(?)
g_menu      db 512 dup(?)
g_delay     db 32 dup(?)
g_file      db 1024 dup(?)
g_dir       db 512 dup(?)
g_ini       db 512 dup(?)
g_json      db 512 dup(?)
g_home      db 512 dup(?)
g_tmp       db 2048 dup(?)
g_line      db 1024 dup(?)
g_pick      db 512 dup(?)
g_prompt    db 512 dup(?)
g_bak       db 256 dup(?)
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
g_inbuf     db 4096 dup(?)
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

; rcx = value, rdx = dst -> rax = pointer to dst's terminating zero
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

; ---- console ---------------------------------------------------------------

; rcx = ptr, rdx = length
print_n PROC
    sub rsp, 38h
    mov r8, rdx
    mov rdx, rcx
    mov rcx, g_hOut
    lea r9, g_written
    and qword ptr [rsp+20h], 0
    call [__imp_WriteFile]
    add rsp, 38h
    ret
print_n ENDP

; rcx = zero-terminated string
print PROC
    push rcx
    call strlen
    pop rcx
    mov rdx, rax
    jmp print_n
print ENDP

; rcx = buf, rdx = buf size -> rax = length of the trimmed line.
; Exits the program at end of input.
read_line PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 30h
    mov rbx, rcx
    lea rdi, [rdx-1]
    xor esi, esi
rl_l:
    mov eax, g_inpos
    cmp eax, g_inlen
    jb rl_have
    mov rcx, g_hIn
    lea rdx, g_inbuf
    mov r8d, 4096
    lea r9, g_inlen
    and qword ptr [rsp+20h], 0
    call [__imp_ReadFile]
    mov g_inpos, 0
    test eax, eax
    jz rl_eof
    cmp g_inlen, 0
    je rl_eof
    jmp rl_l
rl_have:
    lea rcx, g_inbuf
    mov al, [rcx+rax]
    inc g_inpos
    cmp al, 0Ah
    je rl_done
    cmp rsi, rdi
    jae rl_l
    mov [rbx+rsi], al
    inc rsi
    jmp rl_l
rl_eof:
    mov g_inlen, 0
    test rsi, rsi
    jnz rl_done
    xor ecx, ecx
    call [__imp_ExitProcess]
rl_done:
    mov byte ptr [rbx+rsi], 0
    mov rcx, rbx
    call trim
    add rsp, 30h
    pop rdi
    pop rsi
    pop rbx
    ret
read_line ENDP

; rcx = prompt, rdx = value buffer (shown as the default, replaced by any answer),
; r8 = buffer size, r9d = 1 to show the default as stars
ask PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 28h
    mov rbx, rdx
    mov rsi, r8
    mov edi, r9d
    call print
    cmp byte ptr [rbx], 0
    je ak_nodef
    PUTS s_lbr
    test edi, edi
    jz ak_plain
    mov rcx, rbx
    call strlen
    mov r12, rax
ak_st:
    PUTS s_star
    dec r12
    jnz ak_st
    jmp ak_rb
ak_plain:
    mov rcx, rbx
    call print
ak_rb:
    PUTS s_rbr
ak_nodef:
    PUTS s_colon
    lea rcx, g_line
    mov edx, 1024
    call read_line
    test rax, rax
    jz ak_ret
    mov rcx, rbx
    lea rdx, g_line
    mov r8, rsi
    call strncpy0
ak_ret:
    add rsp, 28h
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
ask ENDP

; Counts down, returning eax = 1 if S is pressed
wants_setup PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov rcx, g_hIn
    lea rdx, g_mode
    call [__imp_GetConsoleMode]
    mov edi, eax
    mov esi, 3
wt_sec:
    PUTS s_cd1
    mov ecx, esi
    lea rdx, g_num
    call utoa
    PUTS g_num
    PUTS s_cd2
    mov ebx, 10
wt_tick:
    mov ecx, 100
    call [__imp_Sleep]
    test edi, edi
    jz wt_next
wt_ev:
    mov rcx, g_hIn
    lea rdx, g_nev
    call [__imp_GetNumberOfConsoleInputEvents]
    test eax, eax
    jz wt_next
    cmp g_nev, 0
    je wt_next
    mov rcx, g_hIn
    lea rdx, g_inrec
    mov r8d, 1
    lea r9, g_nev
    call [__imp_ReadConsoleInputA]
    test eax, eax
    jz wt_next
    cmp word ptr g_inrec, 1         ; KEY_EVENT
    jne wt_ev
    cmp dword ptr g_inrec+4, 0      ; bKeyDown
    je wt_ev
    cmp word ptr g_inrec+10, 53h    ; 'S'
    jne wt_ev
    PUTS s_crlf2
    mov rcx, g_hIn
    call [__imp_FlushConsoleInputBuffer]
    mov eax, 1
    jmp wt_ret
wt_next:
    dec ebx
    jnz wt_tick
    dec esi
    jnz wt_sec
    PUTS s_crlf2
    xor eax, eax
wt_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
wants_setup ENDP

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
    lea rcx, g_tmp
    mov byte ptr [rcx], 22h
    inc rcx
    mov rdx, [rbx+8]
    call stpcpy
    mov word ptr [rax], 0022h
    lea rcx, s_section
    mov rdx, [rbx]
    lea r8, g_tmp
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
    lea rcx, g_tmp
    lea rdx, g_home
    call stpcpy
    mov rcx, rax
    mov rdx, [rbx]
    call stpcpy
    lea rcx, g_tmp
    call file_exists
    test eax, eax
    jnz fs_found
    add rbx, 8
    jmp fs_l
fs_found:
    lea rcx, g_file
    lea rdx, g_tmp
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

; Reads currentsong.txt into g_text (trimmed) and its last-write time into g_mtime
read_state PROC
    sub rsp, 28h
    mov g_mtime, 0
    lea rcx, g_file
    lea rdx, g_text
    mov r8d, TEXTSIZE
    lea r9, g_mtime
    call read_file
    lea rcx, g_text
    call trim
    add rsp, 28h
    ret
read_state ENDP

; ---- OBS WebSocket ----------------------------------------------------------

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

; Connects and logs in to OBS -> eax = 1, or 0 with the reason in g_err
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
    lea rcx, g_port
    call atou
    mov rbx, rax
    mov ecx, 65001
    xor edx, edx
    lea r8, g_host
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
    lea rdx, g_pass
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
    lea rdx, g_host
    call stpcpy
    mov byte ptr [rax], ':'
    lea rcx, [rax+1]
    lea rdx, g_port
    call stpcpy
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

; Connects, retrying every 5 seconds until it works
connect_loop PROC
    sub rsp, 28h
cl_l:
    call ws_connect
    test eax, eax
    jnz cl_ok
    PUTS s_cant1
    PUTS g_err
    PUTS s_cant2
    mov ecx, 5000
    call [__imp_Sleep]
    jmp cl_l
cl_ok:
    PUTS s_connto
    PUTS g_host
    PUTS s_colon1
    PUTS g_port
    PUTS s_crlf
    add rsp, 28h
    ret
connect_loop ENDP

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
    mov eax, 1
gs_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
get_scenes ENDP

get_scenes_retry PROC
    sub rsp, 28h
gr_l:
    call get_scenes
    test eax, eax
    jnz gr_ret
    call connect_loop
    jmp gr_l
gr_ret:
    add rsp, 28h
    ret
get_scenes_retry ENDP

; rcx = name -> eax = 1 if it is in g_scenes
scene_exists PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov rdi, rcx
    xor ebx, ebx
    lea rsi, g_scenes
sx_l:
    cmp ebx, g_nscenes
    jae sx_no
    mov rcx, rdi
    mov rdx, [rsi+rbx*8]
    call streq
    test eax, eax
    jnz sx_ret
    inc ebx
    jmp sx_l
sx_no:
    xor eax, eax
sx_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
scene_exists ENDP

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

; rcx = scene name (empty = do nothing). Reconnects and retries once on failure.
switch_scene PROC
    push rbx
    sub rsp, 20h
    mov rbx, rcx
    cmp byte ptr [rcx], 0
    je ss_ret
    call sw_try
    test eax, eax
    jnz ss_ok
    PUTS s_swfail
    call connect_loop
    mov rcx, rbx
    call sw_try
    test eax, eax
    jnz ss_ok
    PUTS s_still1
    mov rcx, rbx
    call print
    PUTS s_still2
    jmp ss_ret
ss_ok:
    PUTS s_arrow
    mov rcx, rbx
    call print
    PUTS s_crlf
ss_ret:
    add rsp, 20h
    pop rbx
    ret
switch_scene ENDP

; ---- setup questions ---------------------------------------------------------

setup_connection PROC
    sub rsp, 28h
    PUTS s_hdr1
su_l:
    lea rcx, s_q_ip
    lea rdx, g_host
    mov r8d, 256
    xor r9d, r9d
    call ask
su_port:
    lea rcx, g_bak
    lea rdx, g_port
    call stpcpy
    lea rcx, s_q_port
    lea rdx, g_port
    mov r8d, 16
    xor r9d, r9d
    call ask
    lea rcx, g_port
    call atou
    test rax, rax
    jz su_badport
    cmp rax, 65535
    jbe su_pass
su_badport:
    lea rcx, g_port
    lea rdx, g_bak
    call stpcpy
    PUTS s_portnum
    jmp su_port
su_pass:
    lea rcx, s_q_pass
    lea rdx, g_pass
    mov r8d, 256
    mov r9d, 1
    call ask
    call ws_connect
    test eax, eax
    jnz su_ok
    PUTS s_cc1
    PUTS g_err
    PUTS s_cc2
    jmp su_l
su_ok:
    PUTS s_connected
    add rsp, 28h
    ret
setup_connection ENDP

; rcx = prompt, rdx = scene buffer (512), r8d = 1 to allow "0" for none
pick_scene PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov rbx, rcx
    mov rsi, rdx
    mov edi, r8d
pk_l:
    lea rcx, g_pick
    mov rdx, rsi
    call stpcpy
    lea rcx, g_prompt
    mov rdx, rbx
    call stpcpy
    mov rcx, rax
    lea rdx, s_numname
    call stpcpy
    mov rcx, rax
    lea rdx, s_none
    test edi, edi
    jnz pk_sfx
    lea rdx, s_empty
pk_sfx:
    call stpcpy
    mov rcx, rax
    lea rdx, s_rparen
    call stpcpy
    lea rcx, g_prompt
    lea rdx, g_pick
    mov r8d, 512
    xor r9d, r9d
    call ask
    test edi, edi
    jz pk_num
    lea rcx, g_pick
    lea rdx, s_zero
    call streq
    test eax, eax
    jz pk_num
    mov byte ptr [rsi], 0
    jmp pk_ret
pk_num:
    lea rcx, g_pick
    call atou
    test rax, rax
    jz pk_name
    mov ecx, g_nscenes
    cmp rax, rcx
    ja pk_name
    lea rcx, g_scenes
    mov rdx, [rcx+rax*8-8]
    mov rcx, rsi
    call stpcpy
    jmp pk_ret
pk_name:
    lea rcx, g_pick
    call scene_exists
    test eax, eax
    jz pk_bad
    mov rcx, rsi
    lea rdx, g_pick
    call stpcpy
    jmp pk_ret
pk_bad:
    PUTS s_notscene
    jmp pk_l
pk_ret:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
pick_scene ENDP

print_scenes PROC
    push rbx
    sub rsp, 20h
    xor ebx, ebx
pl_l:
    cmp ebx, g_nscenes
    jae pl_ret
    PUTS s_indent
    lea ecx, [rbx+1]
    lea rdx, g_num
    call utoa
    PUTS g_num
    PUTS s_dot
    lea rax, g_scenes
    mov rcx, [rax+rbx*8]
    call print
    PUTS s_crlf
    inc ebx
    jmp pl_l
pl_ret:
    add rsp, 20h
    pop rbx
    ret
print_scenes ENDP

setup_scenes PROC
    sub rsp, 28h
    PUTS s_hdr2
    call print_scenes
    PUTS s_crlf
    lea rcx, s_q_song
    lea rdx, g_song
    xor r8d, r8d
    call pick_scene
    lea rcx, s_q_menu
    lea rdx, g_menu
    mov r8d, 1
    call pick_scene
    cmp byte ptr g_menu, 0
    je sc2_ret
sc2_d:
    lea rcx, g_bak
    lea rdx, g_delay
    call stpcpy
    lea rcx, s_q_delay
    lea rdx, g_delay
    mov r8d, 32
    xor r9d, r9d
    call ask
    lea rcx, g_delay
    call parse_ms
    cmp rax, -1
    jne sc2_ret
    lea rcx, g_delay
    lea rdx, g_bak
    call stpcpy
    PUTS s_delaynum
    jmp sc2_d
sc2_ret:
    add rsp, 28h
    ret
setup_scenes ENDP

setup_song_file PROC
    sub rsp, 28h
    call find_song_file
    PUTS s_crlf
    lea rcx, s_q_path
    lea rdx, g_file
    mov r8d, 1024
    xor r9d, r9d
    call ask
    lea rcx, g_file
    call strip_quotes
    lea rcx, g_file
    call file_exists
    test eax, eax
    jnz sf2_ret
    PUTS s_notyet
sf2_ret:
    add rsp, 28h
    ret
setup_song_file ENDP

; ---- entry point -------------------------------------------------------------

main PROC
    sub rsp, 28h
    mov ecx, -11                    ; STD_OUTPUT_HANDLE
    call [__imp_GetStdHandle]
    mov g_hOut, rax
    mov ecx, -10                    ; STD_INPUT_HANDLE
    call [__imp_GetStdHandle]
    mov g_hIn, rax
    mov ecx, 65001
    call [__imp_SetConsoleOutputCP]
    mov ecx, 65001
    call [__imp_SetConsoleCP]
    call init_paths
    call load_settings
    call migrate
    call load_settings

    cmp byte ptr g_song, 0
    je mn_setup
    call [__imp_GetCommandLineA]
    mov rcx, rax
    lea rdx, s_setupflag
    call strfind
    test rax, rax
    jnz mn_setup
    call wants_setup
    test eax, eax
    jnz mn_setup

    ; start with the saved settings
    call connect_loop
    call get_scenes_retry
    lea rcx, g_song
    call scene_exists
    test eax, eax
    jz mn_rescene
    cmp byte ptr g_menu, 0
    je mn_found
    lea rcx, g_menu
    call scene_exists
    test eax, eax
    jnz mn_found
mn_rescene:
    PUTS s_gone
    call setup_scenes
    call save_settings
mn_found:
    call find_song_file
    jmp mn_watch

mn_setup:
    call setup_connection
    call get_scenes_retry
    call setup_scenes
    call setup_song_file
    call save_settings

mn_watch:
    PUTS s_watching
    PUTS g_file
    PUTS s_songarrow
    PUTS g_song
    cmp byte ptr g_menu, 0
    je mn_nomenu
    PUTS s_menuarrow
    PUTS g_menu
    PUTS s_after
    PUTS g_delay
    PUTS s_secs
    jmp mn_sum
mn_nomenu:
    PUTS s_apos
mn_sum:
    PUTS s_leave
    lea rcx, g_delay
    call parse_ms
    cmp rax, -1
    jne mn_dl
    xor eax, eax
mn_dl:
    mov g_delayms, rax

    ; r12 = last mtime, r13d = playing, r14d = menu switch pending, r15 = due tick
    call read_state
    lea rcx, g_last
    lea rdx, g_text
    call stpcpy
    mov r12, g_mtime
    xor r13d, r13d
    cmp byte ptr g_text, 0
    je mn_init
    mov r13d, 1
mn_init:
    xor r14d, r14d
mn_loop:
    mov ecx, POLL_MS
    call [__imp_Sleep]
    call read_state
    cmp r12, g_mtime
    jne mn_changed
    lea rcx, g_text
    lea rdx, g_last
    call streq
    test eax, eax
    jnz mn_pending
mn_changed:
    mov r12, g_mtime
    lea rcx, g_last
    lea rdx, g_text
    call stpcpy
    cmp byte ptr g_text, 0
    je mn_empty
    ; print the first line of the song info
    PUTS s_songcolon
    lea rcx, g_text
    mov rdx, rcx
mn_fl:
    mov al, [rdx]
    test al, al
    jz mn_fle
    cmp al, 0Dh
    je mn_fle
    cmp al, 0Ah
    je mn_fle
    inc rdx
    jmp mn_fl
mn_fle:
    sub rdx, rcx
    call print_n
    PUTS s_crlf
    xor r14d, r14d
    test r13d, r13d
    jnz mn_pending
    mov r13d, 1
    lea rcx, g_song
    call switch_scene
    jmp mn_pending
mn_empty:
    test r13d, r13d
    jz mn_pending
    xor r13d, r13d
    mov r14d, 1
    call [__imp_GetTickCount64]
    add rax, g_delayms
    mov r15, rax
mn_pending:
    test r14d, r14d
    jz mn_loop
    call [__imp_GetTickCount64]
    cmp rax, r15
    jb mn_loop
    xor r14d, r14d
    lea rcx, g_menu
    call switch_scene
    jmp mn_loop
main ENDP

END
