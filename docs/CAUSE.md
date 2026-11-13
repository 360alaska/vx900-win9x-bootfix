# Cause and fix in detail

## What the video BIOS does

Addresses are from the VX900 video BIOS dated 09/01/11 (version 19). The version dated 08/16/10 has the same routine at `C000:6A62`.

```
C000:64EC  pusha
           cmp  cx,0
           jz   done
unit:      mov  dx,015Dh        ; sequencer register 5D
           mov  ah,70h
           call write_reg       ; start the chip timer
poll:      call read_reg
           test ah,80h
           jz   poll            ; no time limit
           loop unit
done:      popa
           ret
```

When CRTC register `3E` has bit 1 or bit 2 set, every mode set calls this routine nine times. Both tested boards read `CR3E = 0F`. The VX855 video BIOS has the same routine but does not take that path.

The BIOS also reads port `3C3` about 145,000 times per mode set as a delay loop, and makes about 27,000 sequencer register accesses.

## What the stock VDD does

For the sequencer data port (`3C5`), when the virtual machine does not own the hardware (Windows 98 SE, code object 15):

```
write:  push eax
        cmp  cl,0Fh
        ja   discard            ; index above 0F: thrown away
        ...
read:   mov  al,[ecx+edi+66h]   ; index above 0F: reads past the 16-entry shadow
```

So the write that starts the timer is discarded, and the read returns an unrelated byte of the VDD's own per-VM data. If bit 7 of that byte is clear, the BIOS loop never ends.

Windows runs the video BIOS inside a virtual machine at these points:

1. `Device_Init` of the VDD: mode `10h`, then `AX=1202h` and mode `03h`.
2. When `DISPLAY.DRV` enables: its font query makes `IO.SYS` close the boot logo with `AX=0083h`.
3. When a DOS window opens: `AX=1202h`, then `AX=0003h`.

## The changes

All four are found by instruction pattern. The same code is present in the Windows 95 OSR2, 98 SE and Me VDDs at different addresses.

### 1. Extended sequencer reads come from the chip

The fallback `mov al,[ecx+edi+66h]` becomes a jump to new code placed in the blank space after the code object:

```
        cmp  cl,0Fh
        ja   real
        mov  al,[edi+ecx+66h]   ; standard registers: the shadow, as before
        ret
real:   dec  edx
        in   al,dx              ; keep the chip's index
        mov  ch,al
        mov  al,cl
        out  dx,al
        inc  edx
        in   al,dx              ; the real value
        xchg ch,al
        dec  edx
        out  dx,al              ; put the index back
        inc  edx
        mov  al,ch
        ret
```

### 2. The timer write reaches the chip

In the non-owner write path, index `5D` alone is passed to the chip, again saving and restoring the chip's index. Every other extended write from such a virtual machine is still discarded.

### 3. Extended CRTC writes are held back while detached

The stock VDD passes CRTC indexes above `18` to the hardware even while the owning virtual machine is detached from it. The VX900 BIOS writes dozens of those per mode set, which made the logo jump between resolutions during start-up. One `jbe` becomes `jmp` so those writes are held back in that state only. Full-screen DOS sessions take a different branch and are unchanged.

### 4. Port 3C3 is not trapped

The VDD's handler for port `3C3` only passes the access through. Removing the port from the trapped-port table (32 entries become 31) lets the BIOS delay loop run at full speed. With the port trapped, a DOS window took 5 to 7 seconds to open.

## What did not work, or was not needed

- **`Logo=0` in MSDOS.SYS.** Windows can start, because nothing has to close the logo, but DOS windows still lock.
- **Skipping the VDD's start-up mode calls.** Reaches the desktop, but does nothing for DOS windows.
- **Forcing VMPOLL's fallback path.** Got past a stall at VMPOLL, and stopped keyboard input in DOS windows. Not needed with the fix.
- **Renaming HSFLOP.PDR.** Not needed with the fix.
- **Giving the BIOS timer loop a timeout in shadow RAM** (`extras/VX9FIX.ASM`). The hard lock became a recoverable crash, because the BIOS then went on to calculate from junk register values. Not needed with the fix.
- **A stall at `C000:5EE1` seen when the video ROM is run in an emulator.** Not the cause. That loop scans the font-override list reached through `40:A8`, which points at garbage if the ROM is swapped in without running its start-up code.

## Notes for anyone repeating this

- A file in `C:\WINDOWS\SYSTEM\VMM32` overrides the copy packed inside `VMM32.VXD`.
- `VMM32.VXD` on Windows 98 and Me is in W4 format: 8 KB chunks compressed with the DoubleSpace bit stream. On the Windows 95 CD it is plain W3 and holds only VMM. `vx9vdd.py` reads both.
- Windows keeps a cached video ROM image on disk that may come from a different machine. Dump `C000` from the running board before working by address.
