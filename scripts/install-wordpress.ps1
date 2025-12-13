<#
.SYNOPSIS
   INSTALACE WORDPRESSU (Robustni verze)
   1. Opravuje Windows radkovani (CRLF -> LF).
   2. Posila skript po castech (Chunked Transfer).
   3. Kontroluje dostupnost VM a VMware Tools.
#>

# =============================================================================
# 1. NASTAVENI CEST
# =============================================================================
# Cesta k Bash skriptu (ten musi byt ve stejne slozce)
$ScriptFile = Join-Path $PSScriptRoot "setup-wordpress.sh"

# Cesta ke konfiguraci (vygenerovano setupem)
$ConfigFile = Join-Path $PSScriptRoot "config\config.json"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# --- KONTROLA EXISTENCE SOUBORU ---
if (-not (Test-Path $ScriptFile)) {
    Write-Host " [CHYBA] Nenalezen soubor 'setup-wordpress.sh'!" -ForegroundColor Red
    Write-Host "         Ujistete se, ze je ve slozce: $PSScriptRoot" -ForegroundColor Gray
    exit
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host " [CHYBA] Nenalezen 'config.json'!" -ForegroundColor Red
    Write-Host "         Nejprve spustte 'setup.ps1'." -ForegroundColor Yellow
    exit
}

# =============================================================================
# 2. PRIPOJENI K ESXi
# =============================================================================
try {
    $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} catch {
    Write-Host " [CHYBA] Soubor config.json je poskozeny." -ForegroundColor Red
    exit
}

if (-not ($global:DefaultVIServer.IsConnected)) {
    Write-Host " Pripojuji k ESXi serveru ($($Config.EsxiServer))..." -ForegroundColor Gray
    try {
        Connect-VIServer -Server $Config.EsxiServer -ErrorAction Stop | Out-Null
        Write-Host " [OK] Pripojeno." -ForegroundColor Green
    } catch {
        Write-Host " [CHYBA] Nepodarilo se pripojit k serveru ESXi." -ForegroundColor Red
        exit
    }
}

# =============================================================================
# 3. VYBER VIRTUALNIHO STROJE
# =============================================================================
Clear-Host
Write-Host "--- INSTALACE WORDPRESS (REMOTE EXECUTION) ---" -ForegroundColor Cyan

# Nacteme jen zapnute VM, protoze na vypnute nelze instalovat
try {
    $AllVMs = Get-VM | Where-Object { $_.PowerState -eq "PoweredOn" } | Sort-Object Name
} catch { Write-Host " [CHYBA] Nelze nacist seznam VM." -ForegroundColor Red; exit }

if ($AllVMs.Count -eq 0) {
    Write-Host " [INFO] Zadné běžící VM nebyly nalezeny." -ForegroundColor Yellow
    Write-Host "        Zapnete VM a zkuste to znovu." -ForegroundColor Gray
    exit
}

Write-Host "`n Vyberte cilovy server (VM musi beze):"
$i = 1
foreach ($vm in $AllVMs) {
    $IP = if ($vm.Guest.IPAddress) { $vm.Guest.IPAddress[0] } else { "---" }
    Write-Host " [$i] $($vm.Name) (IP: $IP)" -ForegroundColor Green
    $i++
}

while ($true) {
    $Selection = Read-Host "`n Cislo VM"
    if ($Selection -match "^\d+$" -and [int]$Selection -ge 1 -and [int]$Selection -le $AllVMs.Count) {
        $VM = $AllVMs[[int]$Selection - 1]
        break
    }
}

# =============================================================================
# 4. KONTROLA VMWARE TOOLS (DULEZITE!)
# =============================================================================
# Pokud Tools nebezi, Invoke-VMScript selže. Proto musíme pockat.
try { [Console]::CursorVisible = $false } catch {}

