#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnóstico completo de desempenho e bateria para Windows 11 — coleta dados,
    monitora o comportamento real do sistema por um período e gera um relatório
    HTML apontando quais aplicativos são os prováveis responsáveis.

.DESCRIPTION
    Ferramenta somente-leitura: não desinstala, não altera configurações, não
    finaliza processos. Apenas coleta e correlaciona sinais nativos do Windows
    (Registro, powercfg, Log de Eventos, Agendador de Tarefas, contadores de
    desempenho) para apontar aplicativos instalados recentemente que estejam
    associados a alto consumo de recursos ou dreno de bateria.

.PARAMETER DuracaoMonitoramentoMinutos
    Duração da janela de monitoramento contínuo. Durante esse período, o usuário
    deve usar o notebook normalmente para que a coleta capture o comportamento
    real. Padrão: 30 minutos.

.PARAMETER IntervaloAmostragemSegundos
    Intervalo entre amostras de processos/bateria. Padrão: 15 segundos.

.PARAMETER DiasSoftwareRecente
    Janela, em dias, para considerar um software/serviço/tarefa "recém-instalado".
    Padrão: 30 dias.

.PARAMETER PularEnergyReport
    Pula o trace de 60s do 'powercfg /energy' (caso já tenha sido executado ou
    para acelerar testes).

.PARAMETER AbrirRelatorio
    Abre o relatório (PDF, ou HTML se o PDF não puder ser gerado) ao final.

.PARAMETER PastaBase
    Pasta onde a subpasta do relatório será criada. Padrão: "Relatório Monitor
    Sistema" na Área de Trabalho do usuário atual.

.PARAMETER SemCompactar
    Não gera o .zip final com todos os relatórios (por padrão, um .zip é criado
    ao lado da pasta de saída para facilitar o envio a quem for analisar).

.EXAMPLE
    .\Invoke-DiagnosticoCompleto.ps1 -DuracaoMonitoramentoMinutos 45 -AbrirRelatorio

.EXAMPLE
    .\Invoke-DiagnosticoCompleto.ps1 -DuracaoMonitoramentoMinutos 1 -IntervaloAmostragemSegundos 5
    Execução rápida para validar a ferramenta.
#>
[CmdletBinding()]
param(
    [int]$DuracaoMonitoramentoMinutos = 30,
    [int]$IntervaloAmostragemSegundos = 15,
    [int]$DiasSoftwareRecente = 30,
    [switch]$PularEnergyReport,
    [switch]$AbrirRelatorio,
    [string]$PastaBase = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Relatório Monitor Sistema'),
    [switch]$SemCompactar,
    [switch]$SemPausar
)
# ---FIM-DO-PARAM--- (marcador usado por build\Build-Exe.ps1 — não remover)

$ErrorActionPreference = 'Stop'

# A partir daqui, TUDO roda dentro de um try/finally: se qualquer coisa falhar
# (elevação, importação de módulo, erro inesperado), o erro é exibido de forma
# legível e a janela SÓ fecha depois que o usuário apertar Enter. Sem isso, um
# executável compilado (ps2exe) que falha cedo simplesmente "pisca e some", sem
# dar nenhuma pista do que aconteceu — foi exatamente esse sintoma relatado em
# campo quando o .exe não ficava elevado corretamente.
try {

# ---INICIO-IMPORT-MODULES--- (bloco inteiro removido por build\Build-Exe.ps1 no .exe compilado — as funções já vêm fundidas acima)
$pastaModulos = Join-Path $PSScriptRoot 'Modules'
Import-Module (Join-Path $pastaModulos 'Diag.Common.psm1') -Force
Import-Module (Join-Path $pastaModulos 'Diag.Inventario.psm1') -Force
Import-Module (Join-Path $pastaModulos 'Diag.Energia.psm1') -Force
Import-Module (Join-Path $pastaModulos 'Diag.Monitor.psm1') -Force
Import-Module (Join-Path $pastaModulos 'Diag.Eventos.psm1') -Force
Import-Module (Join-Path $pastaModulos 'Diag.Relatorio.psm1') -Force
Import-Module (Join-Path $pastaModulos 'Diag.Tray.psm1') -Force
# ---FIM-IMPORT-MODULES---

# --- Elevação automática ---
if (-not (Test-DiagIsAdmin)) {
    # No .exe compilado (build\Build-Exe.ps1), o manifesto -requireAdmin já força
    # o Windows a pedir elevação ANTES do processo iniciar — se chegamos aqui sem
    # ser admin, é porque a elevação foi negada/cancelada. Um relançamento manual
    # não é confiável nesse caso ($PSCommandPath não aponta para um arquivo .ps1
    # real dentro de um .exe compilado), então apenas avisamos com clareza.
    $scriptValido = $PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue) -and $PSCommandPath.ToLower().EndsWith('.ps1')

    if ($scriptValido) {
        Write-Host 'Este diagnóstico precisa de privilégios de Administrador.' -ForegroundColor Yellow
        Write-Host 'Reabrindo com elevação...' -ForegroundColor Yellow
        $argList = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        foreach ($key in $PSBoundParameters.Keys) {
            $val = $PSBoundParameters[$key]
            if ($val -is [switch]) {
                if ($val.IsPresent) { $argList += "-$key" }
            } else {
                $argList += "-$key"; $argList += "$val"
            }
        }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
        return
    } else {
        Write-Host ''
        Write-Host '=====================================================================' -ForegroundColor Red
        Write-Host ' ESTE DIAGNÓSTICO PRECISA SER EXECUTADO COMO ADMINISTRADOR.' -ForegroundColor Red
        Write-Host ''
        Write-Host ' A elevação (janela do Windows perguntando "Deseja permitir que este' -ForegroundColor Yellow
        Write-Host ' aplicativo faça alterações...") não foi concedida. Clique com o' -ForegroundColor Yellow
        Write-Host ' botão direito no MonitorSistema.exe e escolha "Executar como' -ForegroundColor Yellow
        Write-Host ' administrador", e na janela do Controle de Conta de Usuário' -ForegroundColor Yellow
        Write-Host ' clique em "Sim".' -ForegroundColor Yellow
        Write-Host '=====================================================================' -ForegroundColor Red
        return
    }
}

