# Remote for ADI-2 - Windows diagnosis
# Reads MIDI ports, devices and host status. Changes nothing.
# Writes ADI-2-Diagnose.txt to the desktop and opens it.

param([switch]$NoOpen)

$ErrorActionPreference = 'SilentlyContinue'

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class Adi2Midi {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct InCaps { public ushort m; public ushort p; public uint v; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public uint s; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct OutCaps { public ushort m; public ushort p; public uint v; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public ushort t; public ushort vo; public ushort n; public ushort c; public uint s; }
 [DllImport("winmm.dll")] public static extern uint midiInGetNumDevs();
 [DllImport("winmm.dll")] public static extern uint midiOutGetNumDevs();
 [DllImport("winmm.dll", CharSet=CharSet.Unicode)] public static extern uint midiInGetDevCapsW(UIntPtr i, ref InCaps c, uint size);
 [DllImport("winmm.dll", CharSet=CharSet.Unicode)] public static extern uint midiOutGetDevCapsW(UIntPtr i, ref OutCaps c, uint size);
}
"@

$out = New-Object System.Collections.Generic.List[string]
function Add-Line($text) { $out.Add([string]$text) }
function Add-Block($title, $lines) {
  Add-Line ''
  Add-Line "=== $title"
  if ($null -eq $lines -or @($lines).Count -eq 0) { Add-Line '(none)' } else { foreach ($l in $lines) { Add-Line $l } }
}

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Add-Line 'Remote for ADI-2 - Windows diagnosis'
Add-Line ("Date: " + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
Add-Line ("Windows: " + $cv.ProductName + ' ' + $cv.DisplayVersion + ' (build ' + $cv.CurrentBuild + ')')
Add-Line ("64-bit: " + [Environment]::Is64BitOperatingSystem)

$inputs = @()
for ($i = 0; $i -lt [Adi2Midi]::midiInGetNumDevs(); $i++) {
  try {
    $c = New-Object Adi2Midi+InCaps
    $r = [Adi2Midi]::midiInGetDevCapsW((New-Object UIntPtr ([uint32]$i)), [ref]$c, [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Adi2Midi+InCaps]))
    $inputs += "$i [result $r] $($c.name)"
  } catch { $inputs += "$i error: $($_.Exception.Message)" }
}
Add-Block 'MIDI inputs (WinMM)' $inputs

$outputs = @()
for ($i = 0; $i -lt [Adi2Midi]::midiOutGetNumDevs(); $i++) {
  try {
    $c = New-Object Adi2Midi+OutCaps
    $r = [Adi2Midi]::midiOutGetDevCapsW((New-Object UIntPtr ([uint32]$i)), [ref]$c, [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Adi2Midi+OutCaps]))
    $outputs += "$i [result $r] $($c.name)"
  } catch { $outputs += "$i error: $($_.Exception.Message)" }
}
Add-Block 'MIDI outputs (WinMM)' $outputs

$adiPorts = @($inputs + $outputs | Where-Object { $_ -match 'adi-2|adi2|adi 2' })
Add-Line ''
if ($adiPorts.Count -gt 0) { Add-Line 'Result: ADI-2 MIDI port found.' } else { Add-Line 'Result: NO MIDI port with "ADI-2" in its name.' }

$devices = Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'ADI|RME|MIDI' } |
  ForEach-Object {
    $desc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc').Data
    "$($_.Class) | $($_.Status) | $($_.FriendlyName) | reported: $desc"
  }
Add-Block 'Devices (ADI, RME, MIDI)' $devices

$svc = Get-Service -Name MidiSrv
Add-Block 'Windows MIDI service' @(if ($svc) { "$($svc.Name): $($svc.Status)" } else { 'MidiSrv not installed' })

$procs = Get-Process | Where-Object { $_.ProcessName -match 'adi2_host|ADI-2|RME' } |
  ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }
Add-Block 'Running programs (host, RME)' $procs

$listen = Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -ge 47321 -and $_.LocalPort -le 47330 } |
  ForEach-Object { "Port $($_.LocalPort) by PID $($_.OwningProcess)" }
Add-Block 'Host network port (47321)' $listen

$fw = Get-NetFirewallApplicationFilter | Where-Object { $_.Program -match 'adi2_host' } |
  ForEach-Object {
    $rule = $_ | Get-NetFirewallRule
    "$($rule.DisplayName) | enabled $($rule.Enabled) | $($rule.Action) | profile $($rule.Profile)"
  }
Add-Block 'Firewall rules for adi2_host' $fw

$file = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ADI-2-Diagnose.txt'
$out | Out-File -FilePath $file -Encoding UTF8
$out | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host "Saved: $file"
if (-not $NoOpen) { Start-Process notepad.exe $file }
