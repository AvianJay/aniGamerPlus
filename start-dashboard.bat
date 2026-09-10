@echo off
rem ===================================================================
rem  aniGamerPlus+ -- one-click server start (for testing the mobile app)
rem
rem  Double-click this file. It finds Python, installs anything that is
rem  missing, prints the URL to type into the Flutter app, and starts
rem  the downloader + dashboard.
rem
rem  Deliberately ASCII-only: cmd.exe decides how to read this file
rem  before "chcp" can take effect, so Chinese text here turns into
rem  mojibake on some machines. Once aniGamerPlus.py takes over, its
rem  own output is Chinese as usual.
rem ===================================================================
setlocal EnableExtensions EnableDelayedExpansion
title aniGamerPlus+ server
cd /d "%~dp0"

echo.
echo  ==================================================================
echo   aniGamerPlus+  server
echo  ==================================================================
echo.

rem ------------------------------------------------------------ python
rem  Pick the interpreter that ALREADY has the dependencies, not simply
rem  the newest one. requirements.txt pins lxml==4.9.4, which ships no
rem  wheel for the newest CPython -- "py -3" would land there, try to
rem  compile lxml from source and die on a missing libxml2.
set "PY="
set "PYANY="
for %%p in ("py -3.11" "py -3.12" "py -3.10" "py -3.9" "py -3.13" "py -3" "python") do (
    if not defined PY (
        %%~p -c "import sys" >nul 2>&1
        if not errorlevel 1 (
            if not defined PYANY set "PYANY=%%~p"
            %%~p -c "import fastapi,uvicorn,jinja2,curl_cffi,termcolor,multipart" >nul 2>&1
            if not errorlevel 1 set "PY=%%~p"
        )
    )
)

set "NEEDINSTALL="
if not defined PY (
    if not defined PYANY (
        echo  [X] No Python on PATH.
        echo      Install Python 3.11 from https://www.python.org/downloads/
        echo      and tick "Add python.exe to PATH" in the installer.
        goto :hold
    )
    set "PY=!PYANY!"
    set "NEEDINSTALL=1"
)
for /f "delims=" %%v in ('!PY! -c "import sys;print(sys.version.split()[0])"') do set "PYVER=%%v"
echo  [1/5] Python !PYVER!  ^(!PY!^)

rem ------------------------------------------------------------ config
if not exist "config.json" (
    if not exist "config-sample.json" (
        echo  [X] Neither config.json nor config-sample.json is here.
        echo      Is this the aniGamerPlus folder?
        goto :hold
    )
    copy /y "config-sample.json" "config.json" >nul
    echo  [2/5] config.json created from the sample
    echo        NOTE: the sample listens on 127.0.0.1, which your iPad
    echo        cannot reach. Set dashboard.host to 0.0.0.0 and rerun.
) else (
    echo  [2/5] config.json found
)

rem ------------------------------------------------------- dependencies
if defined NEEDINSTALL (
    echo  [3/5] Installing dependencies, this takes a few minutes...
    echo.
    !PY! -m pip install --disable-pip-version-check -r requirements.txt
    if errorlevel 1 (
        echo.
        echo  [X] pip install failed -- see the errors above.
        echo      If it died building lxml, this Python is too new for the
        echo      pinned lxml==4.9.4. Install Python 3.11 and rerun; this
        echo      script prefers whichever Python already has the packages.
        goto :hold
    )
    echo.
) else (
    echo  [3/5] Dependencies OK
)

rem ----------------------------------------------------------- address
set "HOST="
set "PORT="
set "SCHEME=http"
set "IDX=0"
rem  usebackq, not the usual quotes: the Python below is full of single
rem  quotes and cmd would try to close the for/f command string on them.
for /f "usebackq delims=" %%a in (`!PY! -c "import json;d=json.load(open('config.json',encoding='utf-8')).get('dashboard',{});print(d.get('host','127.0.0.1'));print(d.get('port',5000));print('https' if d.get('SSL') else 'http')" 2^>nul`) do (
    set /a IDX+=1
    if !IDX!==1 set "HOST=%%a"
    if !IDX!==2 set "PORT=%%a"
    if !IDX!==3 set "SCHEME=%%a"
)
if not defined PORT (
    echo  [X] Could not read dashboard.host / dashboard.port from config.json.
    echo      The file is probably not valid JSON.
    goto :hold
)

set "LANIP="
for /f "usebackq delims=" %%a in (`!PY! -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(('8.8.8.8',80));print(s.getsockname()[0]);s.close()" 2^>nul`) do set "LANIP=%%a"

echo  [4/5] Dashboard on !HOST!:!PORT! over !SCHEME!
echo.
if /i "!HOST!"=="0.0.0.0" (
    if defined LANIP (
        echo        Type this into the app ^(Server address^):
        echo.
        echo            !SCHEME!://!LANIP!:!PORT!
        echo.
    ) else (
        echo        Could not detect this PC's LAN address. Run "ipconfig"
        echo        and use the IPv4 address of your Wi-Fi adapter.
        echo.
    )
    echo        This PC:  !SCHEME!://127.0.0.1:!PORT!
) else (
    echo        Listening on !HOST! only.
    if /i not "!HOST!"=="127.0.0.1" (
        echo        Use  !SCHEME!://!HOST!:!PORT!  in the app.
    ) else (
        echo        127.0.0.1 is loopback -- your phone or iPad CANNOT reach it.
        echo        Set dashboard.host to 0.0.0.0 in config.json to test on a device.
    )
)
echo.

rem ---------------------------------------------------------- firewall
netsh advfirewall firewall show rule name="aniGamerPlus !PORT!" >nul 2>&1
if errorlevel 1 (
    echo        [i] No firewall rule named "aniGamerPlus !PORT!" exists yet.
    echo            If the device times out, run this ONCE as Administrator:
    echo.
    echo            netsh advfirewall firewall add rule name="aniGamerPlus !PORT!" dir=in action=allow protocol=TCP localport=!PORT!
    echo.
)

if not exist "cookie.txt" (
    echo        [i] cookie.txt is missing -- browsing and the dashboard still
    echo            work, but downloads that need a Premium account will fail.
    echo.
)

rem ------------------------------------------------------------ launch
echo  [5/5] Starting. Press Ctrl+C to stop.
echo  ------------------------------------------------------------------
echo.
!PY! aniGamerPlus.py
echo.
echo  ------------------------------------------------------------------
echo  Server stopped.

:hold
echo.
pause
endlocal
