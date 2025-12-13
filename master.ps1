<#
.SYNOPSIS
   MASTER LAUNCHER (Orchestrator)
   Rozcestnik pro spousteni vsech podrizernych skriptu v projektu.
#>

# =============================================================================
# 1. NASTAVENI A KONFIGURACE
# =============================================================================
$ScriptRoot = $PSScriptRoot
$ScriptsDir = Join-Path $ScriptRoot "scripts"

# VLASTNI PORADI SKRIPTU (LOGICKY TOK)
# Zde definujeme, v jakem poradi se maji skripty zobrazit v menu.
# Vsechny ostatni nenalezeny v tomto seznamu se zaradi nakonec abecedne.
$CustomOrder = @(
    "setup.ps1",
    "check-esxi.ps1",
    "install-rocky.ps1",
    "install-wordpress.ps1"
)

# =============================================================================
# 2. DEFINICE FUNKCI
# =============================================================================

# Funkce pro efekt psaciho stroje (Animace)
function Write-Typewriter {
    param(
        [string]$Text,
        [string]$Color = "Cyan",
        [int]$Speed = 30
    )
    # Skryjeme kurzor pro cistsi efekt
    try { [Console]::CursorVisible = $false } catch {}

    $CharArray = $Text.ToCharArray()
    foreach ($Char in $CharArray) {
        Write-Host $Char -NoNewline -ForegroundColor $Color
        Start-Sleep -Milliseconds $Speed
    }
    Write-Host "" # Odradkovani
    
    # Vratime kurzor
    try { [Console]::CursorVisible = $true } catch {}
}

# Funkce pro cekani na klavesu
function Wait-UserAction {
    Write-Host ""
    Write-Host "---------------------------------------------------------------" -ForegroundColor Gray
    Write-Host " Stisknete libovolnou klavesu pro navrat do menu..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# =============================================================================
# 3. SPUSTENI INTRA (Run Once)
# =============================================================================

Clear-Host
Write-Host "`n"

# -- ANIMACE START --
Write-Typewriter "BAKALARSKA PRACE: AUTOMATIZACE NASAZENI SERVERU" -Color Cyan -Speed 25
Write-Typewriter "AUTOR: JAKUB MORAVEC" -Color White -Speed 25
Write-Typewriter "NACITANI MODULU..." -Color DarkGray -Speed 10
Start-Sleep -Milliseconds 400
Write-Typewriter "HOTOVO." -Color Green -Speed 10
Start-Sleep -Seconds 1
# -- ANIMACE END --

# =============================================================================
# 4. HLAVNI SMYCKA (MENU)
# =============================================================================
while ($true) {
    Clear-Host
    Write-Host "===============================================================" -ForegroundColor Cyan
    Write-Host "   MASTER LAUNCHER - RIDICI PULT" -ForegroundColor Cyan
    Write-Host "===============================================================" -ForegroundColor Gray
    
    # Kontrola existence slozky se skripty
    if (-not (Test-Path $ScriptsDir)) {
        Write-Host " [CHYBA] Slozka '$ScriptsDir' neexistuje!" -ForegroundColor Red
        Write-Host " Ujistete se, ze struktura slozek je spravna."
        exit
    }

    # Nacteni vsech .ps1 souboru
    $AllFiles = Get-ChildItem -Path $ScriptsDir -Filter "*.ps1"
    
    if ($AllFiles.Count -eq 0) {
        Write-Host " [INFO] Ve slozce 'scripts' nebyly nalezeny zadne soubory." -ForegroundColor Yellow
        exit
    }

    # --- LOGIKA RAZENI (Prioritni + Zbytek) ---
    $OrderedList = [System.Collections.ArrayList]::new()

    # A) Pridame prioritni skripty (pokud existuji)
    foreach ($Name in $CustomOrder) {
        $Found = $AllFiles | Where-Object { $_.Name -eq $Name }
        if ($Found) { [void]$OrderedList.Add($Found) }
    }
    # B) Pridame zbytek abecedne
    $Remaining = $AllFiles | Where-Object { $CustomOrder -notcontains $_.Name } | Sort-Object Name
    foreach ($File in $Remaining) { [void]$OrderedList.Add($File) }

    # --- VYPIS POLOZEK ---
    $Index = 1
    foreach ($File in $OrderedList) {
        # Zkusime precist prvni radek skriptu jako popis (pokud zacina #)
        $Desc = ""
        $Header = Get-Content $File.FullName -TotalCount 1
        if ($Header -match "^#") { 
            # Odstranime mrizku a mezery
            $RawDesc = $Header -replace "^#\s*", ""
            # Zkratime popis, pokud je moc dlouhy
            if ($RawDesc.Length -gt 50) { $RawDesc = $RawDesc.Substring(0, 47) + "..." }
            $Desc = "- $RawDesc"
        }

        # Barva: Zluta pro hlavni skripty, Bila pro ostatni
        $Color = if ($CustomOrder -contains $File.Name) { "Yellow" } else { "White" }

        Write-Host " $Index. " -NoNewline -ForegroundColor Green
        Write-Host "$($File.Name) " -NoNewline -ForegroundColor $Color
        Write-Host "$Desc" -ForegroundColor DarkGray
        $Index++
    }

    Write-Host ""
    Write-Host " Q. Ukoncit (Quit)" -ForegroundColor Gray
    Write-Host "===============================================================" -ForegroundColor Gray

    # --- INTERAKCE S UZIVATELEM ---
    $Selection = Read-Host " Vyberte akci"

    if ($Selection -in 'q', 'Q') { 
        Write-Host " Ukoncuji..."
        break 
    }

    # Overeni vstupu (je to cislo a je v rozsahu?)
    if ($Selection -match "^\d+$" -and [int]$Selection -ge 1 -and [int]$Selection -le $OrderedList.Count) {
        $TargetScript = $OrderedList[[int]$Selection - 1]
        
        Write-Host "`n >>> Spoustim: $($TargetScript.Name)..." -ForegroundColor Cyan
        try {
            # Operator '&' spusti skript v aktualnim okne (zachova promenne)
            & $TargetScript.FullName
        } 
        catch {
            Write-Host " [CHYBA] Nastala chyba pri spousteni skriptu:" -ForegroundColor Red
            Write-Host " $_" -ForegroundColor Red
        }
        
        # Pockame, aby si uzivatel mohl precist vysledek
        Wait-UserAction
    } 
    else {
        Write-Host " Neplatna volba." -ForegroundColor Red
        Start-Sleep -Milliseconds 800
    }
}