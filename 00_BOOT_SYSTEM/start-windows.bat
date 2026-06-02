@echo off
:: =============================================================================
:: Project Aeria — Windows CLI Boot Script
:: Author:   Project Aeria
:: Version:  1.0.0
:: Modified: YYYY-MM-DD
:: Purpose:  Launches llama-cli.exe for direct interactive use on Windows.
::           Uses relative paths throughout — safe on read-only media.
::           All volatile data (logs, temp context) is written to %TEMP%.
:: Usage:    Double-click, or run from cmd: start-windows.bat
:: =============================================================================
SETLOCAL EnableExtensions EnableDelayedExpansion

echo.
echo ====================================================
echo  Project Aeria -- Offline Knowledge Node (Windows)
echo ====================================================
echo.

:: ---------------------------------------------------------------------------
:: Resolve paths relative to this script's directory
:: ---------------------------------------------------------------------------
SET "AERIA_ROOT=%~dp0.."
SET "BIN=%~dp0bin\win\llama-cli.exe"
SET "BRAINS=%AERIA_ROOT%\01_THE_BRAINS"
SET "PROMPT=%AERIA_ROOT%\02_THE_COUNCIL\technical_sys.txt"
SET "LOGDIR=%TEMP%\aeria_logs"

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
SET /P CHOICE="  Select [1-2] (default: 1, auto-selects in 15s): "

:: Auto-detect model based on choice — prefer Q5_K_M, fall back to Q4_K_M
SET "MODEL_PATH="

IF "%CHOICE%"=="2" (
    FOR /F "delims=" %%F IN ('dir /b /s "%BRAINS%\*Q5_K_M*.gguf" 2^>nul ^| findstr /i "7b\|8b\|13b" ^| sort') DO (
        IF NOT DEFINED MODEL_PATH SET "MODEL_PATH=%%F"
    )
    IF NOT DEFINED MODEL_PATH (
        FOR /F "delims=" %%F IN ('dir /b /s "%BRAINS%\*Q4_K_M*.gguf" 2^>nul ^| findstr /i "7b\|8b\|13b" ^| sort') DO (
            IF NOT DEFINED MODEL_PATH SET "MODEL_PATH=%%F"
        )
    )
)

:: Fall back to any available GGUF if specific size not found
IF NOT DEFINED MODEL_PATH (
    FOR /F "delims=" %%F IN ('dir /b /s "%BRAINS%\*Q5_K_M*.gguf" 2^>nul ^| sort') DO (
        IF NOT DEFINED MODEL_PATH SET "MODEL_PATH=%%F"
    )
)
IF NOT DEFINED MODEL_PATH (
    FOR /F "delims=" %%F IN ('dir /b /s "%BRAINS%\*Q4_K_M*.gguf" 2^>nul ^| sort') DO (
        IF NOT DEFINED MODEL_PATH SET "MODEL_PATH=%%F"
    )
)
IF NOT DEFINED MODEL_PATH (
    FOR /F "delims=" %%F IN ('dir /b /s "%BRAINS%\*.gguf" 2^>nul ^| sort') DO (
        IF NOT DEFINED MODEL_PATH SET "MODEL_PATH=%%F"
    )
)

IF NOT DEFINED MODEL_PATH (
    echo.
    echo [ERROR] No .gguf model found in:
    echo         %BRAINS%
    echo.
    echo  Add a quantized model (Q4_K_M or Q5_K_M recommended) and retry.
    pause
    EXIT /B 1
)

:: ---------------------------------------------------------------------------
:: Check system prompt
:: ---------------------------------------------------------------------------
SET "PROMPT_FLAG="
IF EXIST "%PROMPT%" (
    SET "PROMPT_FLAG=-f "%PROMPT%""
) ELSE (
    echo [WARN ] System prompt not found at %PROMPT% -- running without primer.
)

:: ---------------------------------------------------------------------------
:: Ensure log directory exists in %TEMP% (never writes to source media)
:: ---------------------------------------------------------------------------
IF NOT EXIST "%LOGDIR%" MKDIR "%LOGDIR%"

:: ---------------------------------------------------------------------------
:: Launch
:: ---------------------------------------------------------------------------
echo.
echo  Model    : %MODEL_PATH%
echo  Endpoint : local (CLI mode -- no server)
echo  Logs     : %LOGDIR%
echo.
echo ====================================================
echo  Type your question. Type /bye to exit.
echo ====================================================
echo.

"%BIN%" ^
    -m "%MODEL_PATH%" ^
    -c 4096 ^
    --color ^
    %PROMPT_FLAG% ^
    -ngl 99 ^
    -i ^
    -r "User:" ^
    >> "%LOGDIR%\session_%DATE:~-4,4%%DATE:~-7,2%%DATE:~0,2%.log" 2>&1

echo.
echo [AEGIS] Session ended.
pause
ENDLOCAL
