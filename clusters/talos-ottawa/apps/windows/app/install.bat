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
    @REM TS_NOLAUNCH=no ^
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

REM Configure Tailscale with OAuth credentials
echo.
echo Configuring Tailscale with OAuth authentication...

REM Read OAuth credentials from mounted Kubernetes secret files
REM The secret files are mounted to /data/secrets and accessible via network share
set SECRETS_DIR=\\host.lan\Data\secrets
set CLIENT_ID_FILE=%SECRETS_DIR%\client_id
set CLIENT_SECRET_FILE=%SECRETS_DIR%\client_secret

REM Wait for network share to be available
echo Waiting for network share to be available... >> "%LOG_FILE%"
timeout /t 5 /nobreak > nul

REM Try to access the network share
net use \\host.lan\Data 2>> "%LOG_FILE%" > nul

if not exist "%SECRETS_DIR%" (
    echo WARNING: Secrets directory not found at %SECRETS_DIR% >> "%LOG_FILE%"
    echo Attempting to map network share... >> "%LOG_FILE%"
    
    REM Try to establish connection to the network share
    ping -n 2 host.lan > nul 2>&1
    net use \\host.lan\Data /persistent:no 2>> "%LOG_FILE%"
    timeout /t 3 /nobreak > nul
    
    if not exist "%SECRETS_DIR%" (
        echo WARNING: OAuth secrets not accessible via network share. Manual authentication will be required. >> "%LOG_FILE%"
        echo WARNING: OAuth secrets not mounted. Manual authentication will be required.
        echo.
        echo To manually authenticate later, run:
        echo "C:\Program Files\Tailscale\tailscale.exe" up
        goto skip_auth
    )
)

echo Reading OAuth credentials from %SECRETS_DIR% >> "%LOG_FILE%"

REM Read OAuth Client ID
if exist "%CLIENT_ID_FILE%" (
    set /p TS_OAUTH_CLIENT_ID=<"%CLIENT_ID_FILE%"
    echo OAuth Client ID loaded >> "%LOG_FILE%"
) else (
    echo WARNING: client_id file not found >> "%LOG_FILE%"
)

REM Read OAuth Client Secret
if exist "%CLIENT_SECRET_FILE%" (
    set /p TS_OAUTH_CLIENT_SECRET=<"%CLIENT_SECRET_FILE%"
    echo OAuth Client Secret loaded >> "%LOG_FILE%"
) else (
    echo WARNING: client_secret file not found >> "%LOG_FILE%"
)

REM Check if OAuth credentials are available
if "%TS_OAUTH_CLIENT_SECRET%"=="" (
    echo WARNING: TS_OAUTH_CLIENT_SECRET not loaded from secret. >> "%LOG_FILE%"
    echo WARNING: OAuth client secret not found. Manual authentication will be required.
    echo.
    echo To manually authenticate later, run:
    echo "C:\Program Files\Tailscale\tailscale.exe" up
    goto skip_auth
)

REM Authenticate with Tailscale using OAuth credentials for ephemeral node
echo Authenticating with Tailscale as ephemeral node...
echo Running tailscale up with OAuth credentials >> "%LOG_FILE%"

REM Use OAuth client secret as auth key with ephemeral and preauthorized flags
"C:\Program Files\Tailscale\tailscale.exe" up ^
    --authkey="%TS_OAUTH_CLIENT_SECRET%?ephemeral=true&preauthorized=true" ^
    --advertise-tags=tag:k8s ^
    --accept-routes ^
    --accept-dns >> "%LOG_FILE%" 2>&1

if %errorLevel% equ 0 (
    echo Tailscale authenticated successfully as ephemeral node! >> "%LOG_FILE%"
    echo Tailscale authenticated successfully!
    
    REM Wait a moment for connection to establish
    timeout /t 5 /nobreak > nul
    
    REM Check Tailscale status
    echo.
    echo Checking Tailscale connection status...
    "C:\Program Files\Tailscale\tailscale.exe" status >> "%LOG_FILE%" 2>&1
    "C:\Program Files\Tailscale\tailscale.exe" status
) else (
    echo ERROR: Failed to authenticate with Tailscale. Error code: %errorLevel% >> "%LOG_FILE%"
    echo ERROR: Failed to authenticate with Tailscale
    echo Check the log file for details: %LOG_FILE%
    
    REM Try non-ephemeral as fallback
    echo Attempting non-ephemeral authentication as fallback... >> "%LOG_FILE%"
    "C:\Program Files\Tailscale\tailscale.exe" up ^
        --authkey="%TS_OAUTH_CLIENT_SECRET%?ephemeral=false&preauthorized=true" ^
        --accept-routes ^
        --accept-dns >> "%LOG_FILE%" 2>&1
    
    if %errorLevel% equ 0 (
        echo Fallback authentication successful (non-ephemeral) >> "%LOG_FILE%"
        echo Authenticated successfully with fallback method
    )
)

:skip_auth

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