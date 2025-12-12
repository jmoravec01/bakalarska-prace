# =============================================================================
# SKRIPT: Install-Rocky.ps1
# POPIS: Automatizovane nasazeni VM (s vyuzitim config.json)
# =============================================================================

$MinVersion = [Version]"7.0"
if ($PSVersionTable.PSVersion -lt $MinVersion) {
    Clear-Host
    Write-Host "--- CHYBA PROSTREDI ---" -ForegroundColor Red
    Write-Host " [!] Tento skript vyzaduje PowerShell $MinVersion a novejsi." -ForegroundColor Yellow
    Write-Host "     Vase verze: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host "     Prosim prepnete terminal pomoci 'pwsh' nebo aktualizujte."
    exit
}

# 1. NASTAVENI PROSTREDI
function global:prompt { "PS " + (Split-Path -Leaf (Get-Location)) + "> " }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

Clear-Host
Write-Host "--- INSTALACE ROCKY LINUX (DEPLOYMENT) ---" -ForegroundColor Cyan

# 2. NACTENI KONFIGURACE
$ConfigFile = ".\config\config.json"

if (Test-Path $ConfigFile) {
    try {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        Write-Host " [INIT] Konfigurace nactena (Server: $($Config.EsxiServer))." -ForegroundColor Gray
    }
    catch { Write-Host " [CHYBA] Config poskozen." -ForegroundColor Red; exit }
}
else {
    Write-Host " [CHYBA] Nenalezen config.json! Spustte nejprve setup.ps1." -ForegroundColor Red; exit
}

# 3. PRIPOJENI K SERVERU
if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
    Write-Host " [OK] Pripojeno k: $($global:DefaultVIServer.Name)" -ForegroundColor Green
}
else {
    Write-Host " [INFO] Navazuji spojeni s '$($Config.EsxiServer)'..." -ForegroundColor Yellow
    try {
        Connect-VIServer -Server $Config.EsxiServer | Out-Null
        Write-Host " [OK] Uspesne pripojeno." -ForegroundColor Green
    }
    catch { Write-Host " [CHYBA] Server nedostupny." -ForegroundColor Red; exit }
}

# 4. ZJISTENI DOSTUPNYCH VERZI
Write-Host "`nZjistuji aktualni verze z repozitare..." -ForegroundColor Gray

function Get-RockyVersion {
    param ($MajorVer)
    $Url = "https://download.rockylinux.org/pub/rocky/$MajorVer/isos/x86_64/"
    try {
        $Content = Invoke-WebRequest -Uri $Url -UseBasicParsing
        if ($Content.Content -match "Rocky-$MajorVer\.(\d+)-") { return "$MajorVer.$($Matches[1])" }
        return "$MajorVer.x"
    }
    catch { return "$MajorVer.x (Nedostupna)" }
}

$Ver10 = Get-RockyVersion -MajorVer "10"
$Ver9  = Get-RockyVersion -MajorVer "9"
$Ver8  = Get-RockyVersion -MajorVer "8"

# 5. VYBER VERZE A EDICE
Write-Host "`nDostupne verze (Enterprise LTS):"
Write-Host " [1] Rocky Linux $Ver10 (Experimental)" -ForegroundColor Magenta
Write-Host " [2] Rocky Linux $Ver9  (Doporuceno)" -ForegroundColor Green
Write-Host " [3] Rocky Linux $Ver8  (Legacy)" -ForegroundColor Gray

$VerChoice = Read-Host "`nVyberte verzi (1-3) [Enter = 2]"
if ([string]::IsNullOrWhiteSpace($VerChoice)) { $VerChoice = "2" }

switch ($VerChoice) {
    "1" { $SelectedMajor = "10"; $SelectedFullVer = $Ver10 }
    "2" { $SelectedMajor = "9";  $SelectedFullVer = $Ver9 }
    "3" { $SelectedMajor = "8";  $SelectedFullVer = $Ver8 }
    Default { Write-Host "Neplatna volba."; exit }
}

Write-Host "`nVyberte edici:"
Write-Host " [M] Minimal (Doporuceno)" -ForegroundColor Cyan
Write-Host " [D] DVD / GUI" -ForegroundColor Gray

$TypeInput = Read-Host "Vase volba [Enter = M]"
if ([string]::IsNullOrWhiteSpace($TypeInput)) { $TypeInput = "M" }

if ($TypeInput.ToUpper() -eq "D") { 
    $IsoSuffix = "dvd"; $IsoType = "DVD" 
} else { 
    $IsoSuffix = "minimal"; $IsoType = "Minimal" 
}

# Info o vyberu
Write-Host "`n--------------------------------------------------" -ForegroundColor Cyan
Write-Host " [INFO] Vybrano: Rocky Linux $SelectedFullVer ($IsoType)" -ForegroundColor Green
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

