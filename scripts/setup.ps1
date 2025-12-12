# =============================================================================
# SKRIPT: setup.ps1
# POPIS: Konfigurator prostredi (s interaktivni tabulkou profilu)
# =============================================================================

# 1. NASTAVENI KONZOLE
function global:prompt { "PS " + (Split-Path -Leaf (Get-Location)) + "> " }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Clear-Host
Write-Host "--- KONFIGURACE PROSTREDI (SETUP) ---" -ForegroundColor Cyan

# 2. DEFINICE VYCHOZI STRUKTURY
$Config = [Ordered]@{
    EsxiServer  = "vsphere.esxi"
    Datastore   = "datastore1"
    Network     = "VM Network"      # <--- NOVINKA: Nazev site
    IsoFolder   = "ISOs"            # <--- Slozka na Datastore
    LocalIsoDir = "C:\ISO"
    Profiles = @{
        Low  = @{ RamMB = 2048; CpuCount = 1; DiskGB = 20 }
        Mid  = @{ RamMB = 4096; CpuCount = 2; DiskGB = 50 }
        High = @{ RamMB = 8192; CpuCount = 4; DiskGB = 100 }
    }
}

# 3. PRIPOJENI K SERVERU
$InputServer = Read-Host "`nZadejte nazev/IP adresu ESXi serveru [$($Config.EsxiServer)]"
if (-not [string]::IsNullOrWhiteSpace($InputServer)) { $Config.EsxiServer = $InputServer }

Write-Host "Pripojuji se k serveru..." -ForegroundColor Gray
try {
    if (-not ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected)) { 
        Connect-VIServer -Server $Config.EsxiServer -ErrorAction Stop | Out-Null 
    }
    Write-Host " [OK] Pripojeno." -ForegroundColor Green
}
catch {
    Write-Host " [CHYBA] Server nedostupny. Rezim offline." -ForegroundColor Red
}

# 4. DETEKCE A VYBER DATASTORE (MANUALNI PRISTUP)
if ($global:DefaultVIServer) {
    $CurrentDatastores = Get-Datastore

    # KROK A: Pokud neni zadny datastore -> Vyzva k manualnimu vytvoreni
    # Smycka bezi tak dlouho, dokud se neobjevi aspon jeden datastore
    while ($CurrentDatastores.Count -eq 0) {
        Write-Host "`n[!] Na serveru nebyl nalezen zadny Datastore!" -ForegroundColor Yellow
        Write-Host "    Vase verze ESXi pravdepodobne nepodporuje automaticke formatovani (API Omezeni)." -ForegroundColor Gray
        Write-Host "    AKCE: Jdete na https://$($Config.EsxiServer) a vytvorte datastore manualne." -ForegroundColor Cyan
        
        Read-Host " [Jakmile datastore vytvorite, stisknete ENTER pro pokracovani...]"
        
        # Refresh - zkusime nacist znovu
        $CurrentDatastores = Get-Datastore
        
        if ($CurrentDatastores.Count -eq 0) {
            Write-Host " [CHYBA] Stale neexistuje zadny datastore. Zkuste to znovu." -ForegroundColor Red
        }
    }

    # KROK B: Vyber z existujicich
    Write-Host "`nDostupne datastory:"
    $i = 1
    foreach ($ds in $CurrentDatastores) {
        # Vypiseme nazev a volne misto
        Write-Host " [$i] $($ds.Name) (Volno: $([math]::round($ds.FreeSpaceGB)) GB)"
        $i++
    }

    # Pokud je jen jeden, vybereme ho automaticky, ale vypiseme zpravu
    if ($CurrentDatastores.Count -eq 1) {
        $Config.Datastore = $CurrentDatastores[0].Name
        Write-Host " [OK] Automaticky vybran jediny datastore: $($Config.Datastore)" -ForegroundColor Green
    } 
    else {
        # Pokud je jich vic, musi si uzivatel vybrat
        $Ch = Read-Host "Vyberte cislo datastore (Enter = 1)"
        if (-not [string]::IsNullOrWhiteSpace($Ch) -and $CurrentDatastores[$Ch-1]) {
            $Config.Datastore = $CurrentDatastores[$Ch-1].Name
        } else { 
            $Config.Datastore = $CurrentDatastores[0].Name 
        }
        Write-Host " [OK] Vybran datastore: $($Config.Datastore)" -ForegroundColor Green
    }
}

