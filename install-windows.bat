@echo off
:: =============================================================================
:: Project Aeria — Windows Drive Installer
:: Author:   Project Aeria
:: Version:  1.0.0
:: Modified: YYYY-MM-DD
:: Purpose:  One-shot setup script for D:\AEGIS (or any target path).
::           Clones the repo, creates directory structure, installs Python
::           dependencies, downloads llamafile, and prints what still needs
::           to be done manually (model weights).
:: Usage:    install-windows.bat
::           install-windows.bat D:\AEGIS     (explicit path)
:: =============================================================================
SETLOCAL EnableExtensions EnableDelayedExpansion

:: ---------------------------------------------------------------------------
:: Target path — edit here or pass as argument
:: ---------------------------------------------------------------------------
SET "TARGET=D:\AEGIS"
IF NOT "%~1"=="" SET "TARGET=%~1"

SET "REPO_URL=https://github.com/myaiemail1969-wq/test"
SET "REPO_BRANCH=claude/aeria-system-prompt-khwmY"
SET "LLAMAFILE_URL=https://github.com/Mozilla-Ocho/llamafile/releases/latest/download/llamafile.exe"
SET "LLAMA_CPP_RELEASES=https://github.com/ggerganov/llama.cpp/releases"

echo.
echo ====================================================
echo  Project Aeria -- Drive Installer (Windows)
echo  Target: %TARGET%
echo ====================================================
echo.

:: ---------------------------------------------------------------------------
:: Check prerequisites
:: ---------------------------------------------------------------------------
echo [1/7] Checking prerequisites...

SET MISSING=0

where git >nul 2>&1
IF ERRORLEVEL 1 (
    echo  [FAIL] git not found.
    echo         Install from: https://git-scm.com/download/win
    SET MISSING=1
) ELSE (
    FOR /F "tokens=3" %%V IN ('git --version') DO echo  [OK]   git %%V
)

where python >nul 2>&1
IF ERRORLEVEL 1 (
    echo  [FAIL] python not found.
    echo         Install from: https://www.python.org (3.10 or newer)
    SET MISSING=1
) ELSE (
    FOR /F "tokens=2" %%V IN ('python --version 2^>^&1') DO echo  [OK]   Python %%V
)

where curl >nul 2>&1
IF ERRORLEVEL 1 (
    echo  [WARN] curl not found -- binary download will be skipped.
    echo         curl is built into Windows 10/11. Update Windows if missing.
) ELSE (
    echo  [OK]   curl found
)

IF "%MISSING%"=="1" (
    echo.
    echo  Prerequisites missing. Install them and re-run this script.
    pause
    EXIT /B 1
)

:: ---------------------------------------------------------------------------
:: Create target directory
:: ---------------------------------------------------------------------------
echo.
echo [2/7] Creating directory structure at %TARGET%...

IF NOT EXIST "%TARGET%" MKDIR "%TARGET%"

SET "DIRS=00_BOOT_SYSTEM 01_THE_BRAINS 02_THE_COUNCIL 03_THE_ARCHIVES 04_THE_SCOUT 05_USER_ADDITIONS 06_PERSONAL_VAULT"
FOR %%D IN (%DIRS%) DO (
    IF NOT EXIST "%TARGET%\%%D" (
        MKDIR "%TARGET%\%%D"
        echo  [OK]   Created %%D\
    ) ELSE (
        echo  [OK]   %%D\ exists
    )
)

:: Bin subdirectories for llama-cli
MKDIR "%TARGET%\00_BOOT_SYSTEM\bin\win"   2>nul
MKDIR "%TARGET%\00_BOOT_SYSTEM\bin\linux" 2>nul
MKDIR "%TARGET%\00_BOOT_SYSTEM\bin\mac"   2>nul

:: Scout subdirectories
MKDIR "%TARGET%\05_USER_ADDITIONS\logs"   2>nul

:: ---------------------------------------------------------------------------
:: Clone or update the repo
:: ---------------------------------------------------------------------------
echo.
echo [3/7] Getting Aeria code...

IF EXIST "%TARGET%\.git" (
    echo  Repo already exists — pulling latest...
    git -C "%TARGET%" fetch origin %REPO_BRANCH% 2>&1
    git -C "%TARGET%" checkout %REPO_BRANCH% 2>&1
    git -C "%TARGET%" pull origin %REPO_BRANCH% 2>&1
    echo  [OK]   Code updated.
) ELSE (
    IF EXIST "%TARGET%\00_BOOT_SYSTEM\startup.sh" (
        echo  [OK]   Code already present (no git). Skipping clone.
    ) ELSE (
        echo  Cloning from %REPO_URL% ...
        git clone --branch %REPO_BRANCH% %REPO_URL% "%TARGET%"
        IF ERRORLEVEL 1 (
            echo  [FAIL] Clone failed. Check your internet connection.
            pause
            EXIT /B 1
        )
        echo  [OK]   Cloned.
    )
)

