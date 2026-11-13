; VX9VDD.COM - patches a Windows 9x VDD for VIA VX900 boards. Runs under DOS.
;
;   VX9VDD input [output]
;
; input   VDD.VXD from the Windows CD, or VMM32.VXD from an installed Windows
;         (the VDD is taken out of it; W3 and W4 formats).
; output  the patched driver. Default: VDD.VXD in the current directory.
;         Copy it to C:\WINDOWS\SYSTEM\VMM32\VDD.VXD.
;
; The four patch sites are found by instruction pattern. If one is missing or
; found twice, the output is deleted and nothing is left behind.
;
; Build: nasm -f bin vx9vdd.asm -o VX9VDD.COM
; Copyright (c) 2026 360ALASKA. MIT License.

        cpu 386
        org 100h
BLK     equ 8192                ; W4 chunk size and copy block
SCN     equ 4096                ; scan block
OVL     equ 32                  ; scan overlap, at least the longest pattern
STUB    equ 80h                 ; MZ stub written in front of an extracted LE

start:  cld
        mov dx, m_title
        call print
        ; clear variables
        mov di, bss_start
        mov cx, bss_end - bss_start
        xor al, al
        rep stosb
        mov word [hin], -1
        mov word [hout], -1
        ; ---- command line ----
        mov si, 81h
        mov di, name_in
        call token
        cmp byte [name_in], 0
        je usage
        mov di, name_out
        call token
        cmp byte [name_out], 0
        jne .named
        mov si, def_out
        mov di, name_out
.cpy:   lodsb
        stosb
        or al, al
        jnz .cpy
.named: ; the output must not be the input: creating it would empty the input
        mov si, name_in
        mov di, name_out
.same:  lodsb
        mov ah, [di]
        inc di
        call upper
        xchg al, ah
        call upper
        cmp al, ah
        jne .diff
        or al, al
        jnz .same
        mov dx, m_same
        call print
        mov ax, 4C02h
        int 21h
.diff:  ; ---- open input, create output ----
        mov ax, 3D00h
        mov dx, name_in
        int 21h
        jc e_open
        mov [hin], ax
        mov bx, ax
        mov ax, 4202h           ; file size
        xor cx, cx
        xor dx, dx
        int 21h
        mov [fsize], ax
        mov [fsize+2], dx
        mov ah, 3Ch
        xor cx, cx
        mov dx, name_out
        int 21h
        jc e_create
        mov [hout], ax
        mov byte [made], 1
        ; ---- what kind of file ----
        mov bx, [hin]
        xor edx, edx
        call seek
        mov cx, 40h
        mov dx, iobuf
        call fread
        cmp ax, 40h
        jne e_type
        cmp word [iobuf], 'MZ'
        jne e_type
        mov eax, [iobuf+3Ch]
        mov [ne], eax
        mov edx, eax
        call seek
        mov cx, 16
        mov dx, iobuf
        call fread
        cmp ax, 16
        jne e_type
        mov ax, [iobuf]
        cmp ax, 'LE'
        je plain
        cmp ax, 'W3'
        je .w3
        cmp ax, 'W4'
        jne e_type
        cmp word [iobuf+4], BLK
        jne e_type
        mov byte [isw4], 1
        movzx eax, word [iobuf+6]
        mov [nblk], eax
        jmp vmm32
.w3:    mov eax, [fsize]        ; blocks = ceil((size - ne) / BLK)
        sub eax, [ne]
        add eax, BLK-1
        shr eax, 13
        mov [nblk], eax
        jmp vmm32

; ---- a standalone VxD: copy it to the output ----
plain:  mov bx, [hin]
        xor edx, edx
        call seek
.loop:  mov bx, [hin]
        mov cx, BLK
        mov dx, outbuf
        call fread
        or ax, ax
        jz patch
        mov cx, ax
        mov bx, [hout]
        mov dx, outbuf
        call fwrite
        jmp .loop

