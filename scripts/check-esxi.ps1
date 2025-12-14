<#
.SYNOPSIS
   PREHLED ESXi SERVERU (DASHBOARD)
#>

# =============================================================================
# POPIS:  Diagnosticky nastroj pro rychlou kontrolu infrastruktury.
#         Vypisuje vyuziti prostredku, volne misto na discich a stavy VM.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. NASTAVENI A KONFIGURACE
# -----------------------------------------------------------------------------

$ConfigFile = Join-Path $PSScriptRoot "config\config.json"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

Clear-Host
Write-Host "--- PREHLED ESXi SERVERU ---" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 2. NACTENI KONFIGURACE
# -----------------------------------------------------------------------------
if (Test-Path $ConfigFile) {
    try {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    } catch { Write-Host " [CHYBA] Soubor config.json je poskozeny." -ForegroundColor Red; exit }
} else {
    Write-Host " [CHYBA] Config nenalezen!" -ForegroundColor Red
    Write-Host "         Hledal jsem zde: $ConfigFile" -ForegroundColor Gray
    Write-Host "         Spustte nejprve 'setup.ps1'." -ForegroundColor Yellow
    exit
}

# -----------------------------------------------------------------------------
# 3. PRIPOJENI K SERVERU
# -----------------------------------------------------------------------------
if (-not ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected)) {
    Write-Host " Pripojuji k $($Config.EsxiServer)..." -ForegroundColor Gray
    try {
        Connect-VIServer -Server $Config.EsxiServer -ErrorAction Stop | Out-Null
    } catch {
        Write-Host " [FATAL] Nelze se pripojit k serveru!" -ForegroundColor Red
        Write-Host " Duvod: $_" -ForegroundColor Yellow
        exit
    }
}

# -----------------------------------------------------------------------------
# 4. INFO O HOST SYSTEMU (Fyzicky server)
# -----------------------------------------------------------------------------
$VMHost = Get-VMHost
$HostCpuUsage = [math]::Round($VMHost.CpuUsageMhz / $VMHost.CpuTotalMhz * 100, 1)
$HostMemUsage = [math]::Round($VMHost.MemoryUsageGB / $VMHost.MemoryTotalGB * 100, 1)

Write-Host "`n [1] SYSTEMOVE PROSTREDKY (HOST)" -ForegroundColor Yellow
Write-Host " -----------------------------------------------------------" -ForegroundColor DarkGray
Write-Host " Server:       " -NoNewline; Write-Host $VMHost.Name -ForegroundColor White
Write-Host " Verze:        " -NoNewline; Write-Host "$($VMHost.Version) (Build $($VMHost.Build))" -ForegroundColor Gray
Write-Host " Model:        " -NoNewline; Write-Host $VMHost.Model -ForegroundColor Gray
Write-Host " CPU Vyuziti:  " -NoNewline; Write-Host "$HostCpuUsage %" -ForegroundColor ($HostCpuUsage -gt 80 ? "Red" : "Green")
Write-Host " RAM Vyuziti:  " -NoNewline; Write-Host "$HostMemUsage % ($([math]::Round($VMHost.MemoryUsageGB,1)) / $([math]::Round($VMHost.MemoryTotalGB,1)) GB)" -ForegroundColor ($HostMemUsage -gt 90 ? "Red" : "Green")
Write-Host " -----------------------------------------------------------" -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# 5. KONTROLA ULOZIST (DATASTORES)
# -----------------------------------------------------------------------------
Write-Host "`n [2] ULOZISTE (DATASTORES)" -ForegroundColor Yellow
$Datastores = Get-Datastore | Sort-Object Name

# Priprava dat
$DSList = @()
foreach ($ds in $Datastores) {
    if ($ds.CapacityGB -gt 0) {
        $FreePercent = [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 1)
    } else {
        $FreePercent = 0
    }
    
    # Logika stavů
    if ($FreePercent -lt 25) { 
        # 0% - 25% volného místa
        $Status = "KRITICKE!" 
    }
    elseif ($FreePercent -lt 75) { 
        # 25% - 75% volného místa
        $Status = "OK" 
    }
    else { 
        # 75% - 100% volného místa
        $Status = "NEVYUZITO" 
    }

    $DSList += [PSCustomObject]@{
        NAZEV           = $ds.Name
        "KAPACITA (GB)" = [math]::Round($ds.CapacityGB, 1)
        "VOLNO (GB)"    = [math]::Round($ds.FreeSpaceGB, 1)
        "VOLNO (%)"     = "$FreePercent %"
        STAV            = $Status
    }
}

# --- Vykreslení kompaktní tabulky ---

# 1. Hlavička
# Upraveno: NAZEV (-15), KAPACITA (10), VOLNO (10), VOLNO (%) (11), STAV (10)
Write-Host ("{0,-15} {1,10} {2,10} {3,11} {4,10}" -f "NAZEV", "KAPACITA", "VOLNO", "VOLNO (%)", "STAV")
Write-Host ("-" * 60)

# 2. Výpis řádků
foreach ($row in $DSList) {
    # Určení barvy
    if ($row.STAV -eq "KRITICKE!") {
        $Color = "Red"
    } elseif ($row.STAV -eq "PLNE") {
        $Color = "Yellow"
    } else {
        $Color = "Green"
    }

    Write-Host ("{0,-15} {1,10} {2,10} {3,11} " -f $row.NAZEV, $row."KAPACITA (GB)", $row."VOLNO (GB)", $row."VOLNO (%)") -NoNewline
    
    # Stav barevně
    Write-Host ("{0,10}" -f $row.STAV) -ForegroundColor $Color
}

# -----------------------------------------------------------------------------
# 6. KONTROLA VIRTUALNICH STROJU
# -----------------------------------------------------------------------------
Write-Host "`n [3] VIRTUALNI STROJE (VMs)" -ForegroundColor Yellow
$VMs = Get-VM | Sort-Object Name

if ($VMs.Count -eq 0) {
    Write-Host " Zadne VM nenalezeny." -ForegroundColor Gray
} else {
    $VMList = @()
    foreach ($vm in $VMs) {
        $IP = if ($vm.Guest.IPAddress) { $vm.Guest.IPAddress[0] } else { "---" }
        
        if ($vm.PowerState -eq "PoweredOn") { $State = "BEZI" } else { $State = "VYPNUTO" }

        $VMList += [PSCustomObject]@{
            NAZEV     = $vm.Name
            STAV      = $State
            CPU       = $vm.NumCpu
            "RAM (MB)" = [int]$vm.MemoryMB
            IP_ADRESA = $IP
        }
    }
    $VMList | Format-Table -AutoSize
}

Write-Host "`n Kontrola dokoncena." -ForegroundColor Cyan