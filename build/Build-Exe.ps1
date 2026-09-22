#Requires -Version 5.1
<#
.SYNOPSIS
    Compila a ferramenta de diagnóstico em um executável standalone
    (MonitorSistema.exe) usando o módulo ps2exe, com ícone próprio e
    manifesto de elevação automática (Administrador).

.DESCRIPTION
    Funde todos os módulos PowerShell (src\Modules\*.psm1) e o script
    principal em um único arquivo, para que o .exe final não dependa de
    arquivos externos — pode ser copiado sozinho para qualquer máquina
    do parque de TI.

.EXAMPLE
    .\build\Build-Exe.ps1
#>
[CmdletBinding()]
param(
    [string]$PastaSaida = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)

$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $raiz 'src'
$modulosDir = Join-Path $srcDir 'Modules'
$iconPng = Join-Path $srcDir 'assets\icon.png'
$iconIco = Join-Path $srcDir 'assets\icon.ico'
$mainScript = Join-Path $srcDir 'Invoke-DiagnosticoCompleto.ps1'

# --- 1) Garante o módulo ps2exe ---
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando módulo ps2exe (PowerShell Gallery)...' -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force

# --- 2) Garante o ícone .ico (ps2exe exige .ico, não .png) ---
if (-not (Test-Path $iconIco)) {
    if (-not (Test-Path $iconPng)) {
        throw "Ícone não encontrado em $iconPng. Coloque a imagem em src\assets\icon.png antes de compilar."
    }
    Write-Host 'Convertendo ícone PNG -> ICO...' -ForegroundColor Yellow
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($iconPng)
    $resized = New-Object System.Drawing.Bitmap($bitmap, 256, 256)
    $stream = New-Object System.IO.FileStream($iconIco, [System.IO.FileMode]::Create)
    $icon = [System.Drawing.Icon]::FromHandle($resized.GetHicon())
    $icon.Save($stream)
    $stream.Close()
    $icon.Dispose(); $resized.Dispose(); $bitmap.Dispose()
}

# --- 3) Funde módulos + script principal em um único arquivo ---
New-Item -ItemType Directory -Path $PastaSaida -Force | Out-Null
$mergedPath = Join-Path $PastaSaida 'MonitorSistema.merged.ps1'

$principalBruto = Get-Content -Path $mainScript -Raw
$marcador = "# ---FIM-DO-PARAM--- (marcador usado por build\Build-Exe.ps1 — não remover)"
$partes = $principalBruto -split [regex]::Escape($marcador), 2
if ($partes.Count -ne 2) {
    throw "Marcador '$marcador' não encontrado em $mainScript. Build cancelado para evitar um .exe malformado."
}
$cabecalhoParam = $partes[0].TrimEnd()
$corpoPrincipal = $partes[1]
$marcadorInicioImport = '# ---INICIO-IMPORT-MODULES--- (bloco inteiro removido por build\Build-Exe.ps1 no .exe compilado — as funções já vêm fundidas acima)'
$marcadorFimImport = '# ---FIM-IMPORT-MODULES---'
$padraoImport = [regex]::Escape($marcadorInicioImport) + '(?s).*?' + [regex]::Escape($marcadorFimImport)
if ($corpoPrincipal -notmatch $padraoImport) {
    throw "Marcadores de import-module não encontrados em $mainScript. Build cancelado para evitar um .exe malformado."
}
$corpoPrincipal = $corpoPrincipal -replace $padraoImport, ''

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine($cabecalhoParam)
[void]$sb.AppendLine('')
[void]$sb.AppendLine('# ==== Funções dos módulos (fundidas para gerar um .exe autocontido) ====')

$modulos = @(
    'Diag.Common.psm1',
    'Diag.Inventario.psm1',
    'Diag.Energia.psm1',
    'Diag.Monitor.psm1',
    'Diag.Eventos.psm1',
    'Diag.Relatorio.psm1'
)
foreach ($m in $modulos) {
    $caminho = Join-Path $modulosDir $m
    $conteudo = Get-Content -Path $caminho -Raw
    $conteudo = $conteudo -replace '(?m)^#Requires.*$', ''
    $conteudo = $conteudo -replace '(?m)^Export-ModuleMember.*$', ''
    [void]$sb.AppendLine("# ---- $m ----")
    [void]$sb.AppendLine($conteudo)
}

[void]$sb.AppendLine('# ==== Corpo principal ====')
[void]$sb.AppendLine($corpoPrincipal)

$sb.ToString() | Out-File -FilePath $mergedPath -Encoding UTF8

# --- 4) Valida sintaxe do arquivo fundido antes de compilar ---
$erros = $null
$tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile($mergedPath, [ref]$tokens, [ref]$erros) | Out-Null
if ($erros.Count -gt 0) {
    $erros | ForEach-Object { Write-Host "ERRO: $($_.Message) (linha $($_.Extent.StartLineNumber))" -ForegroundColor Red }
    throw 'O script fundido contém erros de sintaxe. Build cancelado.'
}
Write-Host 'Script fundido validado com sucesso.' -ForegroundColor Green

# --- 5) Compila com ps2exe ---
# O compilador C# subjacente (CompileAssemblyFromSource) herda o bloco de variáveis
# de ambiente do processo atual, que tem um limite de 65535 bytes no Windows. Em
# máquinas com muitas variáveis de ambiente (comum com diversas ferramentas de dev
# instaladas), a compilação falha nesse limite. Para não depender do ambiente de
# quem executa o build, a compilação roda sempre em um processo filho com um
# ambiente mínimo e controlado.
$exePath = Join-Path $PastaSaida 'MonitorSistema.exe'
Write-Host "Compilando $exePath ..." -ForegroundColor Cyan

$compileScript = Join-Path $PastaSaida '_compile.ps1'
@"
Import-Module ps2exe -Force
Invoke-ps2exe ``
    -inputFile '$mergedPath' ``
    -outputFile '$exePath' ``
    -iconFile '$iconIco' ``
    -title 'Monitor de Sistema - Diagnóstico de Desempenho e Bateria' ``
    -description 'Coleta e correlaciona dados para identificar apps que causam lentidão/dreno de bateria' ``
    -company 'Ferramenta de Monitoramento' ``
    -product 'Monitor de Sistema' ``
    -version '1.0.0.0' ``
    -requireAdmin ``
    -noConsole:`$false
"@ | Out-File -FilePath $compileScript -Encoding UTF8

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$compileScript`""
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables.Clear()
$essenciais = 'SystemRoot', 'windir', 'PATH', 'TEMP', 'TMP', 'USERPROFILE', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramData', 'ComSpec', 'PATHEXT', 'USERNAME', 'COMPUTERNAME', 'PSModulePath', 'NUMBER_OF_PROCESSORS', 'OS'
foreach ($v in $essenciais) {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($val) { $psi.EnvironmentVariables[$v] = $val }
}

$proc = [System.Diagnostics.Process]::Start($psi)
$saidaCompilador = $proc.StandardOutput.ReadToEnd()
$erroCompilador = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
Write-Host $saidaCompilador
if ($erroCompilador) { Write-Host $erroCompilador -ForegroundColor Red }
Remove-Item -LiteralPath $compileScript -Force -ErrorAction SilentlyContinue

if (Test-Path $exePath) {
    Write-Host "`nExecutável gerado com sucesso: $exePath" -ForegroundColor Green
} else {
    throw 'Falha ao gerar o executável.'
}
