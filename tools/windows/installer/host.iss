; Remote for ADI-2 Host, GPL-3.0. Versionen werden aus host/pubspec.yaml übergeben.
#ifndef HostVersion
  #error "HostVersion muss beim Aufruf von ISCC übergeben werden."
#endif
#ifndef HostFileVersion
  #error "HostFileVersion muss beim Aufruf von ISCC übergeben werden."
#endif
#define RepoRoot AddBackslash(SourcePath) + "..\..\.."

[Setup]
AppId=de.markus.remote-for-adi2-host
AppName=Remote for ADI-2 Host
AppVersion={#HostVersion}
AppPublisher=Markus Rass
AppCopyright=Copyright (C) 2026 Markus Rass. GPL-3.0.
VersionInfoVersion={#HostFileVersion}
DefaultDirName={localappdata}\Programs\Remote for ADI-2 Host
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
UninstallDisplayName=Remote for ADI-2 Host
SetupIconFile={#RepoRoot}\host\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\app_icon.ico
OutputDir={#RepoRoot}\dist
OutputBaseFilename=Remote-for-ADI-2-Host-Windows-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
de.DesktopShortcut=Desktop-Verknüpfung erstellen
en.DesktopShortcut=Create a desktop shortcut
de.StartHost=Host jetzt starten
en.StartHost=Start Host now
de.DeleteSettings=Einstellungen ebenfalls löschen?%n%nDabei werden auch die Kopplungen und das Protokoll gelöscht. Mit Nein bleiben sie für eine spätere Installation erhalten.
en.DeleteSettings=Delete settings as well?%n%nThis also deletes pairings and the log. Choose No to keep them for a future installation.
de.StopFailed=Die Host-Prozesse konnten nicht beendet werden. Bitte Remote for ADI-2 Host beenden und erneut versuchen.
en.StopFailed=The Host processes could not be stopped. Please close Remote for ADI-2 Host and try again.

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopShortcut}"; Flags: unchecked

[Files]
Source: "{#RepoRoot}\dist\Remote for ADI-2 Host\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#RepoRoot}\host\windows\runner\resources\app_icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Remote for ADI-2 Host"; Filename: "{app}\adi2_host.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\Remote for ADI-2 Host"; Filename: "{app}\adi2_host.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
; Nur bei Deinstallation entfernen; Setup aktiviert den Autostart nicht.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Remote for ADI-2 Host"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\adi2_host.exe"; Description: "{cm:StartHost}"; Flags: nowait postinstall skipifsilent; Check: ShouldStartHost

[Code]
function ShouldStartHost: Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/NOSTART') = 0 then
      Result := False;
end;

function StopHostProcesses: Boolean;
var
  ResultCode: Integer;
begin
  // Exitcode 128 bedeutet: kein passender Prozess läuft.
  Result := Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/IM adi2_host.exe /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := Result and ((ResultCode = 0) or (ResultCode = 128));
  if not Exec(ExpandConstant('{sys}\taskkill.exe'),
    '/IM adi2_midi.exe /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := False
  else if (ResultCode <> 0) and (ResultCode <> 128) then
    Result := False;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not StopHostProcesses then
    Result := CustomMessage('StopFailed');
end;

function InitializeUninstall: Boolean;
begin
  Result := StopHostProcesses;
  if not Result then
    SuppressibleMsgBox(CustomMessage('StopFailed'), mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  SettingsDir, LogDir: String;
begin
  if CurUninstallStep = usPostUninstall then
    if SuppressibleMsgBox(CustomMessage('DeleteSettings'), mbConfirmation,
      MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
    begin
      SettingsDir := ExpandConstant('{userappdata}\Markus Rass\Remote for ADI-2 Host');
      LogDir := ExpandConstant('{localappdata}\Remote for ADI-2 Host');
      DeleteFile(SettingsDir + '\shared_preferences.json');
      RemoveDir(SettingsDir);
      DeleteFile(LogDir + '\host.log');
      RemoveDir(LogDir);
    end;
end;