# --- Bandeja do sistema ---
# Ao minimizar a janela do console, ela some da barra de tarefas e um ícone
# de bandeja assume o lugar (clique duplo ou menu para restaurar). O
# diagnóstico continua rodando normalmente enquanto minimizado.
$trayWatcher = $null
try {
    $trayWatcher = Start-DiagTrayWatcher -TituloBandeja 'Monitor de Sistema - Diagnóstico em andamento'
} catch {
    # Bandeja é um recurso de conforto, não crítico — segue sem ela se falhar
}

# --- Preparação ---
New-Item -ItemType Directory -Path $PastaBase -Force | Out-Null
$pastaSaida = New-DiagOutputFolder -BaseFolder $PastaBase
$pastaRaw = Join-Path $pastaSaida 'raw'
Initialize-DiagLog -Path (Join-Path $pastaSaida 'execucao.log')

Write-DiagLog "=== Diagnóstico de Desempenho e Bateria — $env:COMPUTERNAME ===" 'INFO'
Write-DiagLog "Pasta de saída: $pastaSaida" 'INFO'

$dataExecucao = Get-Date

# --- 1) Inventário estático ---
Write-DiagLog 'Coletando software instalado (Registro)...' 'INFO'
$software = Get-DiagInstalledSoftware
$software | Export-Csv -Path (Join-Path $pastaRaw 'software_instalado.csv') -NoTypeInformation -Encoding UTF8
$softwareRecente = $software | Where-Object { $_.DataInstalacao -and $_.DataInstalacao -gt $dataExecucao.AddDays(-$DiasSoftwareRecente) }
Write-DiagLog "$(@($software).Count) programas encontrados, $(@($softwareRecente).Count) instalados nos últimos $DiasSoftwareRecente dias." 'OK'

Write-DiagLog 'Coletando itens de inicialização...' 'INFO'
$startup = Get-DiagStartupItems
$startup | Export-Csv -Path (Join-Path $pastaRaw 'itens_inicializacao.csv') -NoTypeInformation -Encoding UTF8
$startupRecente = $startup | Where-Object { $_.ExecutavelData -and $_.ExecutavelData -gt $dataExecucao.AddDays(-$DiasSoftwareRecente) }
Write-DiagLog "$(@($startup).Count) itens de inicialização, $(@($startupRecente).Count) recentes." 'OK'

Write-DiagLog 'Coletando tarefas agendadas suspeitas...' 'INFO'
$tarefas = @(Get-DiagScheduledTasksRecentes -DiasRecente $DiasSoftwareRecente)
$tarefas | Export-Csv -Path (Join-Path $pastaRaw 'tarefas_agendadas.csv') -NoTypeInformation -Encoding UTF8
Write-DiagLog "$(@($tarefas).Count) tarefas agendadas sinalizadas." 'OK'

Write-DiagLog 'Coletando serviços automáticos recém-instalados...' 'INFO'
$servicos = @(Get-DiagServicosRecentes -DiasRecente $DiasSoftwareRecente)
$servicos | Export-Csv -Path (Join-Path $pastaRaw 'servicos_recentes.csv') -NoTypeInformation -Encoding UTF8
Write-DiagLog "$(@($servicos).Count) serviços automáticos recentes." 'OK'

