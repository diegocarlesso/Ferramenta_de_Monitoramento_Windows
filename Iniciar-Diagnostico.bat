@echo off
setlocal

:: Atalho de desenvolvimento: roda o diagnostico direto do codigo-fonte (.ps1),
:: sem precisar compilar o .exe. Para uso no dia a dia, prefira dist\MonitorSistema.exe.
:: A propria ferramenta ja solicita elevacao de Administrador automaticamente.

set SCRIPT_DIR=%~dp0
powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%src\Invoke-DiagnosticoCompleto.ps1" -AbrirRelatorio

endlocal
