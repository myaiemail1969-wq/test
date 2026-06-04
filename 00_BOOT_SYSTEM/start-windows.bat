@echo off
:: =============================================================================
:: Project Aeria — Windows CLI Boot Script
:: Author:   Project Aeria
:: Version:  1.1.0
:: Purpose:  Launches llama-cli.exe for direct interactive use on Windows.
::           Uses relative paths — safe on any drive letter.
::           Volatile logs written to %TEMP%, never to source media.
:: Usage:    Double-click, or: start-windows.bat
:: =============================================================================
SETLOCAL EnableExtensions EnableDelayedExpansion

SET "AERIA_ROOT=%~dp0.."
SET "BIN=%~dp0bin\win\llama-cli.exe"
SET "BRAINS=%~dp0..\01_THE_BRAINS"
SET "PROMPT=%~dp0..\02_THE_COUNCIL\technical_sys.txt"
SET "LOGDIR=%TEMP%\aeria_logs"

echo.
echo ====================================================
echo  Project Aeria -- Offline Knowledge Node (Windows)
echo ====================================================
echo.

:: ---------------------------------------------------------------------------
:: Check binary
:: ---------------------------------------------------------------------------
IF NOT EXIST "%BIN%" (
    echo [ERROR] llama-cli.exe not found at:
    echo         %BIN%
    echo.
    echo  Place the Windows binary from llama.cpp releases into:
    echo  00_BOOT_SYSTEM\bin\win\llama-cli.exe
    echo.
    pause
    EXIT /B 1
)

:: ---------------------------------------------------------------------------
:: Model selection
:: ---------------------------------------------------------------------------
echo  Available model sizes:
echo.
echo  [1] Small  -- 2B-3B parameter  (Min ~4 GB RAM, fast on any hardware)
echo  [2] Large  -- 7B-8B parameter  (Min ~12 GB RAM, deeper reasoning)
echo.
SET "CHOICE=1"
SET /P "CHOICE=  Select [1-2] (default: 1, auto-selects in 15s): "

:: ---------------------------------------------------------------------------
:: Find model — scan all .gguf files, pick based on size preference
:: ---------------------------------------------------------------------------
SET "MODEL_PATH="

IF "!CHOICE!"=="2" GOTO FIND_LARGE
GOTO FIND_SMALL

:FIND_LARGE
FOR /F "delims=" %%F IN ('dir /b /s "%BRAINS%\*.gguf" 2^>nul') DO (
    echo %%F | findstr /i "7b 8b 13b 14b" >nul 2>&1
    IF NOT ERRORLEVEL 1 IF NOT DEFINED MODEL_PATH SET "MODEL_PATH=%%F"
)
IF DEFINED MODEL_PATH GOTO MODEL_FOUND

:FIND_SMALL
FOR /F "delims=" %%F IN ('dir /b /s "%BRAINS%\*.gguf" 2^>nul') DO (
    echo %%F | findstr /i "2b 3b 1b" >nul 2>&1
    IF NOT ERRORLEVEL 1 IF NOT DEFINED MODEL_PATH SET "MODEL_PATH=%%F"
)
IF DEFINED MODEL_PATH GOTO MODEL_FOUND

:: Fall back to any .gguf present
:FIND_ANY
FOR /F "delims=" %%F IN ('dir /b /s "%BRAINS%\*.gguf" 2^>nul') DO (
    IF NOT DEFINED MODEL_PATH SET "MODEL_PATH=%%F"
)

:MODEL_FOUND
IF NOT DEFINED MODEL_PATH (
    echo.
    echo [ERROR] No .gguf model found in:
    echo         %BRAINS%
    echo.
    echo  Download a model and place it in 01_THE_BRAINS\
    echo  Recommended: qwen2.5-7b-instruct-q4_k_m.gguf from huggingface.co
    echo.
    pause
    EXIT /B 1
)

:: ---------------------------------------------------------------------------
:: System prompt flag
:: ---------------------------------------------------------------------------
SET "PROMPT_FLAG="
IF EXIST "%PROMPT%" SET "PROMPT_FLAG=-f "%PROMPT%""

:: ---------------------------------------------------------------------------
:: Log directory
:: ---------------------------------------------------------------------------
IF NOT EXIST "%LOGDIR%" MKDIR "%LOGDIR%" 2>nul

:: ---------------------------------------------------------------------------
:: Launch
:: ---------------------------------------------------------------------------
echo.
echo  Model : !MODEL_PATH!
IF DEFINED PROMPT_FLAG (echo  Primer: %PROMPT%) ELSE (echo  Primer: [none found])
echo  Logs  : %LOGDIR%
echo.
echo ====================================================
echo  Ready. Type your question. Ctrl+C or /bye to exit.
echo ====================================================
echo.

"%BIN%" -m "!MODEL_PATH!" -c 4096 --color !PROMPT_FLAG! -ngl 99 --conversation

echo.
echo  Session ended.
pause
ENDLOCAL
