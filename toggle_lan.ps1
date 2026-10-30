<#
.SYNOPSIS
  Schaltet zwischen "FRITZ!Box-Modus" und "Normalbetrieb" um.

.DESCRIPTION
  Static : WLAN-Adapter deaktivieren, LAN-Adapter auf feste IPv4-Adresse (ohne Gateway/DNS)
  Dhcp   : feste Adresse entfernen, LAN wieder auf DHCP, WLAN-Adapter aktivieren
  Toggle : (Standard) wechselt automatisch in den jeweils anderen Modus

.EXAMPLE
  .\Switch-FritzBoxNet.ps1                  # umschalten
  .\Switch-FritzBoxNet.ps1 -Mode Static     # erzwingen: feste IP, WLAN aus
  .\Switch-FritzBoxNet.ps1 -Mode Dhcp       # erzwingen: DHCP, WLAN an
  .\Switch-FritzBoxNet.ps1 -LanName "Ethernet 2" -WifiName "WLAN"

  Falls die Ausfuehrung blockiert ist:
  powershell -ExecutionPolicy Bypass -File .\Switch-FritzBoxNet.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Toggle', 'Static', 'Dhcp')]
    [string]$Mode = 'Toggle',

    [string]$LanName,                      # leer = automatisch (erster kabelgebundener Adapter, bevorzugt "Up")
    [string]$WifiName,                     # leer = automatisch (erster WLAN-Adapter)

    [string]$IPAddress    = '192.168.178.2',
    [int]   $PrefixLength = 24
)

$ErrorActionPreference = 'Stop'

# --- Selbst-Elevation (Adapter-Konfiguration braucht Adminrechte) ---------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-Mode', $Mode, '-IPAddress', $IPAddress, '-PrefixLength', $PrefixLength)
    if ($LanName)  { $argList += @('-LanName',  "`"$LanName`"") }
    if ($WifiName) { $argList += @('-WifiName', "`"$WifiName`"") }
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

# --- Adapter finden --------------------------------------------------------------------------
if ($LanName) {
    $lan = Get-NetAdapter -Name $LanName
} else {
    $lan = Get-NetAdapter -Physical |
           Where-Object { $_.PhysicalMediaType -eq '802.3' } |
           Sort-Object { $_.Status -ne 'Up' } |
           Select-Object -First 1
}
if (-not $lan) { throw 'Kein LAN-Adapter gefunden. Bitte -LanName angeben.' }

if ($WifiName) {
    $wifi = Get-NetAdapter -Name $WifiName
} else {
    $wifi = Get-NetAdapter -Physical |
            Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' } |
            Select-Object -First 1
}
if (-not $wifi) { Write-Warning 'Kein WLAN-Adapter gefunden - WLAN wird nicht umgeschaltet.' }

Write-Host "LAN : $($lan.Name)  ($($lan.InterfaceDescription))"
if ($wifi) { Write-Host "WLAN: $($wifi.Name)  ($($wifi.InterfaceDescription))" }

# --- Modus bestimmen ---------------------------------------------------------------------------
$idx = $lan.ifIndex
if ($Mode -eq 'Toggle') {
    $dhcpState = (Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4).Dhcp
    $Mode = if ($dhcpState -eq 'Disabled') { 'Dhcp' } else { 'Static' }
}
Write-Host "Modus: $Mode"

function Clear-LanIPv4 {
    param([int]$Index)
    Remove-NetRoute -InterfaceIndex $Index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' `
                    -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetIPAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
}

# --- Umschalten --------------------------------------------------------------------------------
switch ($Mode) {

    'Static' {
        if ($wifi -and $wifi.Status -ne 'Disabled') {
            Write-Host 'WLAN deaktivieren ...'
            Disable-NetAdapter -Name $wifi.Name -Confirm:$false
        }
        Write-Host "LAN auf $IPAddress/$PrefixLength setzen (ohne Gateway) ..."
        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled
        Clear-LanIPv4 -Index $idx
        New-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 `
                         -IPAddress $IPAddress -PrefixLength $PrefixLength | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses
    }

    'Dhcp' {
        Write-Host 'LAN zurueck auf DHCP ...'
        Clear-LanIPv4 -Index $idx
        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses
        if ($wifi -and $wifi.Status -eq 'Disabled') {
            Write-Host 'WLAN aktivieren ...'
            Enable-NetAdapter -Name $wifi.Name -Confirm:$false
        }
        Restart-NetAdapter -Name $lan.Name -Confirm:$false   # holt sofort eine neue DHCP-Adresse
    }
}

# --- Ergebnis anzeigen -------------------------------------------------------------------------
Start-Sleep -Seconds 2
Write-Host ''
Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin | Format-Table -AutoSize
if ($wifi) {
    Get-NetAdapter -Name $wifi.Name | Select-Object Name, Status | Format-Table -AutoSize
}
Start-Sleep -Seconds 3