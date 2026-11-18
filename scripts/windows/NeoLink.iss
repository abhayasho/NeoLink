; NeoLink-Setup-x64.exe: a per-user installer (no administrator rights) built with Inno Setup 6.
;
;   python scripts/package-windows.py                       (the release zip; its folder is the source)
;   iscc /DAppVersion=2.2.0 /DSourceDir=<unpacked NeoLink folder> /DOutputDir=target scripts\windows\NeoLink.iss
;
; It installs what scripts/install.ps1 installs, in the same place: Start menu and desktop icons,
; "Open in NeoLink" on folders, the `neolink` command, an entry in Settings > Apps, and (optionally)
; Neovim, Git and ripgrep through winget. Settings in %APPDATA%\NeoLink are kept across updates and
; uninstalls.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\target\windows-package\NeoLink"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\target"
#endif

[Setup]
; Never change the AppId: updates and the uninstaller find an installation by it, and
; scripts/install.ps1 looks for its uninstall entry.
AppId={{6F1D2A8B-3C47-4E5A-9B1E-7A0C2D5E8F31}
AppName=NeoLink
AppVersion={#AppVersion}
AppVerName=NeoLink {#AppVersion}
AppPublisher=NeoLink
AppPublisherURL=https://github.com/abhayasho/NeoLink
AppSupportURL=https://github.com/abhayasho/NeoLink/issues
AppUpdatesURL=https://github.com/abhayasho/NeoLink/releases
VersionInfoVersion={#AppVersion}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={localappdata}\Programs\NeoLink
DisableDirPage=auto
DisableProgramGroupPage=yes
DefaultGroupName=NeoLink
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=NeoLink-Setup-x64
SetupIconFile=..\..\Resources\AppIcon.ico
UninstallDisplayIcon={app}\NeoLink.exe
UninstallDisplayName=NeoLink
LicenseFile=..\..\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes
ChangesAssociations=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Shortcuts:"
Name: "contextmenu"; Description: "Add ""Open in NeoLink"" to folders in File Explorer"; GroupDescription: "Shortcuts:"
Name: "path"; Description: "Add the &neolink command to terminals"; GroupDescription: "Shortcuts:"
Name: "tools"; Description: "Install Neovim, Git and ripgrep if they are missing (uses winget)"; GroupDescription: "Tools NeoLink works with:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "install-tools.ps1"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "neolink.cmd"; DestDir: "{app}\bin"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\NeoLink"; Filename: "{app}\NeoLink.exe"; WorkingDir: "{app}"; Comment: "NeoLink: terminals, editor, explorer and agents"
Name: "{userdesktop}\NeoLink"; Filename: "{app}\NeoLink.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\Directory\shell\NeoLink"; ValueType: string; ValueName: ""; ValueData: "Open in NeoLink"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\NeoLink"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\NeoLink.exe"",0"; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\shell\NeoLink\command"; ValueType: string; ValueName: ""; ValueData: """{app}\NeoLink.exe"" ""%1"""; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\NeoLink"; ValueType: string; ValueName: ""; ValueData: "Open in NeoLink"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\NeoLink"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\NeoLink.exe"",0"; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\NeoLink\command"; ValueType: string; ValueName: ""; ValueData: """{app}\NeoLink.exe"" ""%V"""; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Drive\shell\NeoLink"; ValueType: string; ValueName: ""; ValueData: "Open in NeoLink"; Flags: uninsdeletekey; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Drive\shell\NeoLink"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\NeoLink.exe"",0"; Tasks: contextmenu
Root: HKCU; Subkey: "Software\Classes\Drive\shell\NeoLink\command"; ValueType: string; ValueName: ""; ValueData: """{app}\NeoLink.exe"" ""%1"""; Tasks: contextmenu
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; Check: NeedsAddPath(ExpandConstant('{app}\bin')); Tasks: path

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\bin\install-tools.ps1"""; StatusMsg: "Installing Neovim, Git and ripgrep..."; Flags: runhidden waituntilterminated; Tasks: tools
Filename: "{app}\NeoLink.exe"; Description: "Open NeoLink"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\bin"

[Code]
const
  ScriptUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\NeoLink';

function NeedsAddPath(Folder: string): Boolean;
var
  Current: string;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Current) then
  begin
    Result := True;
    exit;
  end;
  Result := Pos(';' + Uppercase(Folder) + ';', ';' + Uppercase(Current) + ';') = 0;
end;

procedure RemovePath(Folder: string);
var
  Current: string;
  Position: Integer;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Current) then
    exit;
  Current := ';' + Current + ';';
  Position := Pos(';' + Uppercase(Folder) + ';', Uppercase(Current));
  if Position = 0 then
    exit;
  Delete(Current, Position, Length(Folder) + 1);
  Current := Copy(Current, 2, Length(Current) - 2);
  RegWriteExpandStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Current);
end;

// A copy installed by scripts/install.ps1 is taken over: its uninstall entry would otherwise list
// NeoLink twice in Settings > Apps. Its files are replaced by this installation's.
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    if RegKeyExists(HKEY_CURRENT_USER, ScriptUninstallKey) then
      RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, ScriptUninstallKey);
    DeleteFile(ExpandConstant('{app}\uninstall.ps1'));
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemovePath(ExpandConstant('{app}\bin'));
end;
