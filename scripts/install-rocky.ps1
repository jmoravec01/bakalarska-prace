# =============================================================================
# SKRIPT: Install-Rocky.ps1
# POPIS: Interaktivni pruvodce pro nasazeni Rocky Linux na ESXi
# AUTOR: Bakalarska prace
# =============================================================================

# 1. KOSMETICKA UPRAVA KONZOLE (PRO SCREENSHOTY)
# Zkrati cestu v prikazovem radku na: "PS scripts> "
function global:prompt { "PS " + (Split-Path -Leaf (Get-Location)) + "> " }

Clear-Host
Write-Host "--- PRUVODCE NASAZENIM ROCKY LINUX ---" -ForegroundColor Cyan

# 2. KONTROLA SPOJENI S SERVEREM (Lazy Initialization)
if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
    Write-Host " [OK] Detekovano aktivni spojeni: $($global:DefaultVIServer.Name)" -ForegroundColor Green
}
else {
    Write-Host " [INFO] Zadna relace. Zkousim se pripojit k 'esxi'..." -ForegroundColor Yellow
    try {
        # Pokud nejsme pripojeni, provedeme pripojeni nyni (vyzve k heslu nebo pouzije cache)
        Connect-VIServer -Server "esxi" -ErrorAction Stop
        Write-Host " [OK] Uspesne pripojeno." -ForegroundColor Green
    }
    catch {
        Write-Host " [CHYBA] Server 'esxi' je nedostupny." -ForegroundColor Red
        Write-Host " Detail chyby: $_" -ForegroundColor Gray
        exit 
    }
}

Write-Host "`nKontaktuji repozitare a zjistuji dostupne verze..." -ForegroundColor Gray

# 3. FUNKCE PRO ZJISTENI VERZI Z WEBU
function Get-RockyVersion {
    param ($MajorVer)
    $Url = "https://download.rockylinux.org/pub/rocky/$MajorVer/isos/x86_64/"
    try {
        $Content = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
        # Regex pro nalezeni verze (napr. Rocky-9.5-...)
        if ($Content.Content -match "Rocky-$MajorVer\.(\d+)-") {
            return "$MajorVer.$($Matches[1])"
        }
        return "$MajorVer.x (neznama)"
    }
    catch {
        return "$MajorVer.x (nedostupna)"
    }
}

# Nacteni verzi
$Ver10 = Get-RockyVersion -MajorVer "10"
$Ver9  = Get-RockyVersion -MajorVer "9"
$Ver8  = Get-RockyVersion -MajorVer "8"

# 4. INTERAKTIVNI MENU - VYBER VERZE
Write-Host "`nDostupne verze systemu:"
Write-Host " [1] Rocky Linux $Ver10 (Novinka - Next Gen, podpora 2035)" -ForegroundColor Magenta
Write-Host " [2] Rocky Linux $Ver9  (Standard - Enterprise, podpora 2032)" -ForegroundColor Green
Write-Host " [3] Rocky Linux $Ver8  (Legacy - Starsi, podpora 2029)" -ForegroundColor Gray

$VerChoice = Read-Host "`nVyberte verzi (1-3)"
switch ($VerChoice) {
    "1" { $SelectedMajor = "10"; $SelectedFullVer = $Ver10 }
    "2" { $SelectedMajor = "9";  $SelectedFullVer = $Ver9 }
    "3" { $SelectedMajor = "8";  $SelectedFullVer = $Ver8 }
    Default { Write-Host "Neplatna volba. Koncim."; exit }
}

# 5. VYBER EDICE
Write-Host "`nVyberte typ obrazu:"
Write-Host " [M] Minimal (Doporuceno pro servery, cca 1.5 GB)" -ForegroundColor Cyan
Write-Host " [D] DVD / GUI (S grafickym rozhranim, cca 10 GB)" -ForegroundColor Gray

