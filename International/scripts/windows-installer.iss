#ifndef PackageDir
  #error PackageDir is required
#endif
#ifndef TargetArch
  #define TargetArch "x64"
#endif

[Setup]
AppId={{D4C6957A-822E-4CAC-A117-E91CC44430D2}
AppName=DictaNest
AppVersion=1.8.0
AppPublisher=Okulovsky
AppPublisherURL=https://github.com/kurgaan5/golos
DefaultDirName={localappdata}\Programs\DictaNest
DefaultGroupName=DictaNest
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=DictaNest-1.8.0-beta.1-Windows-{#TargetArch}-Setup
SetupIconFile=..\shared\Golos.ico
UninstallDisplayIcon={app}\DictaNest.exe
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
#if TargetArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
MinVersion=10.0.22000
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\DictaNest"; Filename: "{app}\DictaNest.exe"
Name: "{autodesktop}\DictaNest"; Filename: "{app}\DictaNest.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\DictaNest.exe"; Description: "Launch DictaNest"; Flags: nowait postinstall skipifsilent