while ($true) {
    $MaxWait = 30
    $TimeLeft = $MaxWait
    $ToolsOK = $false

    # Smycka odpoctu
    while ($TimeLeft -gt 0) {
        $VM.ExtensionData.UpdateViewData("Guest.ToolsStatus")
        
        if ($VM.ExtensionData.Guest.ToolsStatus -eq "toolsOk") {
            $ToolsOK = $true
            break
        }

        Write-Host -NoNewline "`r [CEKANI] Cekam na VMware Tools... Zbyva: $TimeLeft s    " -ForegroundColor Yellow
        Start-Sleep 1
        $TimeLeft--
    }

    if ($ToolsOK) {
        break # Tools bezi, jdeme dal
    } else {
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host "`n"
        Write-Host "===============================================================" -ForegroundColor Red
        Write-Host " [CHYBA] VMware Tools nenabehly." -ForegroundColor Red
        Write-Host "===============================================================" -ForegroundColor Red
        Write-Host " Duvod: VM nema sit nebo nebezi sluzba vmtoolsd." -ForegroundColor Yellow
        Write-Host ""
        Write-Host " MANUALNI OPRAVA (neukoncujte tento skript):" -ForegroundColor Cyan
        Write-Host " 1. Otevrete konzoli VM ve VMware."
        Write-Host " 2. Prikazem 'nmtui' zapnete sit (Activate a connection)."
        Write-Host " 3. Spustte: dnf install -y open-vm-tools"
        Write-Host " 4. Spustte: systemctl start vmtoolsd"
        Write-Host "===============================================================" -ForegroundColor Red
        
        Write-Host " [?] Az opravu provedete, stisknete ENTER pro novy pokus." -ForegroundColor White
        $Choice = Read-Host "     (Nebo napiste 'Q' pro ukonceni skriptu)"
        
        if ($Choice -in 'Q', 'q') {
            Write-Host " Ukoncuji skript." -ForegroundColor Gray
            exit
        }
        
        Write-Host " Zkousim znovu..." -ForegroundColor Cyan
        try { [Console]::CursorVisible = $false } catch {}
    }
}

try { [Console]::CursorVisible = $true } catch {}
$IP = $VM.Guest.IPAddress[0]
Write-Host "`r [OK] Spojeni navazano. IP adresa VM: $IP           " -ForegroundColor Green

# =============================================================================
# 5. PRIPRAVA SKRIPTU A PRENOS (CHUNKED + CRLF FIX)
# =============================================================================
$GuestCreds = Get-Credential -UserName "root" -Message "Heslo pro ROOT uzivatele ve VM"

Write-Host "`n [1/3] Priprava souboru (Fix CRLF)..." -ForegroundColor Cyan

# 1. Nacteme obsah bash skriptu
$RawText = Get-Content $ScriptFile -Raw

# 2. Nahradime Windows konce radku (CRLF) za Linuxove (LF) - KRITICKE!
$UnixText = $RawText -replace "`r`n", "`n"

# 3. Prevedeme na Base64
$Bytes = [System.Text.Encoding]::UTF8.GetBytes($UnixText)
$Base64Full = [Convert]::ToBase64String($Bytes)

# 4. Rozsekame na kousky (Chunky) po 2000 znacich (limit VMware API)
$Chunks = $Base64Full -split '(.{1,2000})' -ne ''

Write-Host " [2/3] Nahravam skript do VM ($($Chunks.Count) casti)..." -ForegroundColor Cyan

# Smazani stareho souboru ve VM (cisty start)
Invoke-VMScript -VM $VM -ScriptText "rm -f /tmp/install.b64" -GuestCredential $GuestCreds -ScriptType Bash | Out-Null

# Posilani po kouskach
foreach ($Chunk in $Chunks) {
    Write-Host -NoNewline "."
    # Prikaz pripoji kus textu na konec souboru
    $Cmd = "echo -n '$Chunk' >> /tmp/install.b64"
    Invoke-VMScript -VM $VM -ScriptText $Cmd -GuestCredential $GuestCreds -ScriptType Bash | Out-Null
}
Write-Host " [OK]" -ForegroundColor Green

# =============================================================================
# 6. SPUSTENI INSTALACE
# =============================================================================
Write-Host " [3/3] Spoustim instalaci (to muze trvat 3-5 minut)..." -ForegroundColor Cyan

# Prikaz: Dekodovat -> Ulozit jako .sh -> Nastavit prava -> Spustit bashem
$FinalCmd = "base64 -d /tmp/install.b64 > /tmp/install.sh && chmod +x /tmp/install.sh && bash /tmp/install.sh"

try {
    $Result = Invoke-VMScript -VM $VM `
                              -ScriptText $FinalCmd `
                              -GuestCredential $GuestCreds `
                              -ScriptType Bash `
                              -ErrorAction Stop

    # Vypiseme vystup z Linuxu
    Clear-Host
    Write-Host "--- VYSLEDEK INSTALACE ---" -ForegroundColor Cyan
    Write-Host $Result.ScriptOutput -ForegroundColor Gray
    
    $FinalIP = $VM.Guest.IPAddress[0]
    Write-Host "`n===================================================" -ForegroundColor Green
    Write-Host " HOTOVO! Web by mel bezet na: http://$FinalIP" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green
}
catch {
    Write-Host "`n [CHYBA] Skript ve VM selhal nebo vyprsel casovy limit." -ForegroundColor Red
    Write-Host " Detail chyby: $_" -ForegroundColor Yellow
}