# 5. KONFIGURACE HARDWAROVYCH PROFILU (S VALIDACI VSTUPU)
Write-Host "`n--- HARDWAROVE PROFILY ---" -ForegroundColor Cyan

# Pomocna funkce pro bezpecne nacteni cisla
function Read-IntSafe {
    param ($Label, $DefaultVal)
    while ($true) {
        $InputStr = Read-Host "$Label [$DefaultVal]"
        
        # 1. Uzivatel jen mackl Enter -> vracime puvodni hodnotu
        if ([string]::IsNullOrWhiteSpace($InputStr)) { return $DefaultVal }

        # 2. Zkusime prevest na cislo
        try {
            $Result = [int]$InputStr
            # Kontrola, ze cislo je kladne
            if ($Result -gt 0) { return $Result }
            else { Write-Host "     [!] Hodnota musi byt vetsi nez 0." -ForegroundColor Red }
        }
        catch {
            Write-Host "     [!] Neplatny vstup. Zadejte pouze cislo (napr. 2048)." -ForegroundColor Red
        }
    }
}

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

$Editing = $true
while ($Editing) {
    Write-Host ""
    Show-ProfileTable -Conf $Config
    
    Write-Host "Moznosti: [L]ow, [M]id, [H]igh nebo [Enter] pro pokracovani" -ForegroundColor Yellow
    $Choice = Read-Host "Ktery profil upravit?"
    
    # Resetujeme cil pro jistotu
    $EditTarget = $null

    switch ($Choice.ToUpper()) {
        "L" { $EditTarget = "Low" }
        "M" { $EditTarget = "Mid" }
        "H" { $EditTarget = "High" }
        ""  { $Editing = $false } # Enter ukonci smycku
        Default { 
            Write-Host " [!] Neplatna volba '$Choice'. Zkuste to znovu." -ForegroundColor Red 
        }
    }

    # Editační logiku spustime JEN pokud mame platny cil A stale editujeme
    if ($Editing -and $EditTarget) {
        $Current = $Config.Profiles.$EditTarget
        Write-Host "Uprava profilu $EditTarget (Enter = Puvodni hodnota):" -ForegroundColor Gray
        
        $Config.Profiles.$EditTarget.RamMB    = Read-IntSafe -Label " - RAM (MB)"    -DefaultVal $Current.RamMB
        $Config.Profiles.$EditTarget.CpuCount = Read-IntSafe -Label " - CPU (Jadra)" -DefaultVal $Current.CpuCount
        $Config.Profiles.$EditTarget.DiskGB   = Read-IntSafe -Label " - Disk (GB)"   -DefaultVal $Current.DiskGB
        
        Write-Host " [OK] Profil $EditTarget aktualizovan." -ForegroundColor Green
    }
}

# 6. CESTY A SITE (INTERAKTIVNI VYBER)
Write-Host "`n--- SYSTEMOVA NASTAVENI ---" -ForegroundColor Cyan

