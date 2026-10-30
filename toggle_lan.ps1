<#
.SYNOPSIS
  Schaltet zwischen "FRITZ!Box-Modus" und "Normalbetrieb" um.

.DESCRIPTION
  Static : LAN-Adapter auf feste IPv4-Adresse (ohne Gateway/DNS) setzen, danach WLAN deaktivieren
  Dhcp   : feste Adresse entfernen, LAN wieder auf DHCP, WLAN-Adapter aktivieren
  Toggle : (Standard) wechselt automatisch in den jeweils anderen Modus

  WICHTIG:
  - Benoetigt Administratorrechte (das Skript startet sich selbst erhoeht neu).
  - Aendert die Netzwerkkonfiguration und unterbricht die Verbindung kurzzeitig.
  - Nicht ueber RDP/SSH/WinRM auf demselben Adapter ausfuehren; das Skript bricht
    dann ab, ausser -Force wird bewusst gesetzt.
  - Die Standard-IP 192.168.178.2/24 passt zu fritzflash.py (FRITZ!Box auf 192.168.178.1).
  - Bei einem Fehler wird die vorherige Konfiguration automatisch wiederhergestellt.
  - Es wird nur IPv4 angepasst; eine bestehende IPv6-Verbindung bleibt unberuehrt.
  - -Force ueberspringt Rueckfrage und Sicherheitspruefungen (nur bewusst verwenden,
    z. B. fuer unbeaufsichtigte Aufrufe).

.EXAMPLE
  .\toggle_lan.ps1                  # umschalten
  .\toggle_lan.ps1 -Mode Static     # erzwingen: feste IP, WLAN aus
  .\toggle_lan.ps1 -Mode Dhcp       # erzwingen: DHCP, WLAN an
  .\toggle_lan.ps1 -LanName "Ethernet 2" -WifiName "WLAN"

  Falls die Ausfuehrung blockiert ist:
  powershell -ExecutionPolicy Bypass -File .\toggle_lan.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Toggle', 'Static', 'Dhcp')]
    [string]$Mode = 'Toggle',

    [string]$LanName,                      # leer = automatisch (verbundener kabelgebundener Adapter)
    [string]$WifiName,                     # leer = automatisch (bevorzugt aktiver WLAN-Adapter)

    [ValidateScript({
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($_, [ref]$parsed) -or
            $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Ungueltige IPv4-Adresse: $_"
        }
        $true
    })]
    [string]$IPAddress = '192.168.178.2',

    [ValidateRange(1, 32)]
    [int]$PrefixLength = 24,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$requiredModules = 'NetAdapter', 'NetTCPIP', 'DnsClient'
$missingModules = @($requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($missingModules.Count -gt 0) {
    throw "PowerShell-Modul(e) nicht gefunden: $($missingModules -join ', '). Windows 10/11 mit PowerShell 5.1+ erforderlich."
}
$whatIfWasSet = $WhatIfPreference
$WhatIfPreference = $false
try { Import-Module $requiredModules -ErrorAction Stop }
finally { $WhatIfPreference = $whatIfWasSet }

function Quote-Arg {
    param([string]$Value)
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

# --- Schutz vor Remote-Lockout ---------------------------------------------------------------
$remoteSession = $false
if ($env:SESSIONNAME -match '^(RDP|RDP-Tcp)') { $remoteSession = $true }
if ($env:SSH_CONNECTION -or $env:SSH_CLIENT)  { $remoteSession = $true }
if ($PSSenderInfo)                            { $remoteSession = $true }
if ($remoteSession -and -not $Force -and -not $WhatIfPreference) {
    throw 'Die Sitzung scheint remote (RDP/SSH/WinRM) zu sein. Netzwerk-Aenderungen koennen die Verbindung trennen. Mit -Force erzwingen.'
}

# --- Selbst-Elevation (Adapter-Konfiguration braucht Adminrechte) ---------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $PSCommandPath),
        '-Mode', $Mode,
        '-IPAddress', (Quote-Arg $IPAddress),
        '-PrefixLength', $PrefixLength
    )
    if ($LanName)  { $argList += @('-LanName',  (Quote-Arg $LanName)) }
    if ($WifiName) { $argList += @('-WifiName', (Quote-Arg $WifiName)) }
    if ($Force)    { $argList += '-Force' }
    if ($WhatIfPreference) { $argList += '-WhatIf' }

    $hostExe = (Get-Process -Id $PID).Path
    if (-not $hostExe -or $hostExe -match 'powershell_ise\.exe$') {
        $hostExe = Join-Path $PSHOME 'powershell.exe'
    }
    $proc = Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $proc.ExitCode
}

