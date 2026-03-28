@echo off
echo === Building SkyHook for Windows ===
echo.

where dotnet >nul 2>nul
if %errorlevel% neq 0 (
    echo Error: .NET 8 SDK not found.
    echo Install from: https://dotnet.microsoft.com/download
    exit /b 1
)

echo .NET:
dotnet --version
echo.

cd /d "%~dp0SkyHook"

echo Restoring packages...
dotnet restore

echo Building...
dotnet publish -c Release -r win-x64 --self-contained -o "%~dp0build" /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true

if %errorlevel% neq 0 (
    echo Build failed.
    exit /b 1
)

echo.
echo === Build Complete ===
echo   Executable: %~dp0build\SkyHook.exe
echo.

:: Build installer if Inno Setup is available
where iscc >nul 2>nul
if %errorlevel% equ 0 (
    echo === Building Installer ===
    cd /d "%~dp0"
    iscc installer.iss
    if %errorlevel% equ 0 (
        echo.
        echo === Installer Complete ===
        echo   Installer: %~dp0build\SkyHook-Setup.exe
    ) else (
        echo Installer build failed. Standalone exe is still available.
    )
) else (
    echo.
    echo Inno Setup not found - skipping installer.
    echo Install from: https://jrsoftware.org/isdl.php
    echo Then run: iscc installer.iss
)

echo.
