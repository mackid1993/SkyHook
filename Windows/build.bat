@echo off
echo === Building SkyHook for Windows ===
where dotnet >nul 2>nul
if %errorlevel% neq 0 (echo Error: .NET 8 SDK not found. & exit /b 1)
echo .NET:
dotnet --version
cd /d "%~dp0SkyHook"
echo Restoring packages...
dotnet restore
echo Building...
dotnet publish -c Release -r win-x64 --self-contained -o "%~dp0build" /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true
if %errorlevel% equ 0 (echo. & echo === Done === & echo. & echo   %~dp0build\SkyHook.exe) else (echo Build failed. & exit /b 1)
