#Requires -Version 5.1

function Find-DiagEdgeExecutable {
    $candidatos = @(
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    return ($candidatos | Where-Object { Test-Path $_ } | Select-Object -First 1)
}

function Convert-DiagHtmlToPdf {
    <#
        Converte um relatório HTML em PDF usando o Microsoft Edge (Chromium) em
        modo headless — já vem instalado no Windows 11, sem depender de bibliotecas
        de terceiros.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CaminhoHtml,
        [Parameter(Mandatory)][string]$CaminhoPdf
    )

    $edge = Find-DiagEdgeExecutable
    if (-not $edge) {
        Write-DiagLog 'Microsoft Edge não encontrado — geração de PDF pulada (o relatório HTML continua disponível).' 'AVISO'
        return $false
    }

    if (Test-Path $CaminhoPdf) { Remove-Item -LiteralPath $CaminhoPdf -Force -ErrorAction SilentlyContinue }

    # Perfil temporário isolado: evita conflito quando o usuário já tem o Edge aberto
    # normalmente (uma segunda instância no mesmo perfil falha silenciosamente).
    $perfilTemp = Join-Path $env:TEMP ("diag_edge_pdf_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $perfilTemp -Force | Out-Null

    $uri = ([uri]$CaminhoHtml).AbsoluteUri
    $argumentos = @(
        '--headless=new'
        '--disable-gpu'
        '--no-sandbox'
        "--user-data-dir=$perfilTemp"
        "--print-to-pdf=$CaminhoPdf"
        '--print-to-pdf-no-header'
        $uri
    )

    try {
        $proc = Start-Process -FilePath $edge -ArgumentList $argumentos -PassThru -WindowStyle Hidden
        $proc.WaitForExit(20000) | Out-Null
        if (-not $proc.HasExited) { $proc.Kill() }
    } catch {
        Write-DiagLog "Falha ao gerar PDF: $($_.Exception.Message)" 'AVISO'
    } finally {
        Remove-Item -LiteralPath $perfilTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Aguarda o arquivo ficar disponível (o processo pode encerrar antes do flush em disco)
    $tentativas = 0
    while (-not (Test-Path $CaminhoPdf) -and $tentativas -lt 10) {
        Start-Sleep -Milliseconds 500
        $tentativas++
    }

    return (Test-Path $CaminhoPdf)
}

function Get-DiagNomeBase {
    # Normaliza "chrome.exe" -> "chrome" e "svchost#2" -> "svchost" para cruzar
    # processo (contador de desempenho) x software instalado. Entradas vêm de
    # dados reais (comandos de tarefas agendadas, PathName de serviços, nomes
    # de provedor de eventos) que podem conter aspas ou caracteres inválidos
    # de caminho (<, >, |) — GetFileNameWithoutExtension lança exceção nesses
    # casos, então tratamos como "sem correspondência" em vez de derrubar todo
    # o cálculo de suspeitos.
    param([string]$Texto)
    if (-not $Texto) { return '' }
    $textoLimpo = $Texto.Trim().Trim('"')
    try {
        $nome = ([IO.Path]::GetFileNameWithoutExtension($textoLimpo)).ToLowerInvariant()
    } catch {
        return ''
    }
    return ($nome -replace '#\d+$', '')
}

function Build-DiagSuspectScore {
    <#
        Cruza todos os sinais coletados e produz uma lista de "suspeitos" ordenada
        por pontuação. Cada sinal soma pontos e vira uma linha de evidência legível.
        Isso é o coração da análise: transforma dados brutos em um veredito.
    #>
    [CmdletBinding()]
    param(
        # AllowNull(): Get-DiagInstalledSoftware/Get-DiagStartupItems podem
        # legitimamente devolver $null (nenhum item, sem @() na origem) — sem
        # isso, a vinculação do parâmetro rejeitava $null e derrubava todo o
        # cálculo de suspeitos numa máquina sem nada a reportar nessas listas.
        [Parameter(Mandatory)][AllowNull()] $Softwares,
        [Parameter(Mandatory)][AllowNull()] $Startup,
        [Parameter(Mandatory)][AllowNull()] $TarefasAgendadas,
        [Parameter(Mandatory)][AllowNull()] $ServicosRecentes,
        [Parameter(Mandatory)][AllowNull()] $ResumoMonitoramento,
        [Parameter(Mandatory)][AllowNull()] $EnergyReport,
        [Parameter(Mandatory)][AllowNull()] $PowerRequests,
        [Parameter(Mandatory)][AllowNull()] $ErrosAplicativos,
        [int]$DiasSoftwareRecente = 30
    )

    $limite = (Get-Date).AddDays(-$DiasSoftwareRecente)
    $suspeitos = @{}

    function Get-OrCreate($nome) {
        if (-not $suspeitos.ContainsKey($nome)) {
            $suspeitos[$nome] = [pscustomobject]@{
                Nome       = $nome
                Pontuacao  = 0
                Evidencias = New-Object System.Collections.Generic.List[string]
            }
        }
        return $suspeitos[$nome]
    }

    # 1) Software instalado recentemente (peso base — é o ponto de partida da suspeita)
    $softwareRecente = $Softwares | Where-Object { $_.DataInstalacao -and $_.DataInstalacao -gt $limite }
    foreach ($s in $softwareRecente) {
        $chave = Get-DiagNomeBase $s.Nome
        $item = Get-OrCreate $chave
        $item.Pontuacao += 3
        $item.Evidencias.Add("Instalado em $($s.DataInstalacao.ToString('dd/MM/yyyy')) ($($s.Nome), editora: $($s.Editora))")
    }

    # 2) Itens de inicialização recentes
    foreach ($i in $Startup) {
        if ($i.ExecutavelData -and $i.ExecutavelData -gt $limite) {
            $chave = Get-DiagNomeBase $i.Nome
            $item = Get-OrCreate $chave
            $item.Pontuacao += 2
            $item.Evidencias.Add("Configurado para iniciar com o Windows ($($i.Origem), criado em $($i.ExecutavelData.ToString('dd/MM/yyyy')))")
        }
    }

    # 3) Tarefas agendadas recentes ou de origem não-Microsoft
    foreach ($t in $TarefasAgendadas) {
        $chave = Get-DiagNomeBase ($t.Executavel)
        if (-not $chave) { continue }
        $item = Get-OrCreate $chave
        if ($t.Recente) {
            $item.Pontuacao += 2
            $item.Evidencias.Add("Tarefa agendada recente: $($t.Nome) ($($t.DataRegistro))")
        } else {
            $item.Pontuacao += 1
            $item.Evidencias.Add("Possui tarefa agendada de origem externa: $($t.Nome)")
        }
    }

    # 4) Serviços com início automático instalados recentemente
    foreach ($srv in $ServicosRecentes) {
        $chave = Get-DiagNomeBase $srv.Executavel
        $item = Get-OrCreate $chave
        $item.Pontuacao += 3
        $item.Evidencias.Add("Serviço automático recém-instalado: $($srv.NomeExibicao) ($($srv.DataCriacaoExe.ToString('dd/MM/yyyy')))")
    }

    # 5) Consumo de CPU/memória observado durante o monitoramento (peso alto — comportamento real)
    if ($ResumoMonitoramento -and $ResumoMonitoramento.Processos) {
        $top = $ResumoMonitoramento.Processos | Sort-Object CpuMedia -Descending | Select-Object -First 10
        foreach ($p in $top) {
            $chave = Get-DiagNomeBase $p.Processo
            if ($chave -in @('system', 'idle', 'svchost', 'registry')) { continue }
            if ($p.CpuMedia -lt 6) { continue }
            $item = Get-OrCreate $chave
            if ($p.CpuMedia -ge 15) {
                $item.Pontuacao += 4
                $item.Evidencias.Add("Consumo médio de CPU alto durante o monitoramento: $($p.CpuMedia)% (pico $($p.CpuPico)%)")
            } else {
                $item.Pontuacao += 1
                $item.Evidencias.Add("Consumo de CPU relevante durante o monitoramento: $($p.CpuMedia)% em média")
            }
            $memMB = [math]::Round($p.MemMediaBytes / 1MB, 0)
            if ($memMB -ge 500) {
                $item.Pontuacao += 2
                $item.Evidencias.Add("Uso médio de memória elevado: $memMB MB")
            }
        }
    }

    # 6) Processos que solicitaram temporizador de alta resolução (dreno de bateria mesmo ocioso)
    if ($EnergyReport -and $EnergyReport.TimersOfensores) {
        foreach ($proc in $EnergyReport.TimersOfensores) {
            $chave = Get-DiagNomeBase $proc
            if (-not $chave) { continue }
            $item = Get-OrCreate $chave
            $item.Pontuacao += 4
            $item.Evidencias.Add("Solicitou temporizador de alta resolução ao Windows (powercfg /energy) — impede economia de energia da CPU")
        }
    }

    # 7) Processos que atualmente impedem o sistema de suspender/desligar a tela
    if ($PowerRequests -and $PowerRequests.Itens) {
        foreach ($req in $PowerRequests.Itens) {
            $m = [regex]::Match($req.Detalhe, '\[PROCESS\]\s*\\?Device\\?.*?\\(.+?\.exe)', 'IgnoreCase')
            if (-not $m.Success) { $m = [regex]::Match($req.Detalhe, '([\w\.\-]+\.exe)', 'IgnoreCase') }
            if ($m.Success) {
                $chave = Get-DiagNomeBase $m.Groups[1].Value
                $item = Get-OrCreate $chave
                $item.Pontuacao += 3
                $item.Evidencias.Add("Está impedindo o sistema de suspender agora (categoria: $($req.Categoria))")
            }
        }
    }

    # 8) Erros de aplicativo recorrentes (instabilidade -> pode causar lentidão/travamentos)
    foreach ($err in $ErrosAplicativos) {
        $chave = Get-DiagNomeBase $err.Origem
        if (-not $chave -or $err.Ocorrencias -lt 5) { continue }
        $item = Get-OrCreate $chave
        $item.Pontuacao += 1
        $item.Evidencias.Add("$($err.Ocorrencias) erros/avisos registrados no Log de Aplicativos nos últimos dias")
    }

    return ($suspeitos.Values | Where-Object { $_.Pontuacao -gt 0 } | Sort-Object Pontuacao -Descending)
}

function ConvertTo-DiagHtmlTable {
    param(
        [Parameter(Mandatory)][AllowNull()] $Dados,
        [string]$SemDadosTexto = 'Nenhum item encontrado.'
    )
    # Evita o operador @() sobre $Dados: numa build recente do PowerShell 5.1,
    # @() aplicado a um System.Collections.Generic.List<object> lança "Os
    # tipos de argumento não correspondem" (reproduzido em campo — acontecia
    # sempre que um chamador guardava uma List<object> dentro de uma
    # propriedade, ex. Invoke-DiagPowerRequests, em vez de deixar o pipeline
    # "desenrolar" a lista). foreach() enumera qualquer IEnumerable sem esse risco.
    if (-not $Dados) {
        return "<p class='vazio'>$SemDadosTexto</p>"
    }
    $temItens = $false
    foreach ($item in $Dados) { $temItens = $true; break }
    if (-not $temItens) {
        return "<p class='vazio'>$SemDadosTexto</p>"
    }
    $Dados | ConvertTo-Html -Fragment | Out-String
}

function New-DiagHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CaminhoSaida,
        [Parameter(Mandatory)][string]$NomeMaquina,
        [Parameter(Mandatory)][datetime]$DataExecucao,
        [Parameter(Mandatory)][AllowNull()] $Suspeitos,
        [Parameter(Mandatory)][AllowNull()] $Bateria,
        [Parameter(Mandatory)][AllowNull()] $BatteryReportInfo,
        [Parameter(Mandatory)][AllowNull()] $EnergyReportInfo,
        [Parameter(Mandatory)][AllowNull()] $PowerRequests,
        [Parameter(Mandatory)][AllowNull()] $ResumoMonitoramento,
        [AllowNull()] $DrenoPorHora,
        # SoftwareRecente/StartupRecente/EventosEnergia legitimamente chegam
        # $null quando não há nenhum item no período (Where-Object/pipeline
        # sem resultado vira $null, não array vazio) — sem AllowNull() a
        # vinculação do parâmetro rejeitava isso e derrubava o relatório
        # inteiro exatamente numa máquina "limpa", sem nada suspeito.
        [Parameter(Mandatory)][AllowNull()] $SoftwareRecente,
        [Parameter(Mandatory)][AllowNull()] $StartupRecente,
        [Parameter(Mandatory)][AllowNull()] $TarefasAgendadas,
        [Parameter(Mandatory)][AllowNull()] $ServicosRecentes,
        [Parameter(Mandatory)][AllowNull()] $EventosEnergia,
        [Parameter(Mandatory)][AllowNull()] $ErrosAplicativos,
        [string]$DuracaoMonitoramentoTexto,
        [string]$PlanoEnergia
    )

    $css = @'
body { font-family: Segoe UI, Arial, sans-serif; background:#f4f6f8; color:#1f2937; margin:0; padding:0 0 60px 0; }
header { background:#111827; color:#fff; padding:28px 40px; }
header h1 { margin:0; font-size:22px; }
header p { margin:6px 0 0 0; color:#9ca3af; font-size:13px; }
.container { max-width:1100px; margin:0 auto; padding:0 40px; }
section { background:#fff; border-radius:8px; padding:20px 24px; margin-top:24px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
h2 { font-size:17px; border-bottom:2px solid #e5e7eb; padding-bottom:8px; margin-top:0; color:#111827; }
table { border-collapse: collapse; width:100%; margin-top:10px; font-size:13px; }
th { background:#f3f4f6; text-align:left; padding:8px 10px; font-weight:600; color:#374151; }
td { padding:7px 10px; border-top:1px solid #eef0f2; vertical-align:top; }
tr:hover td { background:#fafbfc; }
.vazio { color:#6b7280; font-style:italic; }
.suspeito { border-left:4px solid #dc2626; background:#fef2f2; padding:14px 16px; margin-bottom:12px; border-radius:4px; }
.suspeito h3 { margin:0 0 6px 0; font-size:15px; color:#991b1b; }
.suspeito .pontos { float:right; background:#dc2626; color:#fff; font-size:12px; padding:2px 10px; border-radius:12px; }
.suspeito ul { margin:8px 0 0 0; padding-left:20px; font-size:13px; color:#374151; }
.kpis { display:flex; gap:16px; flex-wrap:wrap; }
.kpi { flex:1; min-width:150px; background:#f9fafb; border:1px solid #eef0f2; border-radius:6px; padding:14px; text-align:center; }
.kpi .valor { font-size:24px; font-weight:700; color:#111827; }
.kpi .rotulo { font-size:12px; color:#6b7280; margin-top:4px; }
.alerta { color:#b45309; background:#fffbeb; border-left:4px solid #f59e0b; padding:10px 14px; border-radius:4px; margin-top:10px; font-size:13px; }
.ok { color:#065f46; background:#ecfdf5; border-left:4px solid #10b981; padding:10px 14px; border-radius:4px; margin-top:10px; font-size:13px; }
footer { text-align:center; color:#9ca3af; font-size:12px; margin-top:30px; }
a { color:#2563eb; }
'@

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="pt-br"><head><meta charset="utf-8"><title>Diagnóstico de Desempenho e Bateria</title>')
    [void]$sb.AppendLine("<style>$css</style></head><body>")

    [void]$sb.AppendLine("<header><h1>Relatório de Diagnóstico — Desempenho e Bateria</h1><p>Máquina: $NomeMaquina &nbsp;|&nbsp; Gerado em: $($DataExecucao.ToString('dd/MM/yyyy HH:mm')) &nbsp;|&nbsp; Janela de monitoramento: $DuracaoMonitoramentoTexto</p></header>")
    [void]$sb.AppendLine('<div class="container">')

    # ---- Resumo executivo ----
    [void]$sb.AppendLine('<section><h2>Resumo Executivo</h2>')
    $cargaTxt = if ($Bateria.Presente) { "$($Bateria.CargaPercentual)%" } else { 'N/D (desktop ou bateria não detectada)' }
    $drenoTxt = if ($DrenoPorHora -ne $null) { "$DrenoPorHora %/h" } else { 'N/D' }
    $desgasteTxt = if ($BatteryReportInfo.DesgastePercentual -ne $null) { "$($BatteryReportInfo.DesgastePercentual)%" } else { 'N/D' }

    [void]$sb.AppendLine('<div class="kpis">')
    [void]$sb.AppendLine("<div class='kpi'><div class='valor'>$cargaTxt</div><div class='rotulo'>Carga da bateria no fim da coleta</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='valor'>$drenoTxt</div><div class='rotulo'>Taxa de dreno observada (sem carregador)</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='valor'>$desgasteTxt</div><div class='rotulo'>Desgaste da bateria (capacidade)</div></div>")
    [void]$sb.AppendLine("<div class='kpi'><div class='valor'>$(@($Suspeitos).Count)</div><div class='rotulo'>Aplicativos suspeitos identificados</div></div>")
    [void]$sb.AppendLine('</div>')

    if ($BatteryReportInfo.DesgastePercentual -ge 20) {
        [void]$sb.AppendLine("<div class='alerta'>A bateria apresenta desgaste de $($BatteryReportInfo.DesgastePercentual)% em relação à capacidade de projeto — isso por si só já reduz a autonomia, independente de software.</div>")
    }

    if (@($Suspeitos).Count -eq 0) {
        [void]$sb.AppendLine("<div class='ok'>Nenhum aplicativo se destacou como causa provável nos sinais coletados. Se os sintomas persistirem, considere aumentar a duração do monitoramento ou repetir a coleta em outro momento de uso típico.</div>")
    } else {
        [void]$sb.AppendLine('<p>Aplicativos abaixo, em ordem de suspeita, cruzando data de instalação, itens de inicialização, consumo real de CPU/memória durante o monitoramento e sinais de energia do Windows:</p>')
    }
    [void]$sb.AppendLine('</section>')

    # ---- Suspeitos ----
    $limiteExibicao = 12
    $suspeitosExibidos = $Suspeitos | Select-Object -First $limiteExibicao
    $restantes = [math]::Max(0, @($Suspeitos).Count - $limiteExibicao)

    [void]$sb.AppendLine('<section><h2>Principais Suspeitos</h2>')
    $rank = 0
    foreach ($s in $suspeitosExibidos) {
        $rank++
        $nomeSeguro = [System.Net.WebUtility]::HtmlEncode($s.Nome)
        [void]$sb.AppendLine("<div class='suspeito'><span class='pontos'>Pontuação: $($s.Pontuacao)</span><h3>$rank. $nomeSeguro</h3><ul>")
        foreach ($ev in $s.Evidencias) {
            [void]$sb.AppendLine("<li>$([System.Net.WebUtility]::HtmlEncode($ev))</li>")
        }
        [void]$sb.AppendLine('</ul></div>')
    }
    if (@($Suspeitos).Count -eq 0) { [void]$sb.AppendLine("<p class='vazio'>Nenhum suspeito.</p>") }
    if ($restantes -gt 0) {
        [void]$sb.AppendLine("<p class='vazio'>+ $restantes outro(s) item(ns) com pontuação mais baixa, omitidos aqui para foco. Lista completa em <code>raw/suspeitos_completo.csv</code>.</p>")
    }
    [void]$sb.AppendLine('</section>')

    # ---- Consumo de recursos monitorado ----
    [void]$sb.AppendLine('<section><h2>Consumo de Recursos Durante o Monitoramento (Top 20 por CPU média)</h2>')
    $topProcessos = $ResumoMonitoramento.Processos | Select-Object -First 20 |
        Select-Object Processo, Amostras,
            @{N = 'CPU Média (%)'; E = { $_.CpuMedia } },
            @{N = 'CPU Pico (%)'; E = { $_.CpuPico } },
            @{N = 'Memória Média'; E = { '{0:N0} MB' -f ($_.MemMediaBytes / 1MB) } },
            @{N = 'Memória Pico'; E = { '{0:N0} MB' -f ($_.MemPicoBytes / 1MB) } }
    [void]$sb.AppendLine((ConvertTo-DiagHtmlTable -Dados $topProcessos -SemDadosTexto 'Monitoramento não gerou amostras (duração pode ter sido 0).'))
    [void]$sb.AppendLine('</section>')

    # ---- Energia ----
    [void]$sb.AppendLine('<section><h2>Diagnóstico de Energia (powercfg)</h2>')
    $planoTxt = if ($PlanoEnergia) { [System.Net.WebUtility]::HtmlEncode($PlanoEnergia) } else { 'N/D' }
    [void]$sb.AppendLine("<p><strong>Plano de energia ativo:</strong> $planoTxt</p>")
    if ($EnergyReportInfo.Gerado) {
        [void]$sb.AppendLine("<p><strong>Relatório powercfg /energy:</strong> $($EnergyReportInfo.Erros) erro(s), $($EnergyReportInfo.Avisos) aviso(s) — <a href='$([IO.Path]::GetFileName($EnergyReportInfo.CaminhoRelatorio))'>abrir relatório completo</a></p>")
    } else {
        [void]$sb.AppendLine("<p><strong>Relatório powercfg /energy:</strong> não gerado nesta execução</p>")
    }
    if ($BatteryReportInfo.Gerado) {
        [void]$sb.AppendLine("<p><strong>Relatório powercfg /batteryreport:</strong> <a href='$([IO.Path]::GetFileName($BatteryReportInfo.CaminhoRelatorio))'>abrir relatório completo</a></p>")
    } else {
        [void]$sb.AppendLine("<p><strong>Relatório powercfg /batteryreport:</strong> não gerado nesta execução</p>")
    }

    [void]$sb.AppendLine('<h3 style="font-size:14px;margin-top:18px;">Processos impedindo suspensão do sistema (no momento da coleta)</h3>')
    [void]$sb.AppendLine((ConvertTo-DiagHtmlTable -Dados $PowerRequests.Itens -SemDadosTexto 'Nenhum processo está impedindo a suspensão do sistema no momento.'))
    [void]$sb.AppendLine('</section>')

    # ---- Eventos de energia ----
    [void]$sb.AppendLine('<section><h2>Eventos de Energia Recentes (desligamentos, suspensão, retomada)</h2>')
    [void]$sb.AppendLine((ConvertTo-DiagHtmlTable -Dados $EventosEnergia -SemDadosTexto 'Nenhum evento relevante nos últimos dias.'))
    [void]$sb.AppendLine('</section>')

    # ---- Software recente ----
    [void]$sb.AppendLine('<section><h2>Software Instalado Recentemente</h2>')
    $softTbl = $SoftwareRecente | Select-Object Nome, Versao, Editora,
        @{N = 'Data de Instalação'; E = { if ($_.DataInstalacao) { $_.DataInstalacao.ToString('dd/MM/yyyy') } else { 'N/D' } } }
    [void]$sb.AppendLine((ConvertTo-DiagHtmlTable -Dados $softTbl -SemDadosTexto 'Nenhum software com data de instalação recente encontrado no Registro.'))
    [void]$sb.AppendLine('</section>')

    # ---- Inicialização ----
    [void]$sb.AppendLine('<section><h2>Itens de Inicialização Recentes</h2>')
    $startupTbl = $StartupRecente | Select-Object Origem, Nome, Comando,
        @{N = 'Data do Executável'; E = { if ($_.ExecutavelData) { $_.ExecutavelData.ToString('dd/MM/yyyy') } else { 'N/D' } } }
    [void]$sb.AppendLine((ConvertTo-DiagHtmlTable -Dados $startupTbl -SemDadosTexto 'Nenhum item de inicialização recente encontrado.'))
    [void]$sb.AppendLine('</section>')

    # ---- Tarefas agendadas ----
    [void]$sb.AppendLine('<section><h2>Tarefas Agendadas Suspeitas</h2>')
    $tarefasTbl = $TarefasAgendadas | Select-Object Nome, Caminho, Autor,
        @{N = 'Data de Registro'; E = { if ($_.DataRegistro) { $_.DataRegistro.ToString('dd/MM/yyyy') } else { 'N/D' } } },
        Executavel
    [void]$sb.AppendLine((ConvertTo-DiagHtmlTable -Dados $tarefasTbl -SemDadosTexto 'Nenhuma tarefa agendada suspeita encontrada.'))
    [void]$sb.AppendLine('</section>')

    # ---- Serviços recentes ----
    [void]$sb.AppendLine('<section><h2>Serviços Automáticos Instalados Recentemente</h2>')
    [void]$sb.AppendLine((ConvertTo-DiagHtmlTable -Dados $ServicosRecentes -SemDadosTexto 'Nenhum serviço automático recém-instalado encontrado.'))
    [void]$sb.AppendLine('</section>')

    # ---- Erros de aplicativos ----
    [void]$sb.AppendLine('<section><h2>Erros de Aplicativos Mais Frequentes (Log do Windows)</h2>')
    [void]$sb.AppendLine((ConvertTo-DiagHtmlTable -Dados ($ErrosAplicativos | Select-Object -First 15) -SemDadosTexto 'Nenhum erro relevante registrado.'))
    [void]$sb.AppendLine('</section>')

    [void]$sb.AppendLine("<footer>Relatório gerado automaticamente. Nenhuma alteração foi feita no sistema — esta ferramenta apenas coleta e analisa dados. Decisões de remoção/desinstalação devem ser tomadas pelo analista.</footer>")
    [void]$sb.AppendLine('</div></body></html>')

    $sb.ToString() | Out-File -FilePath $CaminhoSaida -Encoding UTF8
}

Export-ModuleMember -Function *
