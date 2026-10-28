#ifndef PackageDir
  #error PackageDir is required
#endif
#ifndef TargetArch
  #define TargetArch "x64"
#endif
#ifndef AppVersion
  #define AppVersion "1.7.8"
#endif

[Setup]
AppId={{C44D6EF1-9037-46FB-8610-4A441F13934F}
AppName=Голос
AppVersion={#AppVersion}
AppPublisher=kurgaan5
AppPublisherURL=https://github.com/kurgaan5/golos
DefaultDirName={localappdata}\Programs\Golos
DefaultGroupName=Голос
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Golos-{#AppVersion}-Windows-{#TargetArch}-Setup
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

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  StoredCommand: String;
  ExpectedCommand: String;
begin
  if CurUninstallStep <> usUninstall then
    Exit;

  { Another portable/installed copy may have replaced the shared value since
    this installation registered it. Remove only this exact command. }
  ExpectedCommand := '"' + ExpandConstant('{app}\Golos.exe') + '" --background';
  if RegQueryStringValue(HKCU,
    'Software\Microsoft\Windows\CurrentVersion\Run', 'Golos', StoredCommand) then
  begin
    if StoredCommand = ExpectedCommand then
    begin
      if not RegDeleteValue(HKCU,
        'Software\Microsoft\Windows\CurrentVersion\Run', 'Golos') then
        Log('Could not remove this installation''s Golos startup value.');
    end;
  end;
end;
