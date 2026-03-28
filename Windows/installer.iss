; SkyHook Installer - Inno Setup Script
; Requires Inno Setup 6+ (https://jrsoftware.org/isinfo.php)

#define MyAppName "SkyHook"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "SkyHook"
#define MyAppURL "https://github.com/mackid1993/SkyHook"
#define MyAppExeName "SkyHook.exe"

[Setup]
AppId={{A7E2B4F1-8C3D-4E5F-9A1B-2D3E4F5A6B7C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=build
OutputBaseFilename=SkyHook-Setup
SetupIconFile=SkyHook\Resources\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile=..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "launchonstartup"; Description: "Launch SkyHook when Windows starts"; GroupDescription: "Startup:"

[Files]
Source: "build\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\*.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "SkyHook\Resources\icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\icon.ico"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\icon.ico"; Tasks: desktopicon

[Registry]
; Launch at startup (optional task)
Root: HKCU; Subkey: "SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: launchonstartup

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Kill SkyHook before uninstalling
Filename: "taskkill"; Parameters: "/F /IM {#MyAppExeName}"; Flags: runhidden; RunOnceId: "KillSkyHook"

[UninstallDelete]
; Clean up app data on uninstall (optional — user config preserved by default)
; Uncomment to remove settings: Type: filesanddirs; Name: "{userappdata}\SkyHook"

[Code]
// Check if WinFSP is installed and show a message if not
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if not RegKeyExists(HKLM, 'SOFTWARE\WOW6432Node\WinFsp') then
    begin
      if MsgBox('SkyHook requires WinFSP to mount cloud storage as drive letters.' + #13#10 + #13#10 +
                'WinFSP is a free, open-source Windows file system proxy.' + #13#10 +
                'Would you like to open the WinFSP download page now?',
                mbInformation, MB_YESNO) = IDYES then
      begin
        ShellExec('open', 'https://github.com/winfsp/winfsp/releases/latest', '', '', SW_SHOW, ewNoWait, ResultCode);
      end;
    end;
  end;
end;

var
  ResultCode: Integer;
