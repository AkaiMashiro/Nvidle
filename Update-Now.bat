@echo off
chcp 65001 >nul
title NVIDIA Driver Updater
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Nvidle.ps1" -Mode Update