; ---- a VMM32.VXD: take the VDD out of it ----
vmm32:  mov dx, m_vmm32
        call print
        xor eax, eax
        call getblk             ; block 0 holds the directory
        cmp word [outbuf], 'W3'
        jne e_type
        mov cx, [outbuf+4]      ; entries
        cmp cx, 500
        ja e_type
        mov si, outbuf+16
        mov dword [vend], 0FFFFFFFFh
        push cx
        push si
.find:  jcxz .nov
        cmp dword [si], 'VDD '
        jne .nf
        cmp dword [si+4], '    '
        jne .nf
        mov eax, [si+8]
        mov [vstart], eax
        jmp .gotv
.nf:    add si, 16
        dec cx
        jmp .find
.nov:   pop si
        pop cx
        jmp e_novdd
.gotv:  pop si
        pop cx
.end:   jcxz .ended             ; smallest offset above the VDD's
        mov eax, [si+8]
        cmp eax, [vstart]
        jbe .ne
        cmp eax, [vend]
        jae .ne
        mov [vend], eax
.ne:    add si, 16
        dec cx
        jmp .end
.ended: cmp dword [vend], 0FFFFFFFFh
        jne .have
        mov eax, [nblk]
        shl eax, 13
        add eax, [ne]
        mov [vend], eax
.have:  mov eax, [vstart]       ; positions relative to the W3 header
        sub eax, [ne]
        mov [rs], eax
        mov eax, [vend]
        sub eax, [ne]
        mov [re], eax
        ; MZ stub
        mov di, outbuf
        mov cx, STUB
        xor al, al
        rep stosb
        mov word [outbuf], 'MZ'
        mov word [outbuf+18h], 40h
        mov dword [outbuf+3Ch], STUB
        mov bx, [hout]
        mov cx, STUB
        mov dx, outbuf
        call fwrite
        mov eax, [rs]
        mov [cur], eax
.blk:   mov eax, [cur]
        cmp eax, [re]
        jae .fix
        shr eax, 13
        call getblk
        mov eax, [cur]
        and eax, BLK-1          ; offset inside the block
        mov ecx, BLK
        sub ecx, eax            ; bytes left in the block
        mov edx, [re]
        sub edx, [cur]
        cmp ecx, edx
        jbe .n1
        mov ecx, edx
.n1:    add [cur], ecx
        lea dx, [outbuf]
        add dx, ax
        mov bx, [hout]
        call fwrite
        jmp .blk
.fix:   ; make the LE header fit a standalone file
        mov bx, [hout]
        mov edx, STUB
        call seek
        mov cx, 0C4h
        mov dx, iobuf
        call fread
        cmp ax, 0C4h
        jne e_type
        cmp word [iobuf], 'LE'
        jne e_type
        mov eax, [iobuf+80h]    ; data pages offset: from file start
        sub eax, [vstart]
        add eax, STUB
        mov [iobuf+80h], eax
        mov dword [iobuf+88h], 0 ; non-resident names are not carried over
        mov dword [iobuf+8Ch], 0
        mov ecx, [iobuf+14h]    ; file ends after the last page
        dec ecx
        imul ecx, [iobuf+28h]
        add ecx, [iobuf+2Ch]
        add eax, ecx
        mov [cur], eax
        mov edx, STUB
        call seek
        mov cx, 0C4h
        mov dx, iobuf
        call fwrite
        mov edx, [cur]
        call seek
        xor cx, cx              ; zero-length write: truncate here
        mov ah, 40h
        mov dx, iobuf
        int 21h

; ---- patch the output file in place ----
patch:  mov bx, [hout]
        mov ax, 4202h
        xor cx, cx
        xor dx, dx
        int 21h
        mov [osize], ax
        mov [osize+2], dx
        xor edx, edx
        call seek
        mov cx, 40h
        mov dx, iobuf
        call fread
        cmp ax, 40h
        jne e_type
        cmp word [iobuf], 'MZ'
        jne e_type
        mov eax, [iobuf+3Ch]
        mov [ne], eax
        mov edx, eax
        call seek
        mov cx, 0C4h
        mov dx, iobuf
        call fread
        cmp word [iobuf], 'LE'
        jne e_type
        mov eax, [iobuf+28h]
        mov [pagesz], eax
        mov eax, [iobuf+40h]
        add eax, [ne]
        mov [objtab], eax
        mov eax, [iobuf+44h]
        mov [nobj], eax
        mov eax, [iobuf+80h]
        mov [datapg], eax
        ; ---- scan for the patterns ----
        xor edx, edx
        call seek
        mov dword [sbase], 0
        mov word [carry], 0