# 6. LOGIKA ISO
$IsoFileName = "Rocky-$SelectedMajor-latest-x86_64-$IsoSuffix.iso"
$DownloadUrl = "https://download.rockylinux.org/pub/rocky/$SelectedMajor/isos/x86_64/$IsoFileName"
$LocalPath   = Join-Path $Config.LocalIsoDir $IsoFileName

$DatastoreObj = Get-Datastore -Name $Config.Datastore
New-PSDrive -Name "ds" -PSProvider VimDatastore -Root "\" -Location $DatastoreObj -ErrorAction SilentlyContinue | Out-Null
$RemoteFolder = "ds:\$($Config.IsoFolder)"
$RemoteIsoPath = "$RemoteFolder\$IsoFileName"

if (!(Test-Path $RemoteFolder)) { New-Item -ItemType Directory -Path $RemoteFolder | Out-Null }

Write-Host "`n--- Sprava ISO souboru ---" -ForegroundColor Cyan

# KROK A: Kontrola na serveru
if (Test-Path $RemoteIsoPath) {
    Write-Host " [OK] ISO soubor jiz existuje na ESXi. Preskakuji stahovani." -ForegroundColor Green
}
else {
    # KROK B: Neni na serveru -> Resime PC
    if (-not (Test-Path $LocalPath)) {
        Write-Host " [INFO] Stahuji ISO do PC ($DownloadUrl)..." -ForegroundColor Yellow
        $LDir = [System.IO.Path]::GetDirectoryName($LocalPath)
        if (!(Test-Path $LDir)) { New-Item -ItemType Directory -Path $LDir | Out-Null }
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $LocalPath
        Write-Host " [OK] Stazeno." -ForegroundColor Green
    } else {
        Write-Host " [INFO] ISO nalezeno v cache PC." -ForegroundColor Gray
    }

    # Upload
    Write-Host " [INFO] Nahravam ISO na server..." -ForegroundColor Yellow
    Copy-DatastoreItem -Item $LocalPath -Destination $RemoteIsoPath -Force
    Write-Host " [OK] Nahrano." -ForegroundColor Green

    # Smazani z PC
    Write-Host " [CLEANUP] Mazu lokalni ISO z PC..." -ForegroundColor Magenta
    Remove-Item -Path $LocalPath -Force
    Write-Host " [OK] Smazano." -ForegroundColor Green
}

Remove-PSDrive -Name "ds" -ErrorAction SilentlyContinue

# 7. VYBER HARDWAROVEHO PROFILU (S TABULKOU)

# --- DEFINICE FUNKCE PRO TABULKU ---
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
# -----------------------------------

Write-Host "`n--- Konfigurace Virtualniho Stroje ---" -ForegroundColor Cyan
Write-Host "Dostupne profily (dle setup.ps1):" -ForegroundColor Gray

# Zobrazeni tabulky pomoci funkce
Show-ProfileTable -Conf $Config

Write-Host "Moznosti: [L]ow, [M]id, [H]igh" -ForegroundColor Yellow
$ProfileChoice = Read-Host "Vase volba [Enter = M]"
if ([string]::IsNullOrWhiteSpace($ProfileChoice)) { $ProfileChoice = "M" }

switch ($ProfileChoice.ToUpper()) {
    "L" { $Hw = $Config.Profiles.Low;  $Suffix="low" }
    "H" { $Hw = $Config.Profiles.High; $Suffix="high" }
    Default { $Hw = $Config.Profiles.Mid; $Suffix="mid" }
}

# 8. VYTVORENI VM
$DefaultName = "Rocky-$SelectedMajor-$Suffix"
$VMNameInput = Read-Host "`nZadejte nazev serveru (Enter = $DefaultName)"
if ([string]::IsNullOrWhiteSpace($VMNameInput)) { $VMNameInput = $DefaultName }

if ($SelectedMajor -eq "10") { $GuestID = "rhel9_64Guest" } else { $GuestID = "rhel$($SelectedMajor)_64Guest" }

Write-Host "Vytvarim VM: $VMNameInput..." -ForegroundColor Yellow
Write-Host " - Sit: $($Config.Network) | Datastore: $($Config.Datastore)" -ForegroundColor Gray

try {
    $NewVM = New-VM -Name $VMNameInput `
           -MemoryMB $Hw.RamMB `
           -NumCpu $Hw.CpuCount `
           -DiskGB $Hw.DiskGB `
           -Datastore $Config.Datastore `
           -NetworkName $Config.Network `
           -GuestId $GuestID

    $IsoPathForEsxi = "[$($Config.Datastore)] $($Config.IsoFolder)/$IsoFileName"
    New-CDDrive -VM $NewVM -IsoPath $IsoPathForEsxi -StartConnected $true | Out-Null

    Start-VM -VM $NewVM | Out-Null
    Write-Host "`n[HOTOVO] Server $VMNameInput bezi!" -ForegroundColor Green
}
catch { Write-Host "`n[CHYBA] $_" -ForegroundColor Red }