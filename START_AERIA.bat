@echo off
:: =============================================================================
:: Project Aeria — Root Launcher
:: Drop this at the ROOT of the drive (e.g. D:\START_AERIA.bat)
:: Double-click to boot the Council.
:: =============================================================================
SETLOCAL EnableExtensions

:: Find aeria directory relative to this file's location
SET "DRIVE=%~dp0"
SET "AERIA=%~dp0aeria"

IF NOT EXIST "%AERIA%\00_BOOT_SYSTEM\start-windows.bat" (
    echo.
    echo [ERROR] Cannot find aeria\ folder on this drive.
    echo         Expected: %AERIA%\00_BOOT_SYSTEM\start-windows.bat
    echo.
    echo  Make sure the aeria\ folder is in the same location as this file.
    echo.
    pause
    EXIT /B 1
)

call "%AERIA%\00_BOOT_SYSTEM\start-windows.bat"
ENDLOCAL
