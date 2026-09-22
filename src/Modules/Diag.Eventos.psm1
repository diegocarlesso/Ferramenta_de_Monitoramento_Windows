#Requires -Version 5.1

function Get-DiagEventosEnergia {
    <#
        Busca eventos de Kernel-Power e Power-Troubleshooter recentes: desligamentos
        inesperados (ID 41), suspensões/retomadas e a causa de cada retomada (o que
        "acordou" o notebook — útil para identificar apps que impedem o sleep real).
    #>
    [CmdletBinding()]
    param(
        [int]$DiasRecente = 7,
        [int]$MaximoEventos = 100
    )

    $inicio = (Get-Date).AddDays(-$DiasRecente)
    $resultado = New-Object System.Collections.Generic.List[object]

    $filtros = @(
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; Descricao = 'Desligamento inesperado (perda de energia)' },
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 42; Descricao = 'Entrando em suspensão' },
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; Descricao = 'Retomada de suspensão' }
    )

    foreach ($f in $filtros) {
        try {
            $eventos = Get-WinEvent -FilterHashtable @{
                LogName      = $f.LogName
                ProviderName = $f.ProviderName
                Id           = $f.Id
                StartTime    = $inicio
            } -MaxEvents $MaximoEventos -ErrorAction SilentlyContinue

            foreach ($e in $eventos) {
                $resultado.Add([pscustomobject]@{
                    Data      = $e.TimeCreated
                    Tipo      = $f.Descricao
                    Id        = $e.Id
                    Mensagem  = ($e.Message -split "`n")[0]
                })
            }
        } catch { }
    }

    return ($resultado | Sort-Object Data -Descending)
}

function Get-DiagErrosAplicativosRecentes {
    <#
        Agrupa erros críticos/erro do log de Aplicativos por origem (nome do
        programa), nos últimos N dias — picos de erro após uma instalação recente
        são um forte indício de instabilidade causada por aquele software.
    #>
    [CmdletBinding()]
    param(
        [int]$DiasRecente = 14
    )

    $inicio = (Get-Date).AddDays(-$DiasRecente)

    try {
        $eventos = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            Level     = 1, 2
            StartTime = $inicio
        } -MaxEvents 2000 -ErrorAction SilentlyContinue
    } catch {
        return @()
    }

    if (-not $eventos) { return @() }

    $eventos | Group-Object ProviderName | ForEach-Object {
        [pscustomobject]@{
            Origem       = $_.Name
            Ocorrencias  = $_.Count
            UltimaVez    = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        }
    } | Sort-Object Ocorrencias -Descending
}

Export-ModuleMember -Function *
