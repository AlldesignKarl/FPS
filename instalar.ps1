# =============================================================================
#  GPU BOOSTER 920MX - Instalador de una linea
#  Uso (pegar en PowerShell):
#    irm https://raw.githubusercontent.com/AlldesignKarl/FPS/refs/heads/claude/magical-hopper-b7gkdd/instalar.ps1 | iex
#
#  Descarga la ultima version a %LOCALAPPDATA%\GpuBooster920MX (sin tocar nada
#  mas del sistema), crea accesos directos en el escritorio y abre el Booster.
# =============================================================================
# Todo va dentro de un bloque para no cambiar nada de la sesion de PowerShell del usuario.
& {
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $branch = 'claude/magical-hopper-b7gkdd'
    $url    = "https://github.com/AlldesignKarl/FPS/archive/refs/heads/$branch.zip"
    $dest   = Join-Path $env:LOCALAPPDATA 'GpuBooster920MX'
    $zip    = Join-Path $env:TEMP 'GpuBooster920MX.zip'
    $tmp    = Join-Path $env:TEMP 'GpuBooster920MX_extract'

    Write-Host ''
    Write-Host '  GPU BOOSTER 920MX - descargando la ultima version...' -ForegroundColor Green
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1

    # Se sustituye el programa pero se conservan tools\ (PresentMon) y reports\ (informes).
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if (Test-Path (Join-Path $dest 'src')) { Remove-Item (Join-Path $dest 'src') -Recurse -Force }
    Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $dest -Recurse -Force
    Get-ChildItem $dest -Recurse -File | Unblock-File
    Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "  Instalado en: $dest" -ForegroundColor Gray

    # Accesos directos en el escritorio (no hara falta volver a pegar nada).
    $ws = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath('Desktop')
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $links = @(
        @{ Name = 'GPU Booster 920MX';                File = 'src\Booster.ps1';     Extra = '' },
        @{ Name = 'GPU Booster - Restaurar todo';     File = 'src\Booster.ps1';     Extra = ' -Restaurar' },
        @{ Name = 'GPU Booster - Diagnostico';        File = 'src\Diagnostico.ps1'; Extra = '' }
    )
    foreach ($ln in $links) {
        $sc = $ws.CreateShortcut((Join-Path $desk "$($ln.Name).lnk"))
        $sc.TargetPath = $ps
        $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dest $ln.File)`"$($ln.Extra)"
        $sc.WorkingDirectory = $dest
        $sc.Save()
    }
    Write-Host '  Accesos directos creados en el escritorio.' -ForegroundColor Gray

    Write-Host '  Abriendo GPU BOOSTER (Windows pedira permiso: pulsa SI)...' -ForegroundColor Green
    $boost = Join-Path $dest 'src\Booster.ps1'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$boost`"")
    Write-Host '  Listo. Sigue las instrucciones de la ventana nueva.' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Copia este mensaje y pegalo en el chat.' -ForegroundColor Yellow
}
}
