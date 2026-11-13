@echo off
echo n C:\VX9ROM.BIN> C:\VX9D.TXT
echo r bx>> C:\VX9D.TXT
echo 1>> C:\VX9D.TXT
echo r cx>> C:\VX9D.TXT
echo 0>> C:\VX9D.TXT
echo w C000:0>> C:\VX9D.TXT
echo q>> C:\VX9D.TXT
debug < C:\VX9D.TXT > NUL
echo Saved 64 KB of video BIOS memory to C:\VX9ROM.BIN