.rd:    mov bx, [hout]
        mov cx, SCN
        mov dx, scanbuf
        add dx, [carry]
        call fread
        mov bp, ax              ; bytes read
        add ax, [carry]         ; total in buffer
        mov [total], ax
        or bp, bp
        jnz .more
        mov byte [last], 1
        mov di, scanbuf         ; last pass: pad with zeros, scan every position
        add di, ax
        mov cx, OVL
        xor al, al
        rep stosb
        mov cx, [total]
        jmp .scan
.more:  mov cx, [total]
        sub cx, OVL
        jbe .keep               ; not enough yet
.scan:  jcxz .after
        mov si, scanbuf
.pos:   push cx
        mov bx, pats
.pat:   mov cx, [bx]            ; length, 0 ends the table
        jcxz .nextpos
        push si
        mov di, [bx+2]          ; bytes
        mov bp, [bx+4]          ; mask
.cmp:   mov al, [si]
        xor al, [di]
        and al, [bp]
        jnz .miss
        inc si
        inc di
        inc bp
        loop .cmp
        pop si
        inc word [bx+6]         ; count
        mov eax, [sbase]
        movzx edx, si
        sub edx, scanbuf
        add eax, edx
        mov [bx+8], eax         ; file offset
        jmp .np
.miss:  pop si
.np:    add bx, 12
        jmp .pat
.nextpos:
        pop cx
        inc si
        loop .pos
.after: cmp byte [last], 0
        jne .scanned
        ; keep the last OVL bytes
        mov si, scanbuf
        add si, [total]
        sub si, OVL
        mov di, scanbuf
        mov cx, OVL
        rep movsb
        movzx eax, word [total]
        sub eax, OVL
        add [sbase], eax
        mov word [carry], OVL
        jmp .rd
.keep:  mov ax, [total]
        mov [carry], ax
        jmp .rd
.scanned:
        cmp word [p_done+6], 0
        jne e_done
        mov dx, m_s1
        mov bx, p_rd
        call need1
        mov dx, m_s2
        mov bx, p_wr
        call need1
        mov dx, m_s3
        mov bx, p_cr
        call need1
        mov dx, m_s4
        mov bx, p_pt
        call need1
        ; the port table must end at 3DF
        mov bx, [hout]
        mov edx, [p_pt+8]
        add edx, 2 + 6*31
        call seek
        mov cx, 2
        mov dx, iobuf
        call fread
        cmp word [iobuf], 03DFh
        jne e_site
        ; ---- the object that holds the sequencer code ----
        xor esi, esi            ; object index
.obj:   cmp esi, [nobj]
        jae e_site
        mov edx, esi
        imul edx, 24
        add edx, [objtab]
        mov [objent], edx
        mov bx, [hout]
        call seek
        mov cx, 24
        mov dx, iobuf
        call fread
        mov eax, [iobuf+12]     ; first page, 1-based
        dec eax
        imul eax, [pagesz]
        add eax, [datapg]
        mov [fbase], eax
        mov ecx, [iobuf]        ; virtual size
        mov [vsize], ecx
        mov edx, [p_rd+8]
        cmp edx, eax
        jb .nobj
        add ecx, eax
        cmp edx, ecx
        jb .gotobj
.nobj:  inc esi
        jmp .obj
