@echo off
rem `neolink [folder] [files]`: opens NeoLink without keeping the terminal waiting.
start "" "%~dp0..\NeoLink.exe" %*
