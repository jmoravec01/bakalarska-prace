<#
.SYNOPSIS
   INSTALACE WORDPRESSU (Chunked Transfer + CRLF FIX)
#>

# 1. NASTAVENI
$ScriptFile = Join-Path $PSScriptRoot "setup-wordpress.sh"
# Zkontrolujte, jestli mate slozku 'config' nebo 'confif'
$ConfigFile = Join-Path $PSScriptRoot "config\config.json"
$ErrorActionPreference = "Stop"

# 2. KONTROLY
if (-not (Test-Path $ScriptFile)) { Write-Host " [CHYBA] Nenalezen setup-wordpress.sh" -ForegroundColor Red; exit }
if (-not (Test-Path $ConfigFile)) { Write-Host " [CHYBA] Nenalezen config.json" -ForegroundColor Red; exit }

# 3. PRIPOJENI
try { $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch { exit }
if (-not ($global:DefaultVIServer.IsConnected)) {
    Connect-VIServer -Server $Config.EsxiServer -ErrorAction Stop | Out-Null
}

# 4. VYBER VM
Clear-Host
Write-Host "--- INSTALACE WORDPRESS (FIXED LINE ENDINGS) ---" -ForegroundColor Cyan
$AllVMs = Get-VM | Where-Object { $_.PowerState -eq "PoweredOn" } | Sort-Object Name

if ($AllVMs.Count -eq 0) { Write-Host " [INFO] Zadne bezici VM." -ForegroundColor Yellow; exit }

$i = 1
foreach ($vm in $AllVMs) {
    Write-Host " [$i] $($vm.Name) (IP: $($vm.Guest.IPAddress[0]))" -ForegroundColor Green
    $i++
}

while ($true) {
    $Selection = Read-Host " Vyberte VM"
    if ($Selection -match "^\d+$" -and [int]$Selection -ge 1 -and [int]$Selection -le $AllVMs.Count) {
        $VM = $AllVMs[[int]$Selection - 1]
        break
    }
}

# 5. PRIPRAVA DAT (TADY BYL PROBLEM)
$GuestCreds = Get-Credential -UserName "root" -Message "Heslo root"

Write-Host "`n [1/3] Normalizace skriptu (Windows -> Linux)..." -ForegroundColor Cyan

# A) Nacteme text jako String
$RawText = Get-Content $ScriptFile -Raw

# B) Nahradime Windows konce radku (CRLF) za Linuxove (LF)
#    Toto je ten klicovy krok, ktery opravi "bad interpreter"
$UnixText = $RawText -replace "`r`n", "`n"

# C) Prevedeme na Base64
$Bytes = [System.Text.Encoding]::UTF8.GetBytes($UnixText)
$Base64Full = [Convert]::ToBase64String($Bytes)

# Rozsekame na chunky po 2000 znacich
$Chunks = $Base64Full -split '(.{1,2000})' -ne ''

Write-Host " [2/3] Nahravam skript do VM ($($Chunks.Count) casti)..." -ForegroundColor Cyan

# Vymazeme stary temp soubor ve VM
Invoke-VMScript -VM $VM -ScriptText "rm -f /tmp/install.b64" -GuestCredential $GuestCreds -ScriptType Bash | Out-Null

# Posilame kousky
foreach ($Chunk in $Chunks) {
    Write-Host -NoNewline "."
    $Cmd = "echo -n '$Chunk' >> /tmp/install.b64"
    Invoke-VMScript -VM $VM -ScriptText $Cmd -GuestCredential $GuestCreds -ScriptType Bash | Out-Null
}

Write-Host "`n [OK] Nahrano." -ForegroundColor Green

# 6. SPUSTENI
Write-Host " [3/3] Spoustim instalaci..." -ForegroundColor Cyan

# Dekodujeme -> Udelame spustitelny -> Spustime
# Pridali jsme 'bash' pred spusteni pro jistotu
$FinalCmd = "base64 -d /tmp/install.b64 > /tmp/install.sh && chmod +x /tmp/install.sh && bash /tmp/install.sh"

try {
    $Result = Invoke-VMScript -VM $VM `
                              -ScriptText $FinalCmd `
                              -GuestCredential $GuestCreds `
                              -ScriptType Bash `
                              -ErrorAction Stop

    Clear-Host
    Write-Host "--- VYSLEDEK ---" -ForegroundColor Cyan
    Write-Host $Result.ScriptOutput -ForegroundColor Gray
    Write-Host "`n [HOTOVO] Zkuste web: http://$($VM.Guest.IPAddress[0])" -ForegroundColor Green
}
catch {
    Write-Host " [CHYBA] Instalační skript selhal." -ForegroundColor Red
    Write-Host " $_" -ForegroundColor Yellow
}