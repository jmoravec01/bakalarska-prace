<#
.SYNOPSIS
   Automatizovana instalace Rocky Linux VM na VMware ESXi.
   Pripraveno pro spousteni z Master Menu.
#>

# =============================================================================
# SKRIPT: Install-Rocky.ps1
# POPIS:  Skript pro automatizovane nasazeni virtualniho serveru (VM).
#         Vyuziva konfiguracni soubor 'config.json' z predchoziho kroku.
#         Resi stazeni ISO, upload na server, vytvoreni VM a nastaveni bootu.
# AUTOR:  Jakub Moravec
# DATUM:  2025
# =============================================================================

# -----------------------------------------------------------------------------
# 1. INITIALIZACE A FUNKCE
# -----------------------------------------------------------------------------
function global:prompt { "PS " + (Split-Path -Leaf (Get-Location)) + "> " }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop" # Pri chybe okamzite zastavit

Clear-Host
Write-Host "--- INSTALACE ROCKY LINUX (DEPLOYMENT) ---" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 2. NACTENI KONFIGURACE (JSON)
# -----------------------------------------------------------------------------
# Hledame konfiguracni soubor relativne ke skriptu.
$ConfigFile = Join-Path $PSScriptRoot "config\config.json"

# Fallback: Pokud neexistuje slozka 'config', zkusime 'confif' (preklepova pojistka)
if (-not (Test-Path $ConfigFile)) {
    $ConfigFileAlt = Join-Path $PSScriptRoot "confif\config.json"
    if (Test-Path $ConfigFileAlt) { $ConfigFile = $ConfigFileAlt }
}

if (Test-Path $ConfigFile) {
    try {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        Write-Host " [INIT] Konfigurace nactena (Server: $($Config.EsxiServer))." -ForegroundColor Gray
    }
    catch { Write-Host " [CHYBA] Config soubor je poskozeny." -ForegroundColor Red; exit }
}
else {
    Write-Host " [CHYBA] Nenalezen config.json!" -ForegroundColor Red
    Write-Host "         Hledal jsem zde: $ConfigFile" -ForegroundColor Gray
    Write-Host "         Nejprve spustte setup.ps1." -ForegroundColor Yellow
    exit
}

# -----------------------------------------------------------------------------
# 3. PRIPOJENI K ESXi SERVERU
# -----------------------------------------------------------------------------
# Pokud uz jsme pripojeni (napr. z Master Menu), nezdrzujeme se.
if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
    Write-Host " [OK] Pripojeno k: $($global:DefaultVIServer.Name)" -ForegroundColor Green
}
else {
    Write-Host " [INFO] Navazuji spojeni s '$($Config.EsxiServer)'..." -ForegroundColor Yellow
    
    # Smycka pro opakovane pokusy o prihlaseni
    while ($true) {
        try {
            Connect-VIServer -Server $Config.EsxiServer -ErrorAction Stop | Out-Null
            Write-Host " [OK] Uspesne pripojeno." -ForegroundColor Green
            break 
        }
        catch {
            Write-Host " [CHYBA] Pripojeni selhalo!" -ForegroundColor Red
            Write-Host " Duvod: $_" -ForegroundColor Gray
            
            Write-Host "`nZadali jste spravne heslo? Bezi VPN?" -ForegroundColor Yellow
            $Retry = Read-Host "Zkusit znovu? [A]no / [N]e (Enter = Ano)"
            if ($Retry.ToUpper() -eq "N") { exit }
            Write-Host "Opakuji pokus..." -ForegroundColor Cyan
        }
    }
}

# -----------------------------------------------------------------------------
# 4. DETEKCE VERZI ROCKY LINUX
# -----------------------------------------------------------------------------
Write-Host "`nZjistuji aktualni verze z repozitare..." -ForegroundColor Gray

# Funkce pro parsovani HTML z mirroru a nalezeni nejnovejsi verze
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

# -----------------------------------------------------------------------------
# 5. INTERAKTIVNI VYBER VERZE A EDICE
# -----------------------------------------------------------------------------
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

Write-Host "`nVyberte edici (ISO):"
Write-Host " [M] Minimal (Doporuceno pro servery)" -ForegroundColor Cyan
Write-Host " [B] Boot    (Pouze pro sitovou instalaci)" -ForegroundColor Yellow
Write-Host " [D] DVD     (Plna verze se vsemi balicky)" -ForegroundColor Gray

$TypeInput = Read-Host "Vase volba [Enter = M]"
if ([string]::IsNullOrWhiteSpace($TypeInput)) { $TypeInput = "M" }

switch ($TypeInput.ToUpper()) {
    "B" { $IsoSuffix = "boot"; $IsoType = "Boot/NetInstall" }
    "D" { $IsoSuffix = "dvd";  $IsoType = "DVD/Full" }
    Default { $IsoSuffix = "minimal"; $IsoType = "Minimal" }
}