$TypeChoice = Read-Host "`nVase volba (M/D)"
if ($TypeChoice -eq "D") { $IsoType = "dvd"; $IsoSuffix = "dvd" } 
else { $IsoType = "minimal"; $IsoSuffix = "minimal" }

# 6. KONFIGURACE CEST
$IsoFileName = "Rocky-$SelectedMajor-latest-x86_64-$IsoSuffix.iso"
$DownloadUrl = "https://download.rockylinux.org/pub/rocky/$SelectedMajor/isos/x86_64/$IsoFileName"
$LocalPath = "C:\ISO\$IsoFileName"     # Kam se to stahne do PC
$DatastoreName = "datastore1"          # Nazev uloziste na ESXi
$DatastoreIsoFolder = "ISOs"           # Slozka na ESXi

Write-Host "`n--- Konfigurace ---"
Write-Host "System: Rocky Linux $SelectedFullVer ($IsoType)"
Write-Host "Zdroj: $DownloadUrl"

# 7. STAZENI ISO (pokud neni lokalne)
if (-not (Test-Path $LocalPath)) {
    Write-Host "Stahuji ISO (cekejte prosim)..." -ForegroundColor Yellow
    $Dir = [System.IO.Path]::GetDirectoryName($LocalPath)
    if (!(Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
    
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $LocalPath
    Write-Host "Stazeno." -ForegroundColor Green
} else {
    Write-Host "ISO jiz existuje lokalne." -ForegroundColor Green
}

# 8. UPLOAD NA ESXI (pokud tam neni)
$DatastoreObj = Get-Datastore -Name $DatastoreName
# Namapovani datastore jako virtualniho disku 'ds:'
New-PSDrive -Name "ds" -PSProvider VimDatastore -Root "\" -Location $DatastoreObj -ErrorAction SilentlyContinue | Out-Null
$RemotePath = "ds:\$DatastoreIsoFolder\$IsoFileName"

# Vytvoreni slozky na serveru
if (!(Test-Path "ds:\$DatastoreIsoFolder")) { New-Item -ItemType Directory -Path "ds:\$DatastoreIsoFolder" | Out-Null }

if (-not (Test-Path $RemotePath)) {
    Write-Host "Nahravam ISO na ESXi (pres sit)..." -ForegroundColor Yellow
    Copy-DatastoreItem -Item $LocalPath -Destination $RemotePath -Force
    Write-Host "Nahrano." -ForegroundColor Green
} else {
    Write-Host "ISO jiz na serveru existuje." -ForegroundColor Green
}

# Uklid mapovani
Remove-PSDrive -Name "ds" -ErrorAction SilentlyContinue

# 9. VYTVORENI VM
$VMNameInput = Read-Host "`nZadejte nazev serveru (napr. Rocky-Web)"
if ([string]::IsNullOrWhiteSpace($VMNameInput)) { $VMNameInput = "Rocky-$SelectedMajor-VM" }

# Logika GuestID: Pokud je to verze 10 a ESXi ji nezna, pouzijeme ID pro verzi 9
if ($SelectedMajor -eq "10") { $GuestID = "rhel9_64Guest" } 
else { $GuestID = "rhel$($SelectedMajor)_64Guest" }

Write-Host "Vytvarim VM: $VMNameInput (GuestID: $GuestID)..." -ForegroundColor Yellow

$NewVM = New-VM -Name $VMNameInput `
       -MemoryMB 2048 `
       -NumCpu 2 `
       -DiskGB 25 `
       -Datastore $DatastoreName `
       -GuestId $GuestID

# Pripojeni ISO do virtualni mechaniky
$IsoPathForEsxi = "[$DatastoreName] $DatastoreIsoFolder/$IsoFileName"
New-CDDrive -VM $NewVM -IsoPath $IsoPathForEsxi -StartConnected $true | Out-Null

# Start VM
Start-VM -VM $NewVM
Write-Host "`nHotovo! Server bezi a bootuje instalator." -ForegroundColor Green