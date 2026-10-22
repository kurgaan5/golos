#ifndef PackageDir
  #error PackageDir is required
#endif
#ifndef TargetArch
  #define TargetArch "x64"
#endif

[Setup]
AppId={{C44D6EF1-9037-46FB-8610-4A441F13934F}
AppName=Голос
AppVersion=1.7.2
AppPublisher=kurgaan5
AppPublisherURL=https://github.com/kurgaan5/golos
DefaultDirName={localappdata}\Programs\Golos
DefaultGroupName=Голос
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Golos-1.7.2-Windows-{#TargetArch}-Setup
SetupIconFile=..\shared\Golos.ico
UninstallDisplayIcon={app}\Golos.exe
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
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; Flags: unchecked

[Files]
Source: "{#PackageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Голос"; Filename: "{app}\Golos.exe"
Name: "{autodesktop}\Голос"; Filename: "{app}\Golos.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Golos.exe"; Description: "Запустить Голос"; Flags: nowait postinstall skipifsilent