:: ---------------------------------------------------------------------------
:: Install Python dependencies
:: ---------------------------------------------------------------------------
echo.
echo [4/7] Installing Python dependencies...

python -m pip install --quiet pdfplumber
IF ERRORLEVEL 1 (
    echo  [WARN] pdfplumber install failed. Try manually: pip install pdfplumber
) ELSE (
    echo  [OK]   pdfplumber installed
)

python -m pip install --quiet Pillow 2>nul
IF ERRORLEVEL 1 (
    echo  [INFO] Pillow not installed (optional -- needed for image auto-resize)
) ELSE (
    echo  [OK]   Pillow installed (image auto-resize enabled)
)

:: ---------------------------------------------------------------------------
:: Download llamafile binary
:: ---------------------------------------------------------------------------
echo.
echo [5/7] Downloading llamafile binary...

SET "LLAMAFILE_DEST=%TARGET%\00_BOOT_SYSTEM\llamafile.exe"
IF EXIST "%LLAMAFILE_DEST%" (
    echo  [OK]   llamafile.exe already present -- skipping download.
) ELSE (
    echo  Downloading from GitHub releases...
    curl -L --progress-bar -o "%LLAMAFILE_DEST%" "%LLAMAFILE_URL%"
    IF ERRORLEVEL 1 (
        echo  [WARN] Download failed. Get it manually:
        echo         https://github.com/Mozilla-Ocho/llamafile/releases
        echo         Place as: %LLAMAFILE_DEST%
    ) ELSE (
        echo  [OK]   llamafile.exe downloaded.
    )
)

:: ---------------------------------------------------------------------------
:: Remind about manual downloads
:: ---------------------------------------------------------------------------
echo.
echo [6/7] Manual downloads required (models and llama-cli)...
echo.
echo  The following files are too large to download automatically.
echo  Download them now and place them in the locations shown.
echo.
echo  ── Language Models (choose at least one) ────────────────────
echo.
echo  RECOMMENDED (7B -- needs ~8 GB RAM):
echo    Search Hugging Face for: Qwen2.5-7B-Instruct GGUF
echo    File to download:        qwen2.5-7b-instruct-q4_k_m.gguf
echo    Place at: %TARGET%\01_THE_BRAINS\
echo    Size: ~4.7 GB
echo.
echo  FALLBACK (2B -- runs on anything):
echo    Search Hugging Face for: gemma-2-2b-it GGUF
echo    File to download:        gemma-2-2b-it-q4_k_m.gguf
echo    Place at: %TARGET%\01_THE_BRAINS\
echo    Size: ~1.5 GB
echo.
echo  ── Vision Model (optional) ───────────────────────────────────
echo.
echo    Search Hugging Face for: moondream2 GGUF
echo    Files to download:       moondream2 model file (.gguf)
echo                             mmproj file (starts with mmproj)
echo    Place BOTH at: %TARGET%\04_THE_SCOUT\
echo    Size: ~1.8 GB total
echo.
echo  ── llama-cli (optional CLI fallback) ─────────────────────────
echo.
echo    Download from: %LLAMA_CPP_RELEASES%
echo    Look for:      llama-...-bin-win-avx2-x64.zip
echo    Extract and place llama-cli.exe at:
echo      %TARGET%\00_BOOT_SYSTEM\bin\win\llama-cli.exe
echo.
echo  Hugging Face: https://huggingface.co
echo  (Search the model name + GGUF in the search bar)
echo.

:: ---------------------------------------------------------------------------
:: Run setup check
:: ---------------------------------------------------------------------------
echo [7/7] Running setup check...
echo.

IF EXIST "%TARGET%\00_BOOT_SYSTEM\setup_check.sh" (
    where bash >nul 2>&1
    IF NOT ERRORLEVEL 1 (
        bash "%TARGET%\00_BOOT_SYSTEM\setup_check.sh" --root "%TARGET%"
    ) ELSE (
        echo  [INFO] Bash not available -- skipping automated check.
        echo         Install Git for Windows (includes bash) to run setup_check.sh
    )
) ELSE (
    echo  [INFO] setup_check.sh not found -- check skipped.
)

:: ---------------------------------------------------------------------------
:: Done
:: ---------------------------------------------------------------------------
echo.
echo ====================================================
echo  Setup complete.
echo.
echo  NEXT STEPS:
echo  1. Download the model files listed above
echo  2. Add your documents to:
echo       %TARGET%\03_THE_ARCHIVES\
echo  3. Open a terminal and run:
echo       python 03_THE_ARCHIVES\convert_to_text.py --root %TARGET%
echo       python 03_THE_ARCHIVES\index_archives.py --root %TARGET%
echo  4. Boot the system:
echo       %TARGET%\00_BOOT_SYSTEM\start-windows.bat
echo ====================================================
echo.
pause
ENDLOCAL
