@echo off
REM Tailscale Installation Script for dockur/windows
REM This script installs Tailscale 1.86.2 (latest stable as of now)
REM Note: Version 1.86.5 does not exist; using 1.86.2 instead

echo ==========================================
echo Starting Tailscale Installation
echo ==========================================
echo.

REM Set variables
set TAILSCALE_VERSION=1.86.2
set TAILSCALE_MSI=tailscale-setup-%TAILSCALE_VERSION%-amd64.msi
set DOWNLOAD_URL=https://pkgs.tailscale.com/stable/%TAILSCALE_MSI%
set INSTALL_DIR=C:\OEM
set LOG_FILE=%INSTALL_DIR%\tailscale_install.log

REM Create log file
echo Installation started at %date% %time% > "%LOG_FILE%"

REM Check if running as administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: This script requires administrator privileges >> "%LOG_FILE%"
    echo ERROR: This script requires administrator privileges
    exit /b 1
)

REM Download Tailscale MSI installer
echo Downloading Tailscale %TAILSCALE_VERSION%...
echo Downloading from: %DOWNLOAD_URL% >> "%LOG_FILE%"

REM Use PowerShell to download the file
powershell -Command "& {[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%INSTALL_DIR%\%TAILSCALE_MSI%' -UseBasicParsing}" 2>> "%LOG_FILE%"

if not exist "%INSTALL_DIR%\%TAILSCALE_MSI%" (
    echo ERROR: Failed to download Tailscale installer >> "%LOG_FILE%"
    echo ERROR: Failed to download Tailscale installer
    
    REM Fallback: Try with curl if available
    echo Attempting download with curl... >> "%LOG_FILE%"
    curl -L -o "%INSTALL_DIR%\%TAILSCALE_MSI%" "%DOWNLOAD_URL%" 2>> "%LOG_FILE%"
    
    if not exist "%INSTALL_DIR%\%TAILSCALE_MSI%" (
        echo ERROR: Download failed with both methods >> "%LOG_FILE%"
        echo ERROR: Download failed. Please check your internet connection.
        exit /b 1
    )
)

echo Download complete.
echo.

REM Install Tailscale with MSI parameters
echo Installing Tailscale...
echo Running MSI installation... >> "%LOG_FILE%"

REM MSI installation with parameters for unattended installation
msiexec /i "%INSTALL_DIR%\%TAILSCALE_MSI%" /quiet /norestart /log "%INSTALL_DIR%\tailscale_msi.log" ^
    TS_NOLAUNCH=yes ^
    TS_INSTALLUPDATES=always ^
    TS_ALLOWINCOMINGCONNECTIONS=always ^
    TS_UNATTENDEDMODE=always

set INSTALL_RESULT=%errorLevel%

if %INSTALL_RESULT% equ 0 (
    echo Tailscale installed successfully! >> "%LOG_FILE%"
    echo Tailscale installed successfully!
) else if %INSTALL_RESULT% equ 3010 (
    echo Tailscale installed successfully but requires restart. >> "%LOG_FILE%"
    echo Tailscale installed successfully but requires restart.
) else (
    echo ERROR: Installation failed with error code %INSTALL_RESULT% >> "%LOG_FILE%"
    echo ERROR: Installation failed with error code %INSTALL_RESULT%
    echo Check %INSTALL_DIR%\tailscale_msi.log for details
    exit /b %INSTALL_RESULT%
)

REM Wait for Tailscale service to start
echo.
echo Waiting for Tailscale service to start...
timeout /t 10 /nobreak > nul

REM Check if Tailscale service is running
sc query Tailscale > nul 2>&1
if %errorLevel% equ 0 (
    echo Tailscale service is installed. >> "%LOG_FILE%"
    
    REM Start the service if it's not running
    sc query Tailscale | find "RUNNING" > nul
    if %errorLevel% neq 0 (
        echo Starting Tailscale service...
        net start Tailscale >> "%LOG_FILE%" 2>&1
        timeout /t 5 /nobreak > nul
    )
    
    echo Tailscale service is running. >> "%LOG_FILE%"
) else (
    echo WARNING: Tailscale service not found. It may start after reboot. >> "%LOG_FILE%"
    echo WARNING: Tailscale service not found. It may start after reboot.
)

REM Clean up installer file (optional - comment out if you want to keep it)
REM del "%INSTALL_DIR%\%TAILSCALE_MSI%" 2>> "%LOG_FILE%"

REM Optional: Configure Tailscale (uncomment and modify as needed)
REM echo.
REM echo Configuring Tailscale...
REM 
REM REM Example: Set auth key for automatic connection (replace YOUR_AUTH_KEY)
REM REM "C:\Program Files\Tailscale\tailscale.exe" up --authkey=YOUR_AUTH_KEY --hostname=%COMPUTERNAME%
REM 
REM REM Example: Set exit node preference
REM REM "C:\Program Files\Tailscale\tailscale.exe" set --exit-node=100.x.x.x
REM 
REM REM Example: Enable subnet routes
REM REM "C:\Program Files\Tailscale\tailscale.exe" set --advertise-routes=10.0.0.0/24

echo.
echo ==========================================
echo Tailscale Installation Complete
echo ==========================================
echo.
echo Installation log: %LOG_FILE%
echo MSI log: %INSTALL_DIR%\tailscale_msi.log
echo.
echo To connect Tailscale:
echo 1. Open Tailscale from the system tray
echo 2. Log in with your account
echo 3. Or run: "C:\Program Files\Tailscale\tailscale.exe" up
echo.
echo Installation completed at %date% %time% >> "%LOG_FILE%"

REM Optional: Reboot if needed (uncomment if you want automatic reboot)
REM if %INSTALL_RESULT% equ 3010 (
REM     echo System will restart in 30 seconds...
REM     shutdown /r /t 30 /c "Restarting to complete Tailscale installation"
REM )

exit /b 0