# A) KONFIGURACE SITE
if ($global:DefaultVIServer) {
    Write-Host "Nacitam dostupne site (Port Groups)..." -ForegroundColor Gray
    $PortGroups = Get-VirtualPortGroup | Sort-Object Name
    $DoCreateNew = $false 

    if ($PortGroups.Count -gt 0) {
        # --- CHYTRA DETEKCE DEFAULTU ---
        # 1. Zkusime najit sit, kterou uz mame v configu
        $DefaultPg = $PortGroups | Where-Object { $_.Name -eq $Config.Network } | Select-Object -First 1
        
        # 2. Pokud neni v configu, hledame standardni "VM Network"
        if (-not $DefaultPg) {
            $DefaultPg = $PortGroups | Where-Object { $_.Name -eq "VM Network" } | Select-Object -First 1
        }
        
        # 3. Pokud neni ani ta, vezmeme prvni v seznamu
        if (-not $DefaultPg) { $DefaultPg = $PortGroups[0] }

        # --- VYPIS ---
        Write-Host "`nExistujici site na serveru:"
        $i = 1
        $DefaultIndex = 1
        foreach ($pg in $PortGroups) {
            # Zjistime, jestli je tato sit nase defaultni, abychom si ulozili jeji cislo
            if ($pg.Name -eq $DefaultPg.Name) { $DefaultIndex = $i }
            
            Write-Host " [$i] $($pg.Name) (VLAN: $($pg.VlanId))"
            $i++
        }
        
        Write-Host " [N] Vytvorit NOVOU sit (s nastavenim VLAN)" -ForegroundColor Yellow
        
        # --- VOLBA ---
        $NetChoice = Read-Host "`nVyberte moznost (Enter = $DefaultIndex - $($DefaultPg.Name))"
        
        # --- VYHODNOCENI ---
        if ([string]::IsNullOrWhiteSpace($NetChoice)) {
            # Uzivatel dal jen Enter -> Pouzijeme default
            $Config.Network = $DefaultPg.Name
            Write-Host " [OK] Automaticky vybrana sit: $($DefaultPg.Name)" -ForegroundColor Green
        }
        elseif ($NetChoice.ToUpper() -eq "N") {
            $DoCreateNew = $true
        }
        elseif ($PortGroups[$NetChoice-1]) {
            # Uzivatel zadal cislo
            $SelectedPg = $PortGroups[$NetChoice-1]
            $Config.Network = $SelectedPg.Name
            Write-Host " [OK] Vybrana sit: $($SelectedPg.Name)" -ForegroundColor Green
        }
        else {
            Write-Host " [!] Neplatna volba, pouzivam default." -ForegroundColor Yellow
            $Config.Network = $DefaultPg.Name
        }
    }
    else {
        # SCENAR 2: Zadné site nenalezeny
        Write-Host "`n [!] Na serveru nebyly nalezeny zadne Port Groups." -ForegroundColor Yellow
        Write-Host " Je nutne vytvorit alespon jednu sit." -ForegroundColor Gray
        $DoCreateNew = $true
    }

    # Logika pro vytvoreni site
    if ($DoCreateNew) {
        $NewNetName = Read-Host "`nZadejte nazev nove site (napr. VM Network)"
        if (-not [string]::IsNullOrWhiteSpace($NewNetName)) {
            $VlanIn = Read-Host "Zadejte VLAN ID (0 = bez tagovani, Enter = 0)"
            if ([string]::IsNullOrWhiteSpace($VlanIn)) { $Vid = 0 } else { $Vid = [int]$VlanIn }
            
            try {
                $vSwitch = Get-VirtualSwitch | Select-Object -First 1
                if ($vSwitch) {
                    Write-Host "Vytvarim sit '$NewNetName' (VLAN $Vid) na switchi $($vSwitch.Name)..." -ForegroundColor Gray
                    New-VirtualPortGroup -VirtualSwitch $vSwitch -Name $NewNetName -VLanId $Vid -ErrorAction Stop | Out-Null
                    Write-Host " [OK] Sit vytvorena." -ForegroundColor Green
                    $Config.Network = $NewNetName
                } else {
                    Write-Host " [CHYBA] Nenalezen zadny virtualni switch (vSwitch)!" -ForegroundColor Red
                }
            }
            catch { Write-Host " [CHYBA] $_" -ForegroundColor Red }
        }
    }

} else {
    # Fallback pro offline rezim
    $InputNet = Read-Host "Nazev site pro VM (Port Group) [$($Config.Network)]"
    if (-not [string]::IsNullOrWhiteSpace($InputNet)) { $Config.Network = $InputNet }
}

# B) SLOZKY PRO ISO
# Lokalni
$InputIso = Read-Host "`nSlozka pro ISO soubory v PC [$($Config.LocalIsoDir)]"
if (-not [string]::IsNullOrWhiteSpace($InputIso)) { $Config.LocalIsoDir = $InputIso }

if (-not (Test-Path $Config.LocalIsoDir)) {
    Write-Host "Vytvarim slozku '$($Config.LocalIsoDir)'..." -ForegroundColor Gray
    New-Item -ItemType Directory -Path $Config.LocalIsoDir | Out-Null
}

# Vzdalena (ESXi)
$InputRemote = Read-Host "Nazev slozky na Datastore pro ISO [$($Config.IsoFolder)]"
if (-not [string]::IsNullOrWhiteSpace($InputRemote)) { $Config.IsoFolder = $InputRemote }
# 7. ULOZENI DO SOUBORU
$ConfigDir  = ".\config"
$ConfigFile = "config.json"
$FullPath   = Join-Path $ConfigDir $ConfigFile

if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }

$JsonPayload = $Config | ConvertTo-Json -Depth 5
try {
    Set-Content -Path $FullPath -Value $JsonPayload -Encoding UTF8 -Force
    Write-Host "`n[OK] Konfigurace ulozena: $FullPath" -ForegroundColor Green
} catch { Write-Host " [CHYBA] $_" -ForegroundColor Red }