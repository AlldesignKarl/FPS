# =============================================================================
#  GPU BOOSTER 920MX - Instalador de una linea
#  Uso (pegar en PowerShell):
#    irm https://raw.githubusercontent.com/AlldesignKarl/FPS/refs/heads/claude/magical-hopper-b7gkdd/instalar.ps1 | iex
#
#  Descarga la ultima version a %LOCALAPPDATA%\GpuBooster920MX (sin tocar nada
#  mas del sistema) y abre el diagnostico con permisos de administrador.
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
    Write-Host '  Abriendo el diagnostico (Windows pedira permiso: pulsa SI)...' -ForegroundColor Green
    $diag = Join-Path $dest 'src\Diagnostico.ps1'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$diag`"")
    Write-Host '  Listo. Sigue las instrucciones de la ventana nueva.' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Copia este mensaje y pegalo en el chat.' -ForegroundColor Yellow
}
}