Write-Host "`n--------------------------------------------------" -ForegroundColor Cyan
Write-Host " [INFO] Vybrano: Rocky Linux $SelectedFullVer ($IsoType)" -ForegroundColor Green
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 6. SPRAVA ISO SOUBORU (DOWNLOAD & UPLOAD)
# -----------------------------------------------------------------------------
$IsoFileName = "Rocky-$SelectedMajor-latest-x86_64-$IsoSuffix.iso"
$DownloadUrl = "http://ftp.sh.cvut.cz/rocky/$SelectedMajor/isos/x86_64/$IsoFileName"
$LocalPath   = Join-Path $PSScriptRoot $IsoFileName

# Priprava PSDrive pro pristup k Datastore jako k disku
$DatastoreObj = Get-Datastore -Name $Config.Datastore
if (Get-PSDrive -Name "ds" -ErrorAction SilentlyContinue) { Remove-PSDrive -Name "ds" }
New-PSDrive -Name "ds" -PSProvider VimDatastore -Root "\" -Location $DatastoreObj -ErrorAction SilentlyContinue | Out-Null
$RemoteFolder = "ds:\$($Config.IsoFolder)"
$RemoteIsoPath = "$RemoteFolder\$IsoFileName"

Write-Host "`n--- Sprava ISO souboru ---" -ForegroundColor Cyan

# KROK A: Kontrola existence vzdalene slozky
if (!(Test-Path $RemoteFolder)) { 
    try {
        New-Item -ItemType Directory -Path $RemoteFolder -ErrorAction Stop | Out-Null 
    }
    catch {
        Write-Host " [POZOR] Nelze automaticky vytvorit slozku (Free Licence?)." -ForegroundColor Yellow
        Write-Host "         Vytvorte slozku '$($Config.IsoFolder)' manualne pres web." -ForegroundColor Gray
        Read-Host "         [Jakmile slozku vytvorite, stisknete ENTER]"
    }
}

# KROK B: Logika stahovani a nahravani
if (Test-Path $RemoteIsoPath) {
    Write-Host " [OK] ISO soubor jiz existuje na ESXi. Preskakuji stahovani." -ForegroundColor Green
}
else {
    # 1. Stazeni do lokalni mezipameti (Cache)
    if (-not (Test-Path $LocalPath)) {
        Write-Host " [INFO] Stahuji ISO do PC (Cache)..." -ForegroundColor Yellow
        try {
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $LocalPath
            Write-Host " [OK] Stazeno uspesne." -ForegroundColor Green
        }
        catch {
            Write-Host " [CHYBA] Mirror nedostupny. Prepinam na zalozni..." -ForegroundColor Red
            $BackupUrl = "https://download.rockylinux.org/pub/rocky/$SelectedMajor/isos/x86_64/$IsoFileName"
            try {
                Invoke-WebRequest -Uri $BackupUrl -OutFile $LocalPath
                Write-Host " [OK] Stazeno (Backup)." -ForegroundColor Green
            } catch { Write-Host " [FATAL] Stahovani selhalo." -ForegroundColor Red; exit }
        }
    } else { Write-Host " [INFO] ISO nalezeno v cache." -ForegroundColor Gray }

    # 2. Upload na ESXi (S animaci)
    Write-Host " [INFO] Nahravam ISO na server..." -ForegroundColor Yellow
    Write-Host "         (Sledujte zahlavi okna)" -ForegroundColor Gray
    
    try {
        $StopWatch = New-Object System.Diagnostics.Stopwatch; $StopWatch.Start()
        # Spustime upload na pozadi (ThreadJob), abychom mohli animovat
        $Job = Start-ThreadJob -ScriptBlock { param($S,$D) Copy-DatastoreItem -Item $S -Destination $D -Force -ErrorAction Stop } -ArgumentList $LocalPath, $RemoteIsoPath
        
        $Anim = "|", "/", "-", "\"; $i = 0
        while ($Job.State -eq 'Running') {
            $Time = $StopWatch.Elapsed.ToString("mm\:ss")
            Write-Host -NoNewline "`r [UPLOAD] $($Anim[$i++ % 4]) Cas: $Time "
            Start-Sleep -Milliseconds 200
        }
        Receive-Job -Job $Job -Wait -ErrorAction SilentlyContinue | Out-Null
        if ($Job.JobStateInfo.State -eq 'Failed') { throw $Job.JobStateInfo.Reason }
        
        $StopWatch.Stop()
        Write-Host -NoNewline "`r [OK] Uspesne nahrano. Cas: $($StopWatch.Elapsed.ToString("mm\:ss"))      `n" -ForegroundColor Green
        
        # Uklid
        Remove-Item -Path $LocalPath -Force
        Write-Host " [CLEANUP] Cache vycistena." -ForegroundColor Green
    }
    catch {
        Write-Host "`n [CHYBA] Upload selhal." -ForegroundColor Red
        Write-Host "         Manualne nahrajte '$IsoFileName' do '$($Config.IsoFolder)'." -ForegroundColor Yellow
        # Otevreme slozku s ISO
        Invoke-Item (Split-Path $LocalPath)
        Read-Host "         [Jakmile ISO nahrajete, stisknete ENTER]"
        if ((Read-Host "Smazat ISO z PC? [A]no/[N]e").ToUpper() -eq "A") { Remove-Item -Path $LocalPath -Force }
    }
}
# Odpojime PSDrive
Remove-PSDrive -Name "ds" -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# 7. VYBER PROFILU
# -----------------------------------------------------------------------------
function Show-ProfileTable {
    param($Conf)
    $TableData = @()
    foreach ($key in "Low", "Mid", "High") {
        $p = $Conf.Profiles.$key
        $TableData += [PSCustomObject]@{ Profil=$key; RAM_MB=$p.RamMB; CPU_Jadra=$p.CpuCount; Disk_GB=$p.DiskGB }
    }
    $TableData | Format-Table -AutoSize
}

