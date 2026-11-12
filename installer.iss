#define MyAppName "MY APP"
#define MyAppVersion "3.1.0"
#define MyAppExeName "my_app_inventory.exe"

[Setup]
AppId={{A8C6B17E-91D1-4EAA-94C5-2C21A6A12B37}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
UsePreviousAppDir=yes
Uninstallable=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes
RestartApplications=no
DefaultDirName={autopf}\MY APP
DefaultGroupName={#MyAppName}
OutputDir=Output
OutputBaseFilename=MY-APP-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
ArchitecturesInstallIn64BitMode=x64

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "إنشاء اختصار على سطح المكتب"; GroupDescription: "اختصارات إضافية:"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "تشغيل MY APP"; Flags: nowait postinstall skipifsilent
