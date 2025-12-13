# =============================================================================
# SKRIPT: setup.ps1
# POPIS: Konfiguracni pruvodce pro pripravu prostredi pred nasazenim VM.
#        Skript generuje soubor 'config.json', ktery slouzi jako vstup pro
#        instalacni skript. Resi pripojeni k ESXi, spravu uloziste a siti.
# AUTOR: Jakub Moravec
# DATUM: 2025
# =============================================================================

# -----------------------------------------------------------------------------
# 0. KONTROLA PROSTREDI
# -----------------------------------------------------------------------------
# Vyaduje PowerShell Core (verze 7.0 a vyssi) kvuli modernim funkcim a kompatibilite.
$MinVersion = [Version]"7.0"
if ($PSVersionTable.PSVersion -lt $MinVersion) {
    Write-Host " [!] Tento skript vyzaduje PowerShell $MinVersion a novejsi." -ForegroundColor Red; exit
}

# -----------------------------------------------------------------------------
# 1. POMOCNE FUNKCE A NASTAVENI
# -----------------------------------------------------------------------------
function global:prompt { "PS " + (Split-Path -Leaf (Get-Location)) + "> " }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Funkce: Read-IntSafe
# Ucel:   Zajistuje bezpecne nacitani ciselnych vstupu od uzivatele.
#         Zabrani padu skriptu, pokud uzivatel zada text misto cisla.
function Read-IntSafe {
    param ($Label, $DefaultVal)
    while ($true) {
        $InputStr = Read-Host "$Label [$DefaultVal]"
        if ([string]::IsNullOrWhiteSpace($InputStr)) { return $DefaultVal }
        try {
            $Result = [int]$InputStr
            if ($Result -ge 0) { return $Result }
        } catch {}
        Write-Host "     [!] Zadejte kladne cislo." -ForegroundColor Red
    }
}

# Funkce: Show-ProfileTable
# Ucel:   Vykresli prehlednou tabulku hardwarovych profilu (CPU/RAM/Disk).
function Show-ProfileTable {
    param($Conf)
    $TableData = @()
    foreach ($key in "Low", "Mid", "High") {
        $p = $Conf.Profiles.$key
        $TableData += [PSCustomObject]@{
            Profil    = $key
            RAM_MB    = $p.RamMB
            CPU_Jadra = $p.CpuCount
            Disk_GB   = $p.DiskGB
        }
    }
    $TableData | Format-Table -AutoSize
}

Clear-Host
Write-Host "--- KONFIGURACE PROSTREDI (SETUP) ---" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 2. DEFINICE SABLONY KONFIGURACE
# -----------------------------------------------------------------------------
# Vytvarime objekt $Config s vychozimi hodnotami. Tyto hodnoty budou
# v prubehu skriptu upravovany podle voleb uzivatele.
$Config = [Ordered]@{
    EsxiServer = "vsphere.esxi"
    Datastore  = "datastore1"
    Network    = "VM Network"
    IsoFolder  = "ISOs"
    LocalIsoDir = "C:\ISO"
    Profiles = @{
        Low  = @{ RamMB = 2048; CpuCount = 1; DiskGB = 20 }
        Mid  = @{ RamMB = 4096; CpuCount = 2; DiskGB = 50 }
        High = @{ RamMB = 8192; CpuCount = 4; DiskGB = 100 }
    }
}

# -----------------------------------------------------------------------------
# 3. PRIPOJENI K ESXi SERVERU
# -----------------------------------------------------------------------------
$InputServer = Read-Host "`nZadejte nazev/IP adresu ESXi serveru [$($Config.EsxiServer)]"
if (-not [string]::IsNullOrWhiteSpace($InputServer)) { $Config.EsxiServer = $InputServer }

