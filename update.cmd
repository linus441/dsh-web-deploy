@echo off
title DSH Web Updater
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"
pause
