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
iex "& { $(irm [https://aka.ms/install-powershell.ps1](https://aka.ms/install-powershell.ps1)) } -UseMSI"
```
**Standardní instalace bez grafického průvodce**
```
iex "& { $(irm [https://aka.ms/install-powershell.ps1](https://aka.ms/install-powershell.ps1)) } -UseMSI -Quiet"
```
### 🐧 Linux / 🍎 macOS
```
curl -L [https://aka.ms/install-powershell.sh](https://aka.ms/install-powershell.sh) | sudo bash
```