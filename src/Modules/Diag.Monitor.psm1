#Requires -Version 5.1

function Start-DiagResourceMonitoring {
    <#
        Amostra o consumo de CPU, memória e disco por processo, e o percentual de
        bateria, em intervalos regulares durante uma janela de tempo — para pegar
        o comportamento real de uso, não apenas uma fotografia pontual.
        Grava cada amostra incrementalmente em CSV (para sobreviver a interrupções).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DuracaoMinutos,
        [Parameter(Mandatory)][int]$IntervaloSegundos,
        [Parameter(Mandatory)][string]$CsvSaida,
        [Parameter(Mandatory)][string]$CsvBateria
    )

    $fim = (Get-Date).AddMinutes($DuracaoMinutos)
    $totalAmostras = [math]::Max(1, [math]::Floor(($DuracaoMinutos * 60) / $IntervaloSegundos))
    $amostraAtual = 0

    # Cabeçalhos
    'Timestamp,Processo,PID,CpuPercent,WorkingSetBytes,IOBytesPersec,HandleCount,ThreadCount' |
        Out-File -FilePath $CsvSaida -Encoding UTF8

    'Timestamp,CargaPercentual,NoCarregador' |
        Out-File -FilePath $CsvBateria -Encoding UTF8

    Write-DiagLog "Monitoramento iniciado: $DuracaoMinutos min, amostras a cada $IntervaloSegundos s. Use o notebook normalmente agora." 'INFO'

    while ((Get-Date) -lt $fim) {
        $amostraAtual++
        $agora = Get-Date
        $ts = $agora.ToString('yyyy-MM-dd HH:mm:ss')

        try {
            $procs = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
                Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' }

            $linhas = foreach ($p in $procs) {
                "$ts,$($p.Name),$($p.IDProcess),$($p.PercentProcessorTime),$($p.WorkingSetPrivate),$($p.IODataBytesPersec),$($p.HandleCount),$($p.ThreadCount)"
            }
            $linhas | Out-File -FilePath $CsvSaida -Encoding UTF8 -Append

            $top3 = $procs | Sort-Object PercentProcessorTime -Descending | Select-Object -First 3
            $resumoTop = ($top3 | ForEach-Object { "$($_.Name) ($($_.PercentProcessorTime)%)" }) -join ', '
        } catch {
            Write-DiagLog "Falha ao coletar amostra de processos: $($_.Exception.Message)" 'AVISO'
            $resumoTop = '(falha na amostra)'
        }

        try {
            $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($bat) {
                $noCarregador = $bat.BatteryStatus -in 2, 6, 7, 8, 9
                "$ts,$($bat.EstimatedChargeRemaining),$noCarregador" | Out-File -FilePath $CsvBateria -Encoding UTF8 -Append
            }
        } catch { }

        $percConcluido = [math]::Min(100, [math]::Round(($amostraAtual / $totalAmostras) * 100))
        $restante = $fim - (Get-Date)
        $restanteTxt = if ($restante.TotalSeconds -gt 0) { '{0:mm}min {0:ss}s restantes' -f $restante } else { 'finalizando' }
        Write-Progress -Activity 'Monitoramento de recursos em andamento' `
            -Status "Top processos agora: $resumoTop" `
            -PercentComplete $percConcluido `
            -SecondsRemaining ([math]::Max(0, [int]$restante.TotalSeconds))

        $tempoRestanteAteFim = ($fim - (Get-Date)).TotalSeconds
        $espera = [math]::Min($IntervaloSegundos, [math]::Max(0, $tempoRestanteAteFim))
        if ($espera -gt 0) { Start-Sleep -Seconds $espera }
    }

    Write-Progress -Activity 'Monitoramento de recursos em andamento' -Completed
    Write-DiagLog "Monitoramento concluído ($amostraAtual amostras)." 'OK'
}

function Get-DiagMonitoringSummary {
    <#
        Agrega o CSV de amostragem por processo: médias e picos de CPU/memória/IO,
        e calcula a correlação simples com quedas de bateria (drenos mais rápidos
        no período em que o processo estava ativo com alto consumo).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CsvProcessos,
        [Parameter(Mandatory)][string]$CsvBateria
    )

    if (-not (Test-Path $CsvProcessos)) {
        return [pscustomobject]@{ Processos = @(); DrenoPorHora = $null }
    }
    $dados = Import-Csv -Path $CsvProcessos

    $agrupado = $dados | Group-Object Processo | ForEach-Object {
        $cpuVals = $_.Group.CpuPercent | ForEach-Object { [double]$_ }
        $memVals = $_.Group.WorkingSetBytes | ForEach-Object { [double]$_ }
        $ioVals  = $_.Group.IOBytesPersec | ForEach-Object { [double]$_ }

        [pscustomobject]@{
            Processo       = $_.Name
            Amostras       = $_.Count
            CpuMedia       = [math]::Round(($cpuVals | Measure-Object -Average).Average, 1)
            CpuPico        = [math]::Round(($cpuVals | Measure-Object -Maximum).Maximum, 1)
            MemMediaBytes  = [math]::Round(($memVals | Measure-Object -Average).Average, 0)
            MemPicoBytes   = [math]::Round(($memVals | Measure-Object -Maximum).Maximum, 0)
            IOMediaBytesSeg = [math]::Round(($ioVals | Measure-Object -Average).Average, 0)
        }
    }

    # Taxa de dreno de bateria (percentual por hora) no período monitorado
    $drenoPorHora = $null
    if (Test-Path $CsvBateria) {
        $bat = Import-Csv -Path $CsvBateria | Where-Object { $_.NoCarregador -eq 'False' }
        if ($bat.Count -ge 2) {
            $primeiro = $bat | Select-Object -First 1
            $ultimo = $bat | Select-Object -Last 1
            $t1 = [DateTime]$primeiro.Timestamp
            $t2 = [DateTime]$ultimo.Timestamp
            $horas = ($t2 - $t1).TotalHours
            if ($horas -gt 0) {
                $quedaPercentual = [double]$primeiro.CargaPercentual - [double]$ultimo.CargaPercentual
                $drenoPorHora = [math]::Round($quedaPercentual / $horas, 1)
            }
        }
    }

    return [pscustomobject]@{
        Processos     = ($agrupado | Sort-Object CpuMedia -Descending)
        DrenoPorHora  = $drenoPorHora
    }
}

Export-ModuleMember -Function *
