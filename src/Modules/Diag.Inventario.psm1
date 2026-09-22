#Requires -Version 5.1

function Get-DiagInstalledSoftware {
    <#
        Lê as chaves de desinstalação do Registro (64-bit, 32-bit e por usuário)
        e devolve o inventário de software com data de instalação, quando disponível.
    #>
    [CmdletBinding()]
    param()

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $items = foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
    }

    $items |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        ForEach-Object {
            $installDate = ConvertTo-DiagDateTime -Value $_.InstallDate
            [pscustomobject]@{
                Nome            = $_.DisplayName
                Versao          = $_.DisplayVersion
                Editora         = $_.Publisher
                DataInstalacao  = $installDate
                Local           = $_.InstallLocation
                DesinstalarCmd  = $_.UninstallString
                RegistroChave   = $_.PSPath
            }
        } |
        Sort-Object -Property @{Expression = 'DataInstalacao'; Descending = $true } -Unique |
        Sort-Object Nome, DataInstalacao -Unique |
        Sort-Object -Property DataInstalacao -Descending
}

function Get-DiagStartupItems {
    <#
        Levanta itens de inicialização: chaves Run/RunOnce (HKLM/HKCU, 32/64 bits)
        e atalhos nas pastas de Inicialização (usuário + todos os usuários).
        Usa a data de criação do executável alvo como proxy da "data de instalação".
    #>
    [CmdletBinding()]
    param()

    $resultado = New-Object System.Collections.Generic.List[object]

    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )

    foreach ($key in $runKeys) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -match '^PS(Path|ParentPath|ChildName|Provider)$') { continue }
            $exePath = ($prop.Value -replace '"', '') -split ' -' | Select-Object -First 1
            $exePath = if ($exePath) { $exePath.Trim() } else { '' }
            $criacao = $null
            if ($exePath -and (Test-Path -LiteralPath $exePath -ErrorAction SilentlyContinue)) {
                $criacao = (Get-Item -LiteralPath $exePath -ErrorAction SilentlyContinue).CreationTime
            }
            $resultado.Add([pscustomobject]@{
                Origem         = 'Registro'
                Chave          = $key
                Nome           = $prop.Name
                Comando        = $prop.Value
                ExecutavelData = $criacao
            })
        }
    }

    $startupFolders = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )

    foreach ($folder in $startupFolders) {
        if (-not (Test-Path $folder)) { continue }
        Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | ForEach-Object {
            $resultado.Add([pscustomobject]@{
                Origem         = 'Pasta de Inicialização'
                Chave          = $folder
                Nome           = $_.Name
                Comando        = $_.FullName
                ExecutavelData = $_.CreationTime
            })
        }
    }

    return $resultado
}

function Get-DiagScheduledTasksRecentes {
    <#
        Lista tarefas agendadas ativas cuja data de registro é recente ou cujo
        autor não é da Microsoft — candidatas a terem sido criadas por software
        instalado recentemente.
    #>
    [CmdletBinding()]
    param(
        [int]$DiasRecente = 30
    )

    $limite = (Get-Date).AddDays(-$DiasRecente)
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' }

    foreach ($t in $tasks) {
        $dataRegistro = $null
        try {
            $dataRegistro = [DateTime]$t.Date
        } catch { }

        $autor = $t.Author
        $ehMicrosoft = $autor -and ($autor -match 'Microsoft')
        $caminhoMicrosoft = $t.TaskPath -match '^\\Microsoft\\'

        $recente = $false
        if ($dataRegistro -and $dataRegistro -gt $limite) { $recente = $true }

        if ($recente -or (-not $ehMicrosoft -and -not $caminhoMicrosoft)) {
            $acao = ($t.Actions | Select-Object -First 1)
            $executavel = $null
            $argumentos = $null
            if ($acao -and ($acao.PSObject.Properties.Name -contains 'Execute')) { $executavel = $acao.Execute }
            if ($acao -and ($acao.PSObject.Properties.Name -contains 'Arguments')) { $argumentos = $acao.Arguments }
            [pscustomobject]@{
                Nome          = $t.TaskName
                Caminho       = $t.TaskPath
                Autor         = $autor
                DataRegistro  = $dataRegistro
                Executavel    = $executavel
                Argumentos    = $argumentos
                Recente       = $recente
                ForaDaMicrosoft = (-not $ehMicrosoft -and -not $caminhoMicrosoft)
            }
        }
    }
}

function Get-DiagServicosRecentes {
    <#
        Cruza serviços com início Automático com a data de criação do executável
        correspondente, sinalizando os instalados recentemente.
    #>
    [CmdletBinding()]
    param(
        [int]$DiasRecente = 30
    )

    $limite = (Get-Date).AddDays(-$DiasRecente)
    $servicos = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.StartMode -eq 'Auto' }

    foreach ($s in $servicos) {
        $caminho = $s.PathName
        if (-not $caminho) { continue }
        $exePath = ($caminho -replace '"', '') -split ' -| /' | Select-Object -First 1
        $exePath = if ($exePath) { $exePath.Trim() } else { '' }
        if (-not $exePath -or -not (Test-Path -LiteralPath $exePath -ErrorAction SilentlyContinue)) { continue }

        $info = Get-Item -LiteralPath $exePath -ErrorAction SilentlyContinue
        if (-not $info) { continue }

        if ($info.CreationTime -gt $limite) {
            [pscustomobject]@{
                Nome           = $s.Name
                NomeExibicao   = $s.DisplayName
                Executavel     = $exePath
                DataCriacaoExe = $info.CreationTime
                Estado         = $s.State
                IniciadoPor    = $s.StartName
            }
        }
    }
}

Export-ModuleMember -Function *
