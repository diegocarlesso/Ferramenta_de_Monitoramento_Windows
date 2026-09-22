#Requires -Version 5.1

function Get-DiagBatteryStatus {
    [CmdletBinding()]
    param()

    $bateria = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bateria) {
        return [pscustomobject]@{
            Presente             = $false
            CargaPercentual      = $null
            Status               = $null
            NoCarregador         = $null
        }
    }

    # BatteryStatus: 1 = descarregando, 2 = com AC (carregada), 6 = carregando
    $noCarregador = $bateria.BatteryStatus -in 2, 6, 7, 8, 9

    [pscustomobject]@{
        Presente        = $true
        CargaPercentual = $bateria.EstimatedChargeRemaining
        Status          = $bateria.BatteryStatus
        NoCarregador    = $noCarregador
    }
}

function Get-DiagPowerScheme {
    [CmdletBinding()]
    param()
    $saida = & powercfg /getactivescheme 2>$null
    return ($saida -join ' ').Trim()
}

function Invoke-DiagPowerRequests {
    <#
        Lista quais processos/drivers estão atualmente impedindo o sistema de
        entrar em suspensão ou desligar a tela — causa clássica de dreno de bateria.
    #>
    [CmdletBinding()]
    param()

    $saida = & powercfg /requests 2>$null
    $texto = $saida -join "`n"

    $categorias = @{}
    $categoriaAtual = $null
    foreach ($linha in $saida) {
        if ($linha -match '^([A-Z]+):') {
            $categoriaAtual = $Matches[1]
            $categorias[$categoriaAtual] = New-Object System.Collections.Generic.List[string]
            continue
        }
        if ($categoriaAtual -and $linha.Trim() -and $linha.Trim() -ne 'None.') {
            $categorias[$categoriaAtual].Add($linha.Trim())
        }
    }

    $itens = New-Object System.Collections.Generic.List[object]
    foreach ($cat in $categorias.Keys) {
        foreach ($linha in $categorias[$cat]) {
            $itens.Add([pscustomobject]@{ Categoria = $cat; Detalhe = $linha })
        }
    }
    return [pscustomobject]@{
        Itens      = $itens
        TextoBruto = $texto
    }
}

function Invoke-DiagEnergyReport {
    <#
        Executa 'powercfg /energy', um trace de ~60s que identifica ineficiências
        energéticas (temporizadores de alta resolução, USB sem suspensão, processos
        com uso elevado de CPU durante o trace, etc). Requer administrador.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputHtmlPath,
        [int]$DuracaoSegundos = 60
    )

    & powercfg /energy /output $OutputHtmlPath /duration $DuracaoSegundos *>$null

    $resultado = [pscustomobject]@{
        CaminhoRelatorio = $OutputHtmlPath
        Gerado           = (Test-Path $OutputHtmlPath)
        Erros            = 0
        Avisos           = 0
        TimersOfensores  = New-Object System.Collections.Generic.List[string]
    }

    if (-not $resultado.Gerado) { return $resultado }

    $html = Get-Content -LiteralPath $OutputHtmlPath -Raw -ErrorAction SilentlyContinue
    if (-not $html) { return $resultado }

    $erros = [regex]::Matches($html, 'class="errorheader"')
    $avisos = [regex]::Matches($html, 'class="warnheader"')
    $resultado.Erros = $erros.Count
    $resultado.Avisos = $avisos.Count

    # Processos que solicitaram resolução de timer elevada (consome bateria mesmo ocioso)
    $blocoTimers = [regex]::Match($html, '(?s)Platform Timer Resolution.*?(?=<h\d|\z)')
    if ($blocoTimers.Success) {
        $procs = [regex]::Matches($blocoTimers.Value, 'Requesting Process</th>\s*<td[^>]*>([^<]+)</td>')
        foreach ($m in $procs) {
            $nome = $m.Groups[1].Value.Trim()
            if ($nome -and $nome -notin $resultado.TimersOfensores) {
                $resultado.TimersOfensores.Add($nome)
            }
        }
    }

    return $resultado
}

function Invoke-DiagBatteryReport {
    <#
        Executa 'powercfg /batteryreport' e extrai a capacidade de projeto vs.
        capacidade atual (desgaste da bateria).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputHtmlPath
    )

    & powercfg /batteryreport /output $OutputHtmlPath /duration 14 *>$null

    $resultado = [pscustomobject]@{
        CaminhoRelatorio       = $OutputHtmlPath
        Gerado                 = (Test-Path $OutputHtmlPath)
        CapacidadeProjeto_mWh  = $null
        CapacidadeAtual_mWh    = $null
        DesgastePercentual     = $null
    }

    if (-not $resultado.Gerado) { return $resultado }

    $html = Get-Content -LiteralPath $OutputHtmlPath -Raw -ErrorAction SilentlyContinue
    if (-not $html) { return $resultado }

    $design = [regex]::Match($html, 'DESIGN CAPACITY</span>\s*</td>\s*<td[^>]*>\s*<span[^>]*>([\d.,]+)\s*mWh')
    $full = [regex]::Match($html, 'FULL CHARGE CAPACITY</span>\s*</td>\s*<td[^>]*>\s*<span[^>]*>([\d.,]+)\s*mWh')

    if ($design.Success -and $full.Success) {
        $cap1 = [double]($design.Groups[1].Value -replace '[.,]', '')
        $cap2 = [double]($full.Groups[1].Value -replace '[.,]', '')
        if ($cap1 -gt 0) {
            $resultado.CapacidadeProjeto_mWh = $cap1
            $resultado.CapacidadeAtual_mWh = $cap2
            $resultado.DesgastePercentual = [math]::Round((1 - ($cap2 / $cap1)) * 100, 1)
        }
    }

    return $resultado
}

Export-ModuleMember -Function *