# --- 2) Energia (snapshot inicial) ---
Write-DiagLog 'Verificando status da bateria...' 'INFO'
$bateria = Get-DiagBatteryStatus
if ($bateria.Presente) {
    Write-DiagLog "Bateria: $($bateria.CargaPercentual)% | No carregador: $($bateria.NoCarregador)" 'OK'
} else {
    Write-DiagLog 'Nenhuma bateria detectada (desktop?). Métricas de bateria ficarão vazias.' 'AVISO'
}

$energyReportInfo = [pscustomobject]@{ CaminhoRelatorio = ''; Gerado = $false; Erros = 0; Avisos = 0; TimersOfensores = @() }
if (-not $PularEnergyReport) {
    Write-DiagLog 'Executando powercfg /energy (trace de 60s, aguarde)...' 'INFO'
    $caminhoEnergy = Join-Path $pastaSaida 'powercfg_energy.html'
    $energyReportInfo = Invoke-DiagEnergyReport -OutputHtmlPath $caminhoEnergy -DuracaoSegundos 60
    Write-DiagLog "powercfg /energy concluído: $($energyReportInfo.Erros) erro(s), $($energyReportInfo.Avisos) aviso(s)." 'OK'
} else {
    Write-DiagLog 'powercfg /energy pulado (parâmetro -PularEnergyReport).' 'AVISO'
}

Write-DiagLog 'Verificando processos que impedem suspensão do sistema...' 'INFO'
$powerRequests = Invoke-DiagPowerRequests

# --- 3) Monitoramento contínuo ---
$csvProcessos = Join-Path $pastaRaw 'monitoramento_processos.csv'
$csvBateria = Join-Path $pastaRaw 'monitoramento_bateria.csv'

if ($DuracaoMonitoramentoMinutos -gt 0) {
    if ($DuracaoMonitoramentoMinutos -lt 20) {
        Write-DiagLog "Janela de monitoramento curta ($DuracaoMonitoramentoMinutos min). Para uma medição confiável do dreno de bateria, prefira 45-60 minutos sem o carregador, com uso normal do notebook." 'AVISO'
    }
    Write-Host ''
    Write-Host ">>> Use o notebook normalmente pelos próximos $DuracaoMonitoramentoMinutos minuto(s) (abra os apps que suspeita, navegue, etc). Preferencialmente sem o carregador. A coleta é silenciosa." -ForegroundColor Cyan
    Write-Host ''
    Start-DiagResourceMonitoring -DuracaoMinutos $DuracaoMonitoramentoMinutos -IntervaloSegundos $IntervaloAmostragemSegundos -CsvSaida $csvProcessos -CsvBateria $csvBateria
} else {
    Write-DiagLog 'Monitoramento contínuo desativado (duração = 0).' 'AVISO'
}

$resumoMonitoramento = Get-DiagMonitoringSummary -CsvProcessos $csvProcessos -CsvBateria $csvBateria

# --- 4) Relatório de bateria (histórico) ---
$batteryReportInfo = [pscustomobject]@{ CaminhoRelatorio = ''; Gerado = $false; CapacidadeProjeto_mWh = $null; CapacidadeAtual_mWh = $null; DesgastePercentual = $null }
if ($bateria.Presente) {
    Write-DiagLog 'Gerando relatório de saúde da bateria (powercfg /batteryreport)...' 'INFO'
    $caminhoBatReport = Join-Path $pastaSaida 'powercfg_batteryreport.html'
    $batteryReportInfo = Invoke-DiagBatteryReport -OutputHtmlPath $caminhoBatReport
    if ($batteryReportInfo.DesgastePercentual -ne $null) {
        Write-DiagLog "Desgaste da bateria: $($batteryReportInfo.DesgastePercentual)%" 'OK'
    }
}

# --- 5) Eventos do sistema ---
Write-DiagLog 'Analisando eventos de energia (desligamentos, suspensão)...' 'INFO'
$eventosEnergia = Get-DiagEventosEnergia -DiasRecente 7

Write-DiagLog 'Analisando erros de aplicativos recentes...' 'INFO'
$errosApps = Get-DiagErrosAplicativosRecentes -DiasRecente 14
$errosApps | Export-Csv -Path (Join-Path $pastaRaw 'erros_aplicativos.csv') -NoTypeInformation -Encoding UTF8

# --- 6) Correlação e pontuação de suspeitos ---
Write-DiagLog 'Cruzando sinais e calculando suspeitos...' 'INFO'
$suspeitos = Build-DiagSuspectScore -Softwares $software -Startup $startup -TarefasAgendadas $tarefas `
    -ServicosRecentes $servicos -ResumoMonitoramento $resumoMonitoramento -EnergyReport $energyReportInfo `
    -PowerRequests $powerRequests -ErrosAplicativos $errosApps -DiasSoftwareRecente $DiasSoftwareRecente