Write-Host "`n--- Konfigurace Virtualniho Stroje ---" -ForegroundColor Cyan
Show-ProfileTable -Conf $Config
$ProfileChoice = Read-Host "Profil [Enter = Mid]"
if ([string]::IsNullOrWhiteSpace($ProfileChoice)) { $ProfileChoice = "M" }

switch ($ProfileChoice.ToUpper()) {
    "L" { $Hw = $Config.Profiles.Low;  $Suffix="low" }
    "H" { $Hw = $Config.Profiles.High; $Suffix="high" }
    Default { $Hw = $Config.Profiles.Mid; $Suffix="mid" }
}

# -----------------------------------------------------------------------------
# 8. VYTVORENI VM A KONFIGURACE BOOTU
# -----------------------------------------------------------------------------
$DefaultName = "Rocky-$SelectedMajor-$Suffix"

# Kontrola unikatnosti nazvu
while ($true) {
    $VMNameInput = Read-Host "`nZadejte nazev serveru (Enter = $DefaultName)"
    if ([string]::IsNullOrWhiteSpace($VMNameInput)) { $VMNameInput = $DefaultName }
    if (Get-VM -Name $VMNameInput -ErrorAction SilentlyContinue) {
        Write-Host " [!] Server '$VMNameInput' jiz existuje!" -ForegroundColor Red
    } else { break }
}

# Nastaveni ID hosta pro VMware
if ($SelectedMajor -eq "10") { $GuestID = "rhel9_64Guest" } else { $GuestID = "rhel$($SelectedMajor)_64Guest" }

Write-Host "Vytvarim VM: $VMNameInput..." -ForegroundColor Yellow
Write-Host " - Sit: $($Config.Network) | Datastore: $($Config.Datastore)" -ForegroundColor Gray

try {
    # 1. Vytvoreni samotneho VM
    $NewVM = New-VM -Name $VMNameInput -MemoryMB $Hw.RamMB -NumCpu $Hw.CpuCount -DiskGB $Hw.DiskGB `
             -Datastore $Config.Datastore -NetworkName $Config.Network -GuestId $GuestID -ErrorAction Stop

    # 2. Pripojeni ISO do CD-ROM mechaniky
    $IsoPathForEsxi = "[$($Config.Datastore)] $($Config.IsoFolder)/$IsoFileName"
    $ExistingCd = Get-CDDrive -VM $NewVM -ErrorAction SilentlyContinue
    if ($ExistingCd) {
        Set-CDDrive -CD $ExistingCd -IsoPath $IsoPathForEsxi -StartConnected:$true -Confirm:$false -ErrorAction Stop | Out-Null
    } else {
        New-CDDrive -VM $NewVM -IsoPath $IsoPathForEsxi -StartConnected:$true -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Write-Host " [HOTOVO] VM vytvorena." -ForegroundColor Green

    # 3. Volba spusteni (vse pripraveno)
    $StartChoice = Read-Host "`nSpustit server nyni? [A]no / [N]e (Enter = Ano)"

    # --- SILENT BOOT FIX (Disk -> CD-ROM) ---
    # Nastavujeme Boot Order tak, aby Disk mel prednost pred CD-ROM.
    # Vysvetleni: Protoze je disk novy a prazdny, BIOS ho pri prvnim startu preskoci
    # a nabootuje z CD (instalator).
    # Jakmile se nainstaluje system na disk, pri pristim startu uz BIOS najde 
    # bootloader na disku a spusti ho (uz neinstaluje z ISO).
    
    $Spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $Spec.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
    $BootDisk = New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice
    $BootCd   = New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice
    $Spec.BootOptions.BootOrder = @($BootDisk, $BootCd)
    $NewVM.ExtensionData.ReconfigVM($Spec)
    # ----------------------------------------
    
    if ([string]::IsNullOrWhiteSpace($StartChoice) -or $StartChoice.ToUpper() -eq "A") {
        Write-Host "Startuji $VMNameInput..." -ForegroundColor Yellow
        Start-VM -VM $NewVM -ErrorAction Stop | Out-Null
        Write-Host " [OK] Server bezi. Otevrete konzoli pro instalaci." -ForegroundColor Green
    } else {
        Write-Host " [OK] Server ponechan ve vypnutem stavu." -ForegroundColor Gray
    }
}
catch { 
    Write-Host "`n[CHYBA] $_" -ForegroundColor Red
    if ($NewVM) { Write-Host " [INFO] VM byla vytvorena s chybou." -ForegroundColor Gray }
}