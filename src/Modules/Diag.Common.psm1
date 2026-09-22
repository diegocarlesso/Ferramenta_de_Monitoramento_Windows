#Requires -Version 5.1

function Test-DiagIsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-DiagOutputFolder {
    param(
        [Parameter(Mandatory)][string]$BaseFolder
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $machine = $env:COMPUTERNAME
    $folder = Join-Path $BaseFolder "Diagnostico_${machine}_${timestamp}"
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $folder 'raw') -Force | Out-Null
    return $folder
}

$script:DiagLogPath = $null

function Initialize-DiagLog {
    param([Parameter(Mandatory)][string]$Path)
    $script:DiagLogPath = $Path
    "" | Out-File -FilePath $Path -Encoding UTF8
}

function Write-DiagLog {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'OK', 'AVISO', 'ERRO')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'HH:mm:ss'
    $prefix = switch ($Level) {
        'OK'    { '[OK]   ' }
        'AVISO' { '[AVISO]' }
        'ERRO'  { '[ERRO] ' }
        default { '[INFO] ' }
    }
    $line = "$ts $prefix $Message"

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'AVISO' { 'Yellow' }
        'ERRO'  { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color

    if ($script:DiagLogPath) {
        $line | Out-File -FilePath $script:DiagLogPath -Encoding UTF8 -Append
    }
}

function ConvertTo-DiagDateTime {
    <#
        Converte datas no formato de registro do Windows (yyyyMMdd) ou outros
        formatos comuns em DateTime. Retorna $null se não for possível converter.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $formats = @('yyyyMMdd', 'MM/dd/yyyy', 'dd/MM/yyyy', 'yyyy-MM-dd')
    foreach ($fmt in $formats) {
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($Value, $fmt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
    }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse($Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Format-DiagBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DiagFileSignatureInfo {
    <#
        Retorna se um executável é assinado digitalmente e por quem.
        Usado para reduzir falsos positivos (assinado pela Microsoft = menor suspeita).
    #>
    param([string]$Path)

    $result = [pscustomobject]@{
        Assinado  = $false
        Assinante = $null
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $result
    }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            $result.Assinado = $true
            $result.Assinante = $sig.SignerCertificate.Subject
        }
    } catch { }
    return $result
}

Export-ModuleMember -Function *