Write-DiagLog "$(@($suspeitos).Count) aplicativo(s) suspeito(s) identificado(s)." 'OK'
$suspeitos | Select-Object Nome, Pontuacao, @{N = 'Evidencias'; E = { $_.Evidencias -join ' | ' } } |
    Export-Csv -Path (Join-Path $pastaRaw 'suspeitos_completo.csv') -NoTypeInformation -Encoding UTF8

# --- 7) Relatório HTML + PDF ---
Write-DiagLog 'Gerando relatório HTML...' 'INFO'
$caminhoHtml = Join-Path $pastaSaida 'Relatorio.html'
$duracaoTexto = if ($DuracaoMonitoramentoMinutos -gt 0) { "$DuracaoMonitoramentoMinutos minuto(s), amostras a cada $IntervaloAmostragemSegundos s" } else { 'não executado' }

New-DiagHtmlReport -CaminhoSaida $caminhoHtml -NomeMaquina $env:COMPUTERNAME -DataExecucao $dataExecucao `
    -Suspeitos $suspeitos -Bateria $bateria -BatteryReportInfo $batteryReportInfo -EnergyReportInfo $energyReportInfo `
    -PowerRequests $powerRequests -ResumoMonitoramento $resumoMonitoramento -DrenoPorHora $resumoMonitoramento.DrenoPorHora `
    -SoftwareRecente $softwareRecente -StartupRecente $startupRecente -TarefasAgendadas $tarefas -ServicosRecentes $servicos `
    -EventosEnergia $eventosEnergia -ErrosAplicativos $errosApps -DuracaoMonitoramentoTexto $duracaoTexto

Write-DiagLog "Relatório HTML gerado: $caminhoHtml" 'OK'

Write-DiagLog 'Convertendo relatório para PDF...' 'INFO'
$caminhoPdf = Join-Path $pastaSaida 'Relatorio.pdf'
$pdfGerado = Convert-DiagHtmlToPdf -CaminhoHtml $caminhoHtml -CaminhoPdf $caminhoPdf
if ($pdfGerado) {
    Write-DiagLog "Relatório PDF gerado: $caminhoPdf" 'OK'
} else {
    Write-DiagLog 'PDF não pôde ser gerado — o relatório HTML continua disponível.' 'AVISO'
}

# --- 8) Compactação para envio ---
$caminhoZip = $null
if (-not $SemCompactar) {
    Write-DiagLog 'Compactando relatórios em .zip para envio...' 'INFO'
    $nomeZip = (Split-Path -Leaf $pastaSaida) + '.zip'
    $caminhoZip = Join-Path $PastaBase $nomeZip
    try {
        if (Test-Path $caminhoZip) { Remove-Item -LiteralPath $caminhoZip -Force }
        Compress-Archive -Path $pastaSaida -DestinationPath $caminhoZip -CompressionLevel Optimal -Force
        Write-DiagLog "Arquivo .zip gerado: $caminhoZip" 'OK'
    } catch {
        Write-DiagLog "Falha ao compactar relatórios: $($_.Exception.Message)" 'AVISO'
        $caminhoZip = $null
    }
}

Write-Host ''
Write-Host "=== Diagnóstico concluído. Relatórios em: $pastaSaida ===" -ForegroundColor Green
if ($caminhoZip) {
    Write-Host "=== Envie este arquivo único para análise: $caminhoZip ===" -ForegroundColor Green
}

if ($AbrirRelatorio) {
    if ($pdfGerado) { Start-Process $caminhoPdf } else { Start-Process $caminhoHtml }
}
if ($caminhoZip) {
    Start-Process 'explorer.exe' -ArgumentList "/select,`"$caminhoZip`""
}

} catch {
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host ' O DIAGNÓSTICO FOI INTERROMPIDO POR UM ERRO.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host '=====================================================================' -ForegroundColor Red

    try {
        $pastaErro = [Environment]::GetFolderPath('Desktop')
        $arquivoErro = Join-Path $pastaErro "MonitorSistema_erro_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').txt"
        @(
            "Erro: $($_.Exception.Message)"
            ''
            'Stack:'
            $_.ScriptStackTrace
        ) | Out-File -FilePath $arquivoErro -Encoding UTF8
        Write-Host "Detalhes salvos em: $arquivoErro" -ForegroundColor Yellow
    } catch { }
} finally {
    if ($trayWatcher) {
        try { Stop-DiagTrayWatcher -Watcher $trayWatcher } catch { }
    }
    if (-not $SemPausar) {
        Write-Host ''
        Read-Host 'Pressione Enter para fechar esta janela'
    }
}
