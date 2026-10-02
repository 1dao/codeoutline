@echo off
setlocal
if not defined CODEOUTLINE_LOG_LEVEL set "CODEOUTLINE_LOG_LEVEL=WARN"
set "CODEOUTLINE_LOG_OUT=LOG_FILE=0"
if defined CODEOUTLINE_LOG_DIR set "CODEOUTLINE_LOG_OUT=LOG_DIR=%CODEOUTLINE_LOG_DIR%"
set "CODEOUTLINE_BASE=%~dp0"
if "%~1"=="update" goto run
if not defined CODEOUTLINE_AUTO_UPDATE (
    if "%~1"=="serve" (set "CODEOUTLINE_AUTO_UPDATE=1") else (set "CODEOUTLINE_AUTO_UPDATE=0")
)
for /f "usebackq delims=" %%R in (`""%~dp0bin\xnet.exe" "%~dp0scripts\codeoutline\updater.lua" LOG_STDERR=1 LOG_FILE=0 LOG_LEVEL=ERROR ACTION=select"`) do set "CODEOUTLINE_BASE=%%R\"
:run
"%CODEOUTLINE_BASE%bin\xnet.exe" "%CODEOUTLINE_BASE%scripts\codeoutline\command.lua" LOG_STDERR=1 "LOG_LEVEL=%CODEOUTLINE_LOG_LEVEL%" "%CODEOUTLINE_LOG_OUT%" %*
exit /b %errorlevel%