# --- Adapter finden --------------------------------------------------------------------------
function Resolve-PhysicalAdapter {
    param(
        [string]$Name,
        [scriptblock]$AutoFilter,
        [string]$Kind
    )

    if ($Name) {
        $found = @(Get-NetAdapter -Physical | Where-Object { $_.Name -eq $Name })
        if ($found.Count -eq 0) {
            throw "$Kind-Adapter '$Name' nicht gefunden (es werden nur physische Adapter verwendet)."
        }
        if ($found.Count -gt 1) {
            throw "$Kind-Adapter '$Name' ist nicht eindeutig."
        }
        return $found[0]
    }

    $candidates = @(Get-NetAdapter -Physical | Where-Object $AutoFilter)
    if ($candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object { $_.Status -ne 'Up' } | Select-Object -First 1)
}

$lan = Resolve-PhysicalAdapter -Name $LanName -Kind 'LAN' -AutoFilter { $_.PhysicalMediaType -eq '802.3' }
if (-not $lan) { throw 'Kein LAN-Adapter gefunden. Bitte -LanName angeben.' }
if ($lan.Status -ne 'Up' -and -not $Force -and -not $WhatIfPreference) {
    throw "LAN-Adapter '$($lan.Name)' ist nicht verbunden (Status: $($lan.Status)). Kabel pruefen oder -Force verwenden."
}

$wifi = Resolve-PhysicalAdapter -Name $WifiName -Kind 'WLAN' -AutoFilter { $_.PhysicalMediaType -eq 'Native 802.11' }
if (-not $wifi) { Write-Warning 'Kein WLAN-Adapter gefunden - WLAN wird nicht umgeschaltet.' }

if ($wifi -and $wifi.ifIndex -eq $lan.ifIndex) {
    throw 'LAN- und WLAN-Adapter duerfen nicht identisch sein.'
}

Write-Host "LAN : $($lan.Name)  ($($lan.InterfaceDescription))  Status: $($lan.Status)"
if ($wifi) { Write-Host "WLAN: $($wifi.Name)  ($($wifi.InterfaceDescription))  Status: $($wifi.Status)" }

# --- Modus bestimmen ---------------------------------------------------------------------------
$idx = $lan.ifIndex
$dhcpState = (Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction Stop).Dhcp
if ($Mode -eq 'Toggle') {
    $Mode = if ($dhcpState -eq 'Disabled') { 'Dhcp' } else { 'Static' }
}
Write-Host "Modus: $Mode"

# --- Bestaetigung / WhatIf ---------------------------------------------------------------------
$target = if ($Mode -eq 'Static') {
    "LAN '$($lan.Name)' auf $IPAddress/$PrefixLength setzen und WLAN deaktivieren"
} else {
    "LAN '$($lan.Name)' auf DHCP zuruecksetzen und WLAN aktivieren"
}
if ($Force) { $ConfirmPreference = 'None' }
if (-not $PSCmdlet.ShouldProcess($target, 'Netzwerkkonfiguration aendern')) {
    if ($WhatIfPreference) {
        Write-Host 'WhatIf: keine Aenderungen vorgenommen.'
    } else {
        Write-Host 'Abgebrochen (Bestaetigung verneint).'
    }
    return
}

