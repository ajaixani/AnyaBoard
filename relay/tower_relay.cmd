@echo off
REM Double-click or run from cmd.exe — no Python, no WSL, no Store.
REM Edit BOARD and OUT below if needed, then run this file on the tower.

set BOARD=http://192.168.1.10:8787
REM IMPORTANT: set OUT to the CET mod folder inside Cyberpunk install
set OUT=D:\SteamLibrary\steamapps\common\Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\AnyaBoard\state.json

echo [tower_relay.cmd] board=%BOARD%
echo [tower_relay.cmd] out=%OUT%
echo Edit this .cmd if paths are wrong. Ctrl+C to stop.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tower_relay.ps1" -Board "%BOARD%" -Out "%OUT%"
if errorlevel 1 pause
