@echo off
echo o 3d4 3e> C:\VX9.TXT
echo i 3d5>> C:\VX9.TXT
echo o 3d4 4d>> C:\VX9.TXT
echo i 3d5>> C:\VX9.TXT
echo o 3d4 3b>> C:\VX9.TXT
echo i 3d5>> C:\VX9.TXT
echo q>> C:\VX9.TXT
debug < C:\VX9.TXT > C:\VX9OUT.TXT
type C:\VX9OUT.TXT
echo.
echo Saved to C:\VX9OUT.TXT