# --- Ausgangszustand sichern (fuer Rollback) ---------------------------------------------------
$snapshot = [pscustomobject]@{
    Dhcp       = $dhcpState
    IPs        = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    Dns        = @((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    Routes     = @(Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    WifiStatus = if ($wifi) { (Get-NetAdapter -Physical | Where-Object { $_.ifIndex -eq $wifi.ifIndex }).Status } else { $null }
    LanName    = $lan.Name
}

function Clear-LanIPv4 {
    param([int]$Index)
    Remove-NetRoute -InterfaceIndex $Index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' `
                    -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetIPAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
}

function Restore-LanConfiguration {
    param(
        [int]$Index,
        [pscustomobject]$Snapshot,
        $Wifi
    )
    Write-Warning 'Fehler - vorherige Netzwerkkonfiguration wird wiederhergestellt ...'
    try {
        Remove-NetRoute -InterfaceIndex $Index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetIPAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        Set-NetIPInterface -InterfaceIndex $Index -AddressFamily IPv4 -Dhcp $Snapshot.Dhcp -Confirm:$false

        if ($Snapshot.Dhcp -eq 'Disabled') {
            foreach ($addr in $Snapshot.IPs) {
                New-NetIPAddress -InterfaceIndex $Index -AddressFamily IPv4 `
                                 -IPAddress $addr.IPAddress -PrefixLength $addr.PrefixLength `
                                 -ErrorAction SilentlyContinue | Out-Null
            }
            foreach ($route in $Snapshot.Routes) {
                if ($route.NextHop -and $route.NextHop -ne '0.0.0.0') {
                    New-NetRoute -InterfaceIndex $Index -AddressFamily IPv4 `
                                 -DestinationPrefix $route.DestinationPrefix -NextHop $route.NextHop `
                                 -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }

        if ($Snapshot.Dns.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $Index -ServerAddresses $Snapshot.Dns -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $Index -ResetServerAddresses -Confirm:$false -ErrorAction SilentlyContinue
        }

        if ($Snapshot.Dhcp -eq 'Enabled') {
            Get-NetAdapter -Physical | Where-Object { $_.ifIndex -eq $Index } |
                Restart-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
        }

        if ($Wifi) {
            $currentWifi = Get-NetAdapter -Physical | Where-Object { $_.ifIndex -eq $Wifi.ifIndex }
            if ($Snapshot.WifiStatus -eq 'Disabled' -and $currentWifi.Status -ne 'Disabled') {
                Disable-NetAdapter -InputObject $currentWifi -Confirm:$false -ErrorAction SilentlyContinue
            } elseif ($Snapshot.WifiStatus -ne 'Disabled' -and $currentWifi.Status -eq 'Disabled') {
                Enable-NetAdapter -InputObject $currentWifi -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Warning "Rollback fehlgeschlagen: $($_.Exception.Message)"
    }
}

# --- Umschalten --------------------------------------------------------------------------------
$changed = $false
try {
    switch ($Mode) {

        'Static' {
            $alreadyOwned      = @($snapshot.IPs | Where-Object { $_.IPAddress -eq $IPAddress }).Count -gt 0
            $alreadyConfigured = @($snapshot.IPs | Where-Object {
                $_.IPAddress -eq $IPAddress -and $_.PrefixLength -eq $PrefixLength
            }).Count -gt 0

            if ($alreadyConfigured -and $snapshot.Dhcp -eq 'Disabled' -and
                (-not $wifi -or $snapshot.WifiStatus -eq 'Disabled')) {
                Write-Host 'Bereits im FRITZ!Box-Modus - keine Aenderung noetig.'
            } else {
                if (-not $Force -and -not $alreadyOwned -and
                    (Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                    throw "IP-Adresse $IPAddress antwortet bereits im Netzwerk - moeglicher Konflikt. Abbruch (mit -Force erzwingbar)."
                }

                Write-Host "LAN auf $IPAddress/$PrefixLength setzen (ohne Gateway) ..."
                Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled -Confirm:$false
                $changed = $true
                Clear-LanIPv4 -Index $idx
                New-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 `
                                 -IPAddress $IPAddress -PrefixLength $PrefixLength -Confirm:$false | Out-Null
                Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -Confirm:$false

                $applied = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                             Where-Object { $_.IPAddress -eq $IPAddress -and $_.PrefixLength -eq $PrefixLength })
                if ($applied.Count -eq 0) {
                    throw "Statische Adresse $IPAddress/$PrefixLength wurde nicht gesetzt."
                }

                if ($wifi -and $snapshot.WifiStatus -ne 'Disabled') {
                    Write-Host 'WLAN deaktivieren ...'
                    Disable-NetAdapter -InputObject $wifi -Confirm:$false
                    $changed = $true
                }
            }
        }

        'Dhcp' {
            $alreadyDhcp = $snapshot.Dhcp -eq 'Enabled' -and
                           @($snapshot.IPs | Where-Object { $_.PrefixOrigin -eq 'Dhcp' }).Count -gt 0

            if ($alreadyDhcp) {
                Write-Host 'LAN nutzt bereits DHCP - keine Aenderung noetig.'
            } else {
                Write-Host 'LAN zurueck auf DHCP ...'
                Clear-LanIPv4 -Index $idx
                Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Enabled -Confirm:$false
                $changed = $true
                Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -Confirm:$false
                if ($lan.Status -eq 'Disabled') {
                    Enable-NetAdapter -InputObject $lan -Confirm:$false
                }
                Restart-NetAdapter -InputObject $lan -Confirm:$false
            }

            if ($wifi) {
                $currentWifi = Get-NetAdapter -Physical | Where-Object { $_.ifIndex -eq $wifi.ifIndex }
                if ($currentWifi.Status -eq 'Disabled') {
                    Write-Host 'WLAN aktivieren ...'
                    Enable-NetAdapter -InputObject $currentWifi -Confirm:$false
                    $changed = $true
                }
            }
        }
    }
} catch {
    if ($changed) {
        Restore-LanConfiguration -Index $idx -Snapshot $snapshot -Wifi $wifi
    }
    throw
}

# --- Ergebnis anzeigen -------------------------------------------------------------------------
if ($Mode -eq 'Dhcp') {
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $v4 = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    } while (@($v4 | Where-Object { $_.PrefixOrigin -eq 'Dhcp' }).Count -eq 0 -and (Get-Date) -lt $deadline)
} else {
    Start-Sleep -Milliseconds 500
    $v4 = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
}

Write-Host ''
$v4 | Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin | Format-Table -AutoSize

if ($wifi) {
    Get-NetAdapter -Physical | Where-Object { $_.ifIndex -eq $wifi.ifIndex } |
        Select-Object Name, Status | Format-Table -AutoSize
}

if ($Mode -eq 'Dhcp' -and @($v4 | Where-Object { $_.PrefixOrigin -eq 'Dhcp' }).Count -eq 0) {
    Write-Warning 'Noch keine DHCP-Adresse erhalten. DHCP kann etwas laenger dauern.'
}