Write-Host "Pripojuji se k serveru..." -ForegroundColor Gray
try {
    # Kontrola, zda uz nejsme pripojeni, abychom nezdrzovali
    if (-not ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected)) { 
        Connect-VIServer -Server $Config.EsxiServer -ErrorAction Stop | Out-Null 
    }
    Write-Host " [OK] Pripojeno." -ForegroundColor Green
}
catch { Write-Host " [CHYBA] Server nedostupny." -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 4. DETEKCE DISKU A VYBER DATASTORE
# -----------------------------------------------------------------------------
# Tato sekce resi vyber uloziste pro VM. Umoznuje vybrat existujici datastore
# nebo vytvorit novy z volnych fyzickych disku.
if ($global:DefaultVIServer) {
    while ($true) {
        # Nacteni existujicich datastore
        $CurrentDatastores = Get-Datastore | Sort-Object Name
        
        Write-Host "`nExistujici uloziste (Datastores):" -ForegroundColor Cyan
        $i = 1
        if ($CurrentDatastores.Count -gt 0) {
            foreach ($ds in $CurrentDatastores) {
                Write-Host " [$i] $($ds.Name) (Volno: $([math]::round($ds.FreeSpaceGB)) GB)"
                $i++
            }
        } else { Write-Host " [!] Zadne uloziste nenalezeno." -ForegroundColor Yellow }

        Write-Host " [N] Vytvorit NOVY Datastore (Zobrazit volne disky)" -ForegroundColor Magenta
        
        $Choice = Read-Host "`nVyberte moznost (Cislo nebo 'N')"
        
        # --- LOGIKA A: VYTVORENI NOVEHO DATASTORE ---
        if ($Choice.ToUpper() -eq "N") {
            Write-Host "Analyzuji disky..." -ForegroundColor Gray
            $VMHost = Get-VMHost
            
            # 1. Zjisteni systemoveho disku (Boot Device) pomoci ESXCLI
            # Toto je bezpecnostni prvek, abychom omylem nesmazali disk s OS ESXi.
            try {
                $EsxCli = Get-EsxCli -VMHost $VMHost -V2
                $BootInfo = $EsxCli.system.boot.device.get.Invoke()
                $BootDevName = $BootInfo.deviceName
            } catch { $BootDevName = "UNKNOWN" }

            # 2. Zjisteni disku, ktere uz jsou soucasti jinych datastore
            $UsedLunNames = @()
            foreach ($ds in $CurrentDatastores) {
                $Extents = $ds.ExtensionData.Info.Vmfs.Extent
                if ($Extents) { foreach ($ex in $Extents) { $UsedLunNames += $ex.DiskName } }
            }

            # 3. Nacteni vsech fyzickych disku (LUNs)
            $AllLuns = Get-ScsiLun -VmHost $VMHost -LunType disk
            
            Write-Host "`nSEZNAM FYZICKYCH DISKU:" -ForegroundColor Cyan
            $k = 1
            $SelectableLuns = @{}

            foreach ($lun in $AllLuns) {
                $CapGB = [math]::round($lun.CapacityGB, 2)
                $IsSafe = $true
                
                # Porovnani ID disku s BootDevice a seznamem pouzitych
                $IsSystem = ($lun.CanonicalName -match $BootDevName)
                $IsUsed = $UsedLunNames -contains $lun.CanonicalName

                # Nastaveni barev a stitku pro uzivatele
                if ($IsSystem) {
                    $Status = "[SYSTEM - BOOT?]"
                    $Color = "Red"; $IsSafe = $false
                }
                elseif ($IsUsed) {
                    $Status = "[DATA - POUZIT]"
                    $Color = "Yellow"; $IsSafe = $false
                }
                else {
                    $Status = "[VOLNY - RAW]"
                    $Color = "Green"
                }

                Write-Host " [$k] $Status Model: $($lun.Model) | Kapacita: $CapGB GB" -ForegroundColor $Color
                Write-Host "     ID: $($lun.CanonicalName)" -ForegroundColor DarkGray
                
                # Ulozeni do pomocne tabulky pro pozdejsi vyber
                $SelectableLuns[$k] = @{ Lun = $lun; IsSafe = $IsSafe; IsSystem = $IsSystem }
                $k++
            }

            # Vyber disku uzivatelem
            $LunIndex = Read-IntSafe -Label "Vyberte cislo disku k naformatovani" -DefaultVal 0
            
            if ($SelectableLuns.ContainsKey($LunIndex)) {
                $Selection = $SelectableLuns[$LunIndex]
                $SelectedLun = $Selection.Lun
                
                # Bezpecnostni varovani (Override)
                if ($Selection.IsSystem) {
                    Write-Host "`n [!!! VAROVANI - SYSTEMOVY DISK !!!]" -ForegroundColor Red
                    $Confirm = Read-Host "Pokud jste si jisti, ze je to volny disk, napiste 'SMAZAT'"
                    if ($Confirm -ne "SMAZAT") { continue }
                    Write-Host " [OK] Ochrana potlacena." -ForegroundColor Magenta
                }
                elseif (-not $Selection.IsSafe) {
                     Write-Host " [POZOR] Disk je jiz pouzivan." -ForegroundColor Yellow
                     if ((Read-Host "Premazat? [A]no/[N]e").ToUpper() -ne "A") { continue }
                }

                # Vytvoreni datastore (Formatovani na VMFS 6)
                $NewDsName = Read-Host "Zadejte nazev noveho datastore (napr. datastore1)"
                if (-not [string]::IsNullOrWhiteSpace($NewDsName)) {
                    try {
                        Write-Host "Vytvarim datastore '$NewDsName'..." -ForegroundColor Yellow
                        New-Datastore -VmHost $VMHost -Name $NewDsName -Path $SelectedLun.CanonicalName -FileSystem 6 -ErrorAction Stop | Out-Null
                        Write-Host " [OK] Hotovo." -ForegroundColor Green
                    } catch { Write-Host " [CHYBA] $_" -ForegroundColor Red }
                }
            }
        }
        # --- LOGIKA B: VYBER EXISTUJICIHO ---
        elseif ($Choice -match "^\d+$" -and $CurrentDatastores[$Choice-1]) {
            $Config.Datastore = $CurrentDatastores[$Choice-1].Name
            Write-Host " [OK] Vybran: $($Config.Datastore)" -ForegroundColor Green
            break 
        }
        else {
             # Automaticky vyber pokud uzivatel jen odklepne Enter
             if ([string]::IsNullOrWhiteSpace($Choice) -and $CurrentDatastores.Count -gt 0) {
                 $Config.Datastore = $CurrentDatastores[0].Name
                 Write-Host " [OK] Automaticky vybran: $($Config.Datastore)" -ForegroundColor Green
                 break
             }
        }
    }
}

# -----------------------------------------------------------------------------
# 5. EDITACE HARDWAROVYCH PROFILU
# -----------------------------------------------------------------------------
# Umoznuje upravit parametry (RAM, CPU, HDD) pro jednotlive velikosti VM.
Write-Host "`n--- HARDWAROVE PROFILY ---" -ForegroundColor Cyan
$Editing = $true
while ($Editing) {
    Write-Host ""
    Show-ProfileTable -Conf $Config
    Write-Host "Moznosti: [L]ow, [M]id, [H]igh nebo [Enter] pro pokracovani" -ForegroundColor Yellow
    $Choice = Read-Host "Ktery profil upravit?"
    $EditTarget = $null
    
    switch ($Choice.ToUpper()) {
        "L" { $EditTarget = "Low" }
        "M" { $EditTarget = "Mid" }
        "H" { $EditTarget = "High" }
        ""  { $Editing = $false }
    }
    
    if ($Editing -and $EditTarget) {
        $Current = $Config.Profiles.$EditTarget
        $Config.Profiles.$EditTarget.RamMB    = Read-IntSafe -Label " - RAM (MB)"    -DefaultVal $Current.RamMB
        $Config.Profiles.$EditTarget.CpuCount = Read-IntSafe -Label " - CPU (Jadra)" -DefaultVal $Current.CpuCount
        $Config.Profiles.$EditTarget.DiskGB   = Read-IntSafe -Label " - Disk (GB)"   -DefaultVal $Current.DiskGB
        Write-Host " [OK] Aktualizovano." -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# 6. NASTAVENI SITI A CEST
# -----------------------------------------------------------------------------
Write-Host "`n--- SYSTEMOVA NASTAVENI ---" -ForegroundColor Cyan

# A) Konfigurace site (Port Groups)
if ($global:DefaultVIServer) {
    # Zajistime, ze se snazime primarne nabidnout "VM Network"
    if ($Config.Network -ne "VM Network") {
         $CheckPg = Get-VirtualPortGroup -Name "VM Network" -ErrorAction SilentlyContinue
         if ($CheckPg) { $Config.Network = "VM Network" }
    }

    # Cyklus pro spravu siti (umoznuje vytvorit novou a hned ji videt v seznamu)
    while ($true) {
        Write-Host "`nNacitam site..." -ForegroundColor Gray
        $PortGroups = Get-VirtualPortGroup | Sort-Object Name
        
        # Logika pro nalezeni vychozi site v seznamu
        $DefaultPg = ($PortGroups | Where-Object Name -eq $Config.Network)
        if (-not $DefaultPg) { $DefaultPg = ($PortGroups | Where-Object Name -eq "VM Network") }
        if (-not $DefaultPg) { $DefaultPg = $PortGroups[0] }

        Write-Host "Dostupne site:"
        $i = 1; $DefaultIndex = 1
        if ($PortGroups.Count -gt 0) {
            foreach ($pg in $PortGroups) {
                if ($DefaultPg -and $pg.Name -eq $DefaultPg.Name) { $DefaultIndex = $i }
                Write-Host " [$i] $($pg.Name) (VLAN: $($pg.VlanId))"
                $i++
            }
        } else { Write-Host " [!] Zadne site." -ForegroundColor Yellow }
        
        Write-Host " [N] Nova sit" -ForegroundColor Yellow
        
        $NetChoice = Read-Host "Vyber (Enter = $DefaultIndex - $($DefaultPg.Name))"
        
        if ([string]::IsNullOrWhiteSpace($NetChoice)) { 
            # Uzivatel stiskl Enter -> Pouzijeme default
            if ($DefaultPg) {
                $Config.Network = $DefaultPg.Name
                Write-Host " [OK] Vybrana sit: $($Config.Network)" -ForegroundColor Green
                break
            }
        }
        elseif ($NetChoice.ToUpper() -eq "N") {
            # Vytvoreni nove site s VLAN ID
            $NewNetName = Read-Host "Nazev site"; $Vid = Read-IntSafe "VLAN ID" 0
            try {
                New-VirtualPortGroup -VirtualSwitch (Get-VirtualSwitch|Select -First 1) -Name $NewNetName -VLanId $Vid -ErrorAction Stop | Out-Null
                Write-Host " [OK] Vytvoreno. Aktualizuji seznam..." -ForegroundColor Green
            } catch { Write-Host " [CHYBA] $_" -ForegroundColor Red }
        }
        elseif ($ChoiceNum = [int]$NetChoice -as [int]) {
            # Uzivatel vybral cislo
            if ($PortGroups[$ChoiceNum-1]) { 
                $Config.Network = $PortGroups[$ChoiceNum-1].Name 
                Write-Host " [OK] Vybrana sit: $($Config.Network)" -ForegroundColor Green
                break
            } else { Write-Host " [!] Neplatne cislo." -ForegroundColor Red }
        }
        else { Write-Host " [!] Neplatna volba." -ForegroundColor Red }
    }
}

# B) Cesty k ISO souborum
$InputIso = Read-Host "`nSlozka pro ISO v PC [$($Config.LocalIsoDir)]"
if (-not [string]::IsNullOrWhiteSpace($InputIso)) { $Config.LocalIsoDir = $InputIso }
if (-not (Test-Path $Config.LocalIsoDir)) { New-Item -ItemType Directory -Path $Config.LocalIsoDir | Out-Null }

$InputRemote = Read-Host "Slozka na Datastore pro ISO [$($Config.IsoFolder)]"
if (-not [string]::IsNullOrWhiteSpace($InputRemote)) { $Config.IsoFolder = $InputRemote }

# -----------------------------------------------------------------------------
# 7. ULOZENI KONFIGURACE (EXPORT)
# -----------------------------------------------------------------------------
# Ulozi vsechna nastaveni do JSON souboru pro pouziti v dalsim kroku (instalace).
$ConfigDir = ".\config"; if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
$FullPath = Join-Path $ConfigDir "config.json"
$Config | ConvertTo-Json -Depth 5 | Set-Content -Path $FullPath -Encoding UTF8 -Force

Write-Host "`n[OK] Ulozeno: $FullPath" -ForegroundColor Green