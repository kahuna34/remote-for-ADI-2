# Stiller Integrationstest auf einem frischen Windows-Build-Runner.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$appName = 'Remote for ADI-2 Host'
$installDir = Join-Path $env:LOCALAPPDATA "Programs/$appName"
$settingsDir = Join-Path $env:APPDATA "Markus Rass/$appName"
$logDir = Join-Path $env:LOCALAPPDATA $appName
$settingsFile = Join-Path $settingsDir 'shared_preferences.json'
$logFile = Join-Path $logDir 'host.log'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
$setup = (Resolve-Path 'dist/Remote-for-ADI-2-Host-Windows-Setup.exe').Path
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) "$appName.lnk"
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) "$appName.lnk"
$pubspec = Get-Content 'host/pubspec.yaml' -Raw
$version = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $version.Success) { throw 'Host-Version fehlt in host/pubspec.yaml.' }
$expectedVersion = "$($version.Groups[1].Value) ($($version.Groups[2].Value))"

function Invoke-Installer([string] $File, [string[]] $InstallerArguments) {
    $process = Start-Process -FilePath $File -ArgumentList $InstallerArguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Installer exit code: $($process.ExitCode) ($File)"
    }
}

function Assert-HostStopped {
    if (Get-Process -Name adi2_host, adi2_midi -ErrorAction SilentlyContinue) {
        throw 'Der stille Test darf keinen Host oder MIDI-Hilfsprozess starten.'
    }
}

function Test-RunValue {
    $props = Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue
    return [bool]($props -and $props.PSObject.Properties[$appName])
}

function Assert-PreservedData {
    if ((Get-Content $settingsFile -Raw).Trim() -ne '{"flutter.host_id":"installer-test"}') {
        throw 'Einstellungen wurden verändert oder entfernt.'
    }
    if ((Get-Content $logFile -Raw).Trim() -ne 'installer-test-log') {
        throw 'Protokoll wurde verändert oder entfernt.'
    }
}

# Auf dem frischen GitHub-Runner haben die Host-Tests zuvor bereits ein Protokoll
# angelegt; dort darf es weg. Lokal bleibt die Sperre unten bestehen.
if ($env:GITHUB_ACTIONS -eq 'true') {
    foreach ($path in @($settingsDir, $logDir)) {
        if (Test-Path $path) { Remove-Item $path -Recurse -Force }
    }
}
# Keine bestehenden Nutzerdaten überschreiben, auch bei versehentlichem lokalen Aufruf.
foreach ($path in @($installDir, $settingsDir, $logDir, $shortcut, $desktopShortcut)) {
    if (Test-Path $path) { throw "Test benötigt einen frischen Benutzer: $path existiert bereits." }
}
if ((Test-RunValue)) {
    throw 'Test benötigt einen Benutzer ohne vorhandenen Host-Autostart.'
}
Get-Process -Name adi2_host, adi2_midi -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Path $settingsDir, $logDir -Force | Out-Null
Set-Content $settingsFile '{"flutter.host_id":"installer-test"}'
Set-Content $logFile 'installer-test-log'
if (-not (Test-Path $runKey)) { New-Item -Path $runKey | Out-Null }
New-ItemProperty -Path $runKey -Name $appName -Value '"C:\Portable\adi2_host.exe"' -PropertyType String -Force | Out-Null

try {
    # Zweiter Durchlauf prüft auch ein Update über eine vorhandene Installation.
    foreach ($pass in 1..2) {
        Invoke-Installer $setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOSTART', '/TASKS=')
        foreach ($file in @('adi2_host.exe', 'adi2_midi.exe', 'app_icon.ico')) {
            if (-not (Test-Path (Join-Path $installDir $file))) { throw "Programmdatei fehlt: $file" }
        }
        if (-not (Test-Path $shortcut)) { throw 'Startmenü-Verknüpfung fehlt.' }
        if (Test-Path $desktopShortcut) { throw 'Nicht gewählte Desktop-Verknüpfung wurde angelegt.' }
        $entry = @(Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq $appName })
        if ($entry.Count -ne 1) { throw 'Erwartet wird genau ein HKCU-Uninstall-Eintrag.' }
        if ($entry[0].Publisher -ne 'Markus Rass') { throw 'Falscher Publisher.' }
        if ($entry[0].DisplayVersion -ne $expectedVersion) { throw 'Falsche Version im Uninstall-Eintrag.' }
        Assert-HostStopped
        Assert-PreservedData
    }

    $uninstaller = Join-Path $installDir 'unins000.exe'
    Invoke-Installer $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    # Windows kann die temporäre Selbstlöschung des Uninstallers kurz verzögern.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Test-Path $installDir) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (Test-Path $installDir) { throw 'Installationsordner nach Deinstallation noch vorhanden.' }
    if (Test-Path $shortcut) { throw 'Startmenü-Verknüpfung wurde nicht entfernt.' }
    if ((Test-RunValue)) {
        throw 'Autostart-Wert wurde nicht entfernt.'
    }
    if (Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq $appName }) {
        throw 'Uninstall-Eintrag wurde nicht entfernt.'
    }
    Assert-HostStopped
    Assert-PreservedData
    Write-Host 'Installation, Update, Deinstallation und Erhalt der Nutzerdaten erfolgreich.'
}
finally {
    # Ausschließlich die oben selbst angelegten Testdaten aufräumen.
    Remove-Item $settingsDir, $logDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction SilentlyContinue
}
