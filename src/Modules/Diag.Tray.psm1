#Requires -Version 5.1

function Start-DiagTrayWatcher {
    <#
        Inicia, em uma runspace separada (thread STA dedicada), um ícone de
        bandeja que assume o lugar da janela de console quando ela é
        minimizada — a janela é escondida (ShowWindow SW_HIDE), o que a
        remove da barra de tarefas, e volta ao clicar duas vezes no ícone ou
        escolher "Restaurar janela".

        Roda em segundo plano sem bloquear a thread principal, que continua
        livre para executar a coleta de dados. Use Stop-DiagTrayWatcher para
        encerrar de forma limpa ao final.
    #>
    [CmdletBinding()]
    param(
        [string]$TituloBandeja = 'Monitor de Sistema - Diagnóstico em andamento'
    )

    # Hashtable sincronizada: é assim que a thread principal consegue pedir
    # para a thread da bandeja (STA) encerrar o próprio loop de mensagens de
    # forma limpa (Form.Invoke), em vez de tentar interromper à força uma
    # chamada nativa bloqueante (Application.Run).
    $sync = [hashtable]::Synchronized(@{ Form = $null; Pronto = $false })

    $scriptBlock = {
        param($TituloBandeja, $sync)

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DiagWindowNativeMethods {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@ -ErrorAction SilentlyContinue

        $SW_HIDE = 0
        $SW_RESTORE = 9

        $hwnd = [DiagWindowNativeMethods]::GetConsoleWindow()

        try {
            $caminhoExe = (Get-Process -Id $PID).MainModule.FileName
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($caminhoExe)
        } catch {
            $icon = [System.Drawing.SystemIcons]::Application
        }

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon = $icon
        $notifyIcon.Text = $TituloBandeja.Substring(0, [Math]::Min(63, $TituloBandeja.Length))
        $notifyIcon.Visible = $false

        $restaurarJanela = {
            [DiagWindowNativeMethods]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
            [DiagWindowNativeMethods]::SetForegroundWindow($hwnd) | Out-Null
            $notifyIcon.Visible = $false
        }.GetNewClosure()

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        [void]$menu.Items.Add('Restaurar janela', $null, $restaurarJanela)
        [void]$menu.Items.Add('-')
        [void]$menu.Items.Add('Encerrar diagnóstico', $null, { [Environment]::Exit(1) })
        $notifyIcon.ContextMenuStrip = $menu
        $notifyIcon.add_MouseDoubleClick({
            param($eventSender, $eventArgs)
            if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $restaurarJanela }
        }.GetNewClosure())

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 400
        $timer.add_Tick({
            if ($hwnd -ne [IntPtr]::Zero -and [DiagWindowNativeMethods]::IsIconic($hwnd) -and -not $notifyIcon.Visible) {
                [DiagWindowNativeMethods]::ShowWindow($hwnd, $SW_HIDE) | Out-Null
                $notifyIcon.Visible = $true
                $notifyIcon.ShowBalloonTip(3000, 'Monitor de Sistema', 'O diagnóstico continua rodando em segundo plano. Clique duas vezes no ícone para reabrir.', [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }.GetNewClosure())
        $timer.Start()

        # Form invisível só para ter uma alça (Invoke) que permite à thread
        # principal pedir o encerramento do loop de mensagens de forma segura.
        $hiddenForm = New-Object System.Windows.Forms.Form
        $hiddenForm.ShowInTaskbar = $false
        $hiddenForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        $hiddenForm.Opacity = 0
        $hiddenForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
        $hiddenForm.add_Load({ $hiddenForm.Hide() }.GetNewClosure())

        $sync.Form = $hiddenForm
        $sync.Pronto = $true

        [System.Windows.Forms.Application]::Run($hiddenForm)

        # Garante que a janela do console volte a aparecer ao encerrar — se o
        # script termina (sucesso ou erro) enquanto minimizado na bandeja, o
        # usuário precisa ver a mensagem final. Chamar SW_RESTORE numa janela
        # que já está visível é inofensivo.
        if ($hwnd -ne [IntPtr]::Zero) {
            [DiagWindowNativeMethods]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
            [DiagWindowNativeMethods]::SetForegroundWindow($hwnd) | Out-Null
        }

        $timer.Stop()
        $timer.Dispose()
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($scriptBlock).AddArgument($TituloBandeja).AddArgument($sync)
    $handle = $ps.BeginInvoke()

    return [pscustomobject]@{
        PowerShell = $ps
        Runspace   = $rs
        Handle     = $handle
        Sync       = $sync
    }
}

function Stop-DiagTrayWatcher {
    <#
        Encerra a runspace do ícone de bandeja de forma limpa e libera os
        recursos. Seguro de chamar mesmo se o watcher nunca tiver iniciado
        corretamente (ex.: sessão sem console real).
    #>
    [CmdletBinding()]
    param($Watcher)

    if (-not $Watcher) { return }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

        $tentativas = 0
        while (-not $Watcher.Sync.Pronto -and $tentativas -lt 20) {
            Start-Sleep -Milliseconds 100
            $tentativas++
        }

        $form = $Watcher.Sync.Form
        if ($form -and -not $form.IsDisposed) {
            $form.Invoke([System.Windows.Forms.MethodInvoker]{ [System.Windows.Forms.Application]::ExitThread() }) | Out-Null
        }
    } catch { }

    try {
        if ($Watcher.Handle) { $Watcher.PowerShell.EndInvoke($Watcher.Handle) | Out-Null }
    } catch { }
    try { $Watcher.PowerShell.Dispose() } catch { }
    try { $Watcher.Runspace.Close() } catch { }
}

Export-ModuleMember -Function *
