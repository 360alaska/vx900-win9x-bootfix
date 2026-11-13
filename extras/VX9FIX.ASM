; VX9FIX 1.2 - gives the VIA VX900 video BIOS chip-timer delay a timeout.
; The stock routine starts the chip timer in sequencer register 5D and waits
; for bit 7 with no way out. Inside a Windows 9x virtual machine the VDD drops
; that write and returns its own data for the read, so the wait never ends.
; The routine is found by its code pattern, so any VX900 video BIOS version
; that carries it is handled. Run once per boot, before Windows.
; Copyright (c) 2026 360ALASKA
        org 100h
ROMSEG  equ 0C000h
TAILLEN equ 23                  ; routine bytes 3..25
NEWLEN  equ tmpl_end - tmpl
PCIADR  equ 80000380h           ; bus 0, device 0, function 3, register 80h

start:  cld
        mov dx, msg_title
        call print
        mov ax, ROMSEG
        mov es, ax
        cmp word [es:0], 0AA55h
        jne bad_id
        mov bx, [es:18h]
        cmp word [es:bx], 'PC'
        jne bad_id
        cmp word [es:bx+4], 1106h
        jne bad_id
        cmp word [es:bx+6], 7122h
        jne bad_id
        xor ax, ax
        mov ah, [es:2]
        shl ax, 1               ; image length in bytes
        mov [imgend], ax
        ; find the routine: bytes 3..25 with the two call displacements wild
        xor bp, bp              ; matches
        mov bx, 3
scan:   mov si, tail
        mov di, bx
        mov cx, TAILLEN
.cmp:   lodsb
        mov ah, [es:di]
        inc di
        cmp cx, TAILLEN-9       ; wild: tail offsets 9,10 and 12,13
        je .wild
        cmp cx, TAILLEN-10
        je .wild
        cmp cx, TAILLEN-12
        je .wild
        cmp cx, TAILLEN-13
        je .wild
        cmp al, ah
        jne .no
.wild:  loop .cmp
        inc bp
        mov [found], bx
.no:    inc bx
        mov ax, [imgend]
        sub ax, TAILLEN
        cmp bx, ax
        jb scan
        cmp bp, 1
        jne bad_code
        mov bx, [found]
        sub bx, 3               ; BX = routine start
        mov [oldoff], bx
        cmp byte [es:bx], 0E9h
        je already
        cmp byte [es:bx], 60h
        jne bad_code
        cmp word [es:bx+1], 0F983h
        jne bad_code
        ; call targets
        mov ax, [es:bx+12]
        add ax, bx
        add ax, 14
        mov [wrreg], ax
        mov ax, [es:bx+15]
        add ax, bx
        add ax, 17
        mov [rdreg], ax
        ; spare room: the last 48 bytes of the image must be blank padding
        mov di, [imgend]
        sub di, 48
        mov [newoff], di
        mov al, [es:di]
        cmp al, 0
        je .fill
        cmp al, 0FFh
        jne bad_free
.fill:  mov cx, 48
        repe scasb
        jne bad_free
        ; fix the two calls in the template
        mov ax, [wrreg]
        sub ax, [newoff]
        sub ax, (tmpl_c1 - tmpl) + 3
        mov [tmpl_c1+1], ax
        mov ax, [rdreg]
        sub ax, [newoff]
        sub ax, (tmpl_c2 - tmpl) + 3
        mov [tmpl_c2+1], ax
        ; unlock the C0000-CFFFF shadow
        call pci_sel
        mov dx, 0CFCh
        in al, dx
        mov [saved], al
        call pci_sel
        mov dx, 0CFCh
        mov al, 0FFh
        out dx, al
        mov di, [newoff]
        mov al, [es:di]
        not al
        mov [es:di], al
        cmp [es:di], al
        jne locked
        mov si, tmpl
        mov cx, NEWLEN
        rep movsb
        mov bx, [oldoff]
        mov ax, [newoff]
        sub ax, bx
        sub ax, 3
        cli
        mov byte [es:bx], 0E9h
        mov [es:bx+1], ax
        sti
        call restore
        mov dx, msg_ok
        call print
        mov ax, [oldoff]
        call hex16
        mov dx, msg_ok2
        call print
        mov ax, 4C00h
        int 21h
already:
        mov dx, msg_already
        call print
        mov ax, 4C00h
        int 21h
locked: call restore
        mov dx, msg_locked
        call print
        mov al, [saved]
        call hex8
        mov dx, msg_crlf
        call print
        mov ax, 4C02h
        int 21h
bad_id: mov dx, msg_bad
        call print
        mov ax, 4C01h
        int 21h
bad_code:
        mov dx, msg_code
        call print
        mov ax, bp
        call hex8
        mov dx, msg_crlf
        call print
        mov ax, 4C03h
        int 21h
bad_free:
        mov dx, msg_free
        call print
        mov ax, [newoff]
        call hex16
        mov dx, msg_crlf
        call print
        mov ax, 4C04h
        int 21h

restore:
        call pci_sel
        mov dx, 0CFCh
        mov al, [saved]
        out dx, al
        xor eax, eax
        mov dx, 0CF8h
        out dx, eax
        ret
pci_sel:
        mov eax, PCIADR
        mov dx, 0CF8h
        out dx, eax
        ret
print:  mov ah, 9
        int 21h
        ret
hex16:  push ax
        mov al, ah
        call hex8
        pop ax
hex8:   push ax
        shr al, 4
        call hex4
        pop ax
hex4:   and al, 0Fh
        add al, '0'
        cmp al, '9'
        jbe .p
        add al, 7
.p:     mov dl, al
        mov ah, 2
        int 21h
        ret

saved   db 0
imgend  dw 0
found   dw 0
oldoff  dw 0
newoff  dw 0
wrreg   dw 0
rdreg   dw 0
; routine bytes 3..25: 00 / jz / mov dx,15D / mov ah,70 / call / call / test ah,80 / jz / loop / popa / ret
tail    db 00h,74h,12h,0BAh,5Dh,01h,0B4h,70h,0E8h,0,0,0E8h,0,0,0F6h,0C4h,80h,74h,0F8h,0E2h,0EEh,61h,0C3h
; replacement routine (position independent apart from the two calls)
tmpl:   pusha
        jcxz t_done
        xor di, di              ; 0 = chip timer answers
t_unit:  mov dx, 015Dh           ; sequencer register 5D
        mov ah, 70h
tmpl_c1: db 0E8h, 0, 0          ; call write-register: start the chip timer
        mov si, 8000h           ; full wait
        or di, di
        jz t_poll
        mov si, 0040h           ; timer is not visible: short fixed wait
t_poll:
tmpl_c2: db 0E8h, 0, 0          ; call read-register
        test ah, 80h
        jnz t_next
        dec si
        jnz t_poll
        inc di                  ; timed out
t_next:  loop t_unit
t_done:  popa
        ret
tmpl_end:
msg_title   db 'VX9FIX 1.2 - VIA VX900 video BIOS delay fix',13,10,'$'
msg_ok      db 'Patched: the delay at C000:$'
msg_ok2     db ' now times out.',13,10,'$'
msg_already db 'Already patched. Nothing to do.',13,10,'$'
msg_bad     db 'Not patched: no VIA VX900 video BIOS found at C000.',13,10,'$'
msg_code    db 'Not patched: delay routine not found exactly once. Matches: $'
msg_free    db 'Not patched: no blank room at the end of the video BIOS, C000:$'
msg_locked  db 'Not patched: video BIOS memory would not unlock. Register 80h was $'
msg_crlf    db 13,10,'$'
