# Automatizace procesu nasazení a správy serverů pomocí PowerShellu v prostředí hypervizoru
Tento repozitář obsahuje veškerý kód a dokumentaci související s mou bakalářskou prací.

## O projektu
Cílem této práce je navrhnout a implementovat sadu skriptů pro **PowerShell v7.x** (s modulem **PowerCLI**), které automatizují deployment virtuálních serverů. 

**Hlavní přínosy řešení:**
* **Standardizace:** Sjednocení procesu od vytvoření po konfiguraci.
* **Efektivita:** Snížení chybovosti a zrychlení nasazení.
* **Bezpečnost:** Automatizovaná správa přístupových práv a autentizace.

📜 Bakalářská práce je dostupná na [Overleaf](https://overleaf.prf.ujep.cz/read/jrsqvjvpcnsy#87aa95).

## 🛠 Instalace PowerShell

Pro spuštění automatizačních skriptů je vyžadován **PowerShell 7.x**. Původní Windows PowerShell 5.1 není podporován.


### 🪟 Windows
Nainstalujte nejnovější stabilní verzi pomocí jednoho z následujících příkazů:

**WinGet**
```
winget install --id Microsoft.PowerShell --source winget
```
**Standardní instalace s grafickým průvodcem**
```
iex "& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI"
```
**Standardní instalace bez grafického průvodce**
```
iex "& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet"
```

> Bezpečnostní politika Windows ve výchozím nastavení blokuje spouštění skriptů. Pro umožnění běhu automatizačních nástrojů byla zvolena politika \texttt{RemoteSigned}, která povoluje lokální skripty bez omezení (aplikováno pouze na aktuálního uživatele): `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force`

### 🐧 Linux (Debian)
```
wget https://github.com/berkley4/icu-74-debian/releases/download/74.2-2/libicu74_74.2-2_amd64.deb
dpkg --install ./libicu74_74.2-2_amd64.deb
rm ./libicu74_74.2-2_amd64.deb
wget https://github.com/PowerShell/PowerShell/releases/download/v7.5.2/powershell_7.5.2-1.deb_amd64.deb
dpkg --install ./powershell_7.5.2-1.deb_amd64.deb
rm ./powershell_7.5.2-1.deb_amd64.deb
```
> Na systémech Linux se politika \texttt{ExecutionPolicy} neuplatňuje a příkaz pro její změnu není vyžadován. Bezpečnost je zde řízena na úrovni souborového systému. Pro spuštění skriptu stačí nastavit práva souboru standardním systémovým příkazem: `chmod +x nazev_skriptu.ps1`
> SCIBOTARU. PowerShell: Issue #25865 [online]. OnlyDust, 2024 [cit. 2025-12-14]. Dostupné z: https://www.onlydust.com/repositories/PowerShell/PowerShell/issues/25865.

### 🍎 macOS
```
brew install --cask powershell
```
```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