.gotobj:
        mov edx, [p_wr+8]       ; the write site must be in the same object
        cmp edx, [fbase]
        jb e_site
        cmp edx, ecx
        jae e_site
        mov eax, [vsize]
        add eax, 15
        and eax, ~15
        mov [c1], eax
        add eax, cave1_len + 15
        and eax, ~15
        mov [c2], eax
        add eax, cave2_len
        mov [cend], eax
        mov ecx, [iobuf+16]     ; pages
        imul ecx, [pagesz]
        cmp eax, ecx
        ja e_room
        add eax, [fbase]
        cmp eax, [osize]
        ja e_room
        ; the room after the code must be blank
        mov bx, [hout]
        mov edx, [fbase]
        add edx, [vsize]
        call seek
        mov ecx, [cend]
        sub ecx, [vsize]
        add cx, 4
        push cx
        mov dx, outbuf
        call fread
        pop cx
        cmp ax, cx
        jb .rchk                ; short read at end of file: check what there is
        mov ax, cx
.rchk:  mov cx, ax
        mov si, outbuf
.z:     jcxz .blank
        lodsb
        or al, al
        jnz e_room
        dec cx
        jmp .z
.blank: ; ---- build the write cave ----
        mov eax, [p_wr+8]
        sub eax, [fbase]
        mov [wro], eax
        mov edx, [p_wr+8]
        add edx, 5
        mov bx, [hout]
        call seek
        mov cx, 1
        mov dx, iobuf
        call fread
        movsx eax, byte [iobuf]
        mov ecx, [wro]
        add ecx, 6
        mov [cont], ecx         ; original path continues here
        add eax, ecx
        mov [drop], eax         ; original 'discard' target
        mov eax, [cont]
        sub eax, [c2]
        sub eax, 15
        mov [cave2+11], eax
        mov eax, [drop]
        sub eax, [c2]
        sub eax, 20
        mov [cave2+16], eax
        mov eax, [drop]
        sub eax, [c2]
        sub eax, cave2_len
        mov [cave2+cave2_len-4], eax
        ; ---- write everything ----
        mov edx, [fbase]
        add edx, [c1]
        mov si, cave1
        mov cx, cave1_len
        call putat
        mov edx, [fbase]
        add edx, [c2]
        mov si, cave2
        mov cx, cave2_len
        call putat
        ; read site: jmp cave1 / nop / nop
        mov eax, [p_rd+8]
        sub eax, [fbase]        ; offset in object
        mov ecx, [c1]
        sub ecx, eax
        sub ecx, 5
        mov byte [iobuf], 0E9h
        mov [iobuf+1], ecx
        mov word [iobuf+5], 9090h
        mov edx, [p_rd+8]
        mov si, iobuf
        mov cx, 7
        call putat
        ; write site: (push eax) jmp cave2
        mov ecx, [c2]
        sub ecx, [wro]
        sub ecx, 6
        mov byte [iobuf], 0E9h
        mov [iobuf+1], ecx
        mov edx, [p_wr+8]
        inc edx
        mov si, iobuf
        mov cx, 5
        call putat
        ; CRTC site: jbe -> jmp
        mov byte [iobuf], 0EBh
        mov edx, [p_cr+8]
        add edx, 3
        mov si, iobuf
        mov cx, 1
        call putat
        ; port table: slot of 3C3 holds 3DF, 31 entries
        mov word [iobuf], 03DFh
        mov edx, [p_pt+8]
        add edx, 2 + 18
        mov si, iobuf
        mov cx, 2
        call putat
        mov word [iobuf], 001Fh
        mov edx, [p_pt+8]
        mov si, iobuf
        mov cx, 2
        call putat
        ; object size now covers the new code
        mov eax, [cend]
        mov [iobuf], eax
        mov edx, [objent]
        mov si, iobuf
        mov cx, 4
        call putat
        mov byte [made], 0      ; keep the output
        call closeall
        mov dx, m_ok
        call print
        mov dx, name_out
        call printz
        mov dx, m_crlf
        call print
        mov ax, 4C00h
        int 21h

; ---- subroutines ----
need1:  cmp word [bx+6], 1      ; pattern at BX must be found exactly once
        je .ok
        push dx
        mov dx, m_site
        call print
        pop dx
        call print
        jmp fail
.ok:    ret

putat:  push si                 ; write CX bytes from SI at file offset EDX
        push cx
        mov bx, [hout]
        call seek
        pop cx
        pop dx
        jmp fwrite

seek:   push eax                ; BX handle, EDX position
        push ecx
        push edx
        mov ecx, edx
        shr ecx, 16
        mov ax, 4200h
        int 21h
        pop edx
        pop ecx
        pop eax
        ret
fread:  mov ah, 3Fh             ; BX handle, CX count, DX buffer -> AX
        int 21h
        jc e_io
        ret
fwrite: jcxz .n
        mov ah, 40h
        int 21h
        jc e_io
        cmp ax, cx
        jne e_io
.n:     ret
print:  mov ah, 9
        int 21h
        ret
printz: mov si, dx
.l:     lodsb
        or al, al
        jz .d
        mov dl, al
        mov ah, 2
        int 21h
        jmp .l
.d:     ret
token:  lodsb                   ; next blank-delimited word from SI to DI
        cmp al, ' '
        je token
        cmp al, 9
        je token
.c:     cmp al, 0Dh
        je .e
        cmp al, ' '
        je .e
        cmp al, 9
        je .e
        or al, al
        jz .e
        stosb
        lodsb
        jmp .c
.e:     dec si
        xor al, al
        stosb
        ret
upper:  cmp al, 'a'
        jb .u
        cmp al, 'z'
        ja .u
        sub al, 20h
.u:     ret
closeall:
        mov bx, [hin]
        cmp bx, -1
        je .a
        mov ah, 3Eh
        int 21h
.a:     mov bx, [hout]
        cmp bx, -1
        je .b
        mov ah, 3Eh
        int 21h
.b:     ret

; ---- one 8 KB block of the W3 image into outbuf. EAX = block number ----
getblk: pushad
        mov [blkno], eax
        mov di, outbuf
        mov cx, BLK
        xor al, al
        rep stosb
        cmp byte [isw4], 0
        jne .w4
        mov edx, [blkno]
        shl edx, 13
        add edx, [ne]
        mov bx, [hin]
        call seek
        mov cx, BLK
        mov dx, outbuf
        call fread
        popad
        ret
.w4:    mov edx, [blkno]        ; chunk offsets: dwords after the 16-byte header
        shl edx, 2
        add edx, [ne]
        add edx, 16
        mov bx, [hin]
        call seek
        mov cx, 8
        mov dx, iobuf
        call fread
        mov eax, [blkno]
        inc eax
        cmp eax, [nblk]
        jb .mid
        mov eax, [fsize]        ; last chunk runs to the end of the file
        mov [iobuf+4], eax
.mid:   mov ecx, [iobuf+4]
        sub ecx, [iobuf]
        cmp ecx, BLK
        ja e_w4
        push cx
        mov edx, [iobuf]
        call seek
        mov di, inbuf
        mov cx, BLK+16
        xor al, al
        rep stosb
        pop cx
        push cx
        mov dx, inbuf
        call fread
        pop cx
        cmp cx, BLK
        jb .lz
        mov si, inbuf           ; stored, not compressed
        mov di, outbuf
        rep movsb
        popad
        ret
.lz:    xor esi, esi            ; bit position in inbuf
        xor di, di              ; bytes produced
.next:  cmp di, BLK
        jae .done
        mov cl, 2
        call getbits
        cmp al, 2
        je .lit
        cmp al, 1
        je .lith
        or al, al
        jnz .long
        mov cl, 6               ; 00: 6-bit offset, 0 ends the chunk
        call getbits
        or ax, ax
        jz .done
        jmp .len
.long:  mov cl, 1
        call getbits
        or al, al
        jnz .l12
        mov cl, 8
        call getbits
        add ax, 64
        jmp .len
.l12:   mov cl, 12
        call getbits
        add ax, 320
        cmp ax, 4415            ; sector marker
        je .next
.len:   mov bp, ax              ; BP = offset
        xor dx, dx              ; count zero bits
.g:     mov cl, 1
        call getbits
        or al, al
        jnz .g1
        inc dx
        cmp dx, 13
        ja e_w4
        jmp .g
.g1:    mov cl, dl
        call getbits
        mov bx, 1
        mov cl, dl
        shl bx, cl
        add ax, bx
        inc ax                  ; length = (1<<n) + bits + 1
        cmp bp, di
        ja e_w4
        mov cx, ax
.cp:    cmp di, BLK
        jae .done
        mov bx, di
        sub bx, bp
        mov al, [outbuf+bx]
        mov [outbuf+di], al
        inc di
        loop .cp
        jmp .next
.lith:  mov cl, 7
        call getbits
        or al, 80h
        jmp .put
.lit:   mov cl, 7
        call getbits
.put:   mov [outbuf+di], al
        inc di
        jmp .next
.done:  popad
        ret

getbits:
        push ebx                ; CL bits from the stream -> EAX
        push edx
        mov dl, cl
        mov ebx, esi
        shr ebx, 3
        mov eax, [inbuf+bx]
        mov cx, si
        and cl, 7
        shr eax, cl
        mov cl, dl
        mov ebx, 1
        shl ebx, cl
        dec ebx
        and eax, ebx
        movzx ebx, dl
        add esi, ebx
        pop edx
        pop ebx
        ret

; ---- errors ----
usage:  mov dx, m_usage
        call print
        mov ax, 4C02h
        int 21h
e_open: mov dx, m_open
        jmp failm
e_create:
        mov dx, m_create
        jmp failm
e_io:   mov dx, m_io
        jmp failm
e_type: mov dx, m_type
        jmp failm
e_novdd:
        mov dx, m_novdd
        jmp failm
e_w4:   mov dx, m_w4
        jmp failm
e_done: mov dx, m_done
        jmp failm
e_site: mov dx, m_site
        call print
        mov dx, m_s0
        jmp failm
e_room: mov dx, m_room
failm:  call print
fail:   call closeall
        cmp byte [made], 0
        je .x
        mov ah, 41h             ; do not leave a half-made output behind
        mov dx, name_out
        int 21h
.x:     mov ax, 4C01h
        int 21h

; ---- data ----
def_out db 'VDD.VXD', 0
; pattern table: length, bytes, mask, count, file offset (12 bytes each)
pats:
p_rd    dw 7,  b_rd, k_rd, 0
        dd 0
p_wr    dw 10, b_wr, k_wr, 0
        dd 0
p_cr    dw 13, b_cr, k_cr, 0
        dd 0
p_pt    dw 22, b_pt, k_pt, 0
        dd 0
p_done  dw cave1_len, cave1, k_all, 0
        dd 0
        dw 0
b_rd    db 8Ah,44h,39h,66h,0EBh,0,90h                    ; mov al,[ecx+edi+66h] / jmp short / nop
k_rd    db 0FFh,0FFh,0FFh,0FFh,0FFh,0,0FFh
b_wr    db 50h,80h,0F9h,0Fh,77h,0,38h,44h,39h,66h         ; push eax / cmp cl,0Fh / ja / cmp [ecx+edi+66h],al
k_wr    db 0FFh,0FFh,0FFh,0FFh,0FFh,0,0FFh,0FFh,0FFh,0FFh
b_cr    db 80h,0F9h,18h,76h,0,0FEh,0CAh,8Ah,0E0h,8Ah,0C1h,66h,0EFh
k_cr    db 0FFh,0FFh,0FFh,0FFh,0,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh,0FFh
b_pt    db 20h,0,0C0h,3, 0,0,0,0, 0C1h,3, 0,0,0,0, 0C2h,3, 0,0,0,0, 0C3h,3
k_pt    db 0FFh,0FFh,0FFh,0FFh, 0,0,0,0, 0FFh,0FFh, 0,0,0,0, 0FFh,0FFh, 0,0,0,0, 0FFh,0FFh
k_all   times 32 db 0FFh
; extended sequencer read: take the value from the chip, keeping the chip's index
cave1   db 80h,0F9h,0Fh, 77h,05h, 8Ah,44h,0Fh,66h, 0C3h
        db 4Ah, 0ECh, 88h,0C5h, 88h,0C8h, 0EEh, 42h, 0ECh, 86h,0E8h, 4Ah, 0EEh, 42h, 88h,0E8h, 0C3h
cave1_len equ $ - cave1
; sequencer write from a VM that does not own the hardware: pass index 5D only
cave2   db 80h,0F9h,5Dh, 74h,0Fh, 80h,0F9h,0Fh, 77h,05h
        db 0E9h, 0,0,0,0                                  ; jmp original path
        db 0E9h, 0,0,0,0                                  ; jmp discard
        db 88h,0C5h, 4Ah, 0ECh, 50h, 88h,0C8h, 0EEh, 42h, 88h,0E8h, 0EEh, 4Ah, 58h, 0EEh, 42h
        db 0E9h, 0,0,0,0                                  ; jmp discard
cave2_len equ $ - cave2

m_title db 'VX9VDD 1.0 - Windows 9x VDD patch for VIA VX900 boards', 13, 10, '$'
m_usage db 'Usage: VX9VDD input [output]', 13, 10
        db '  input   VDD.VXD from the Windows CD, or VMM32.VXD from', 13, 10
        db '          C:\WINDOWS\SYSTEM of an installed Windows', 13, 10
        db '  output  patched file, default VDD.VXD in this directory', 13, 10
        db 'Copy the output to C:\WINDOWS\SYSTEM\VMM32\VDD.VXD', 13, 10, '$'
m_vmm32 db 'VMM32.VXD: taking the VDD out of it', 13, 10, '$'
m_ok    db 'Patched. Copy this file to C:\WINDOWS\SYSTEM\VMM32\VDD.VXD: $'
m_same  db 'The output file must not be the input file.', 13, 10, '$'
m_open  db 'Cannot open the input file.', 13, 10, '$'
m_create db 'Cannot create the output file.', 13, 10, '$'
m_io    db 'Disk read or write error.', 13, 10, '$'
m_type  db 'The input is not a VxD or a VMM32.VXD.', 13, 10, '$'
m_novdd db 'This VMM32.VXD holds no VDD. Use VDD.VXD from the Windows CD.', 13, 10, '$'
m_w4    db 'The VMM32.VXD is damaged or in an unknown format.', 13, 10, '$'
m_done  db 'This VDD is already patched.', 13, 10, '$'
m_room  db 'Not patched: no blank room after the code.', 13, 10, '$'
m_site  db 'Not patched: this VDD build is not supported. Not found exactly once: $'
m_s0    db 'code layout', 13, 10, '$'
m_s1    db 'sequencer read', 13, 10, '$'
m_s2    db 'sequencer write', 13, 10, '$'
m_s3    db 'CRTC write', 13, 10, '$'
m_s4    db 'port table', 13, 10, '$'
m_crlf  db 13, 10, '$'

        section .bss
bss_start:
hin     resw 1
hout    resw 1
made    resb 1
isw4    resb 1
last    resb 1
        resb 1
carry   resw 1
total   resw 1
fsize   resd 1
osize   resd 1
ne      resd 1
nblk    resd 1
blkno   resd 1
vstart  resd 1
vend    resd 1
rs      resd 1
re      resd 1
cur     resd 1
pagesz  resd 1
objtab  resd 1
nobj    resd 1
datapg  resd 1
sbase   resd 1
objent  resd 1
fbase   resd 1
vsize   resd 1
c1      resd 1
c2      resd 1
cend    resd 1
wro     resd 1
cont    resd 1
drop    resd 1
name_in resb 128
name_out resb 128
bss_end:
iobuf   resb 256
inbuf   resb BLK+16
outbuf  resb BLK
scanbuf resb SCN+OVL+OVL
