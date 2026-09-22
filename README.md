# Monitor de Sistema — Diagnóstico de Desempenho e Bateria

Ferramenta de diagnóstico para Windows 11 que coleta e correlaciona dados nativos
do sistema para apontar **quais aplicativos são os prováveis responsáveis** por
lentidão e dreno de bateria — especialmente útil quando se suspeita de um
programa instalado recentemente.

Feita para analistas de TI que precisam **documentar** a causa do problema antes
de agir, não apenas "sentir" que algo mudou.

## O que ela faz

1. **Inventário** — softwares instalados (com data), itens de inicialização,
   tarefas agendadas e serviços automáticos recém-criados.
2. **Energia** — saúde e desgaste da bateria, processos que impedem o sistema de
   suspender (`powercfg /requests`), ineficiências energéticas (`powercfg
   /energy`), histórico de uso (`powercfg /batteryreport`).
3. **Monitoramento contínuo** — amostra CPU, memória e I/O por processo, e o
   percentual de bateria, em intervalos regulares durante uma janela configurável
   (padrão 30 min) enquanto você usa o notebook normalmente.
4. **Eventos do Windows** — desligamentos inesperados, suspensão/retomada, erros
   de aplicativos recorrentes.
5. **Correlação** — cruza todos os sinais acima e gera uma lista de suspeitos
   ordenada por pontuação, com a evidência de cada um.
6. **Relatório** — HTML e PDF, prontos para anexar a um chamado ou enviar ao
   usuário da máquina.

**A ferramenta é somente leitura**: não desinstala, não altera configurações e
não finaliza processos. A decisão de remover algo é sempre do analista.

## Como usar

### Opção 1 — Executável (recomendado para o dia a dia)

Baixe `MonitorSistema.exe` (pasta `dist/` ou a [última release](../../releases))
e dê duplo clique. O programa pede elevação (UAC) automaticamente.

Os relatórios são salvos em:

```
Área de Trabalho\Relatório Monitor Sistema\Diagnostico_<PC>_<data_hora>\
    Relatorio.html
    Relatorio.pdf
    execucao.log
    powercfg_energy.html
    powercfg_batteryreport.html
    raw\   (CSVs com todos os dados brutos coletados)
```

Por padrão, o monitoramento contínuo dura 30 minutos — use o notebook
normalmente durante esse período para que a coleta capture o comportamento real.

### Opção 2 — Script PowerShell (para desenvolvimento/ajustes)

```powershell
.\src\Invoke-DiagnosticoCompleto.ps1 -DuracaoMonitoramentoMinutos 30 -AbrirRelatorio
```

Parâmetros úteis:

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `-DuracaoMonitoramentoMinutos` | 30 | Duração da janela de monitoramento contínuo |
| `-IntervaloAmostragemSegundos` | 15 | Intervalo entre amostras |
| `-DiasSoftwareRecente` | 30 | Janela para considerar um software "recém-instalado" |
| `-PularEnergyReport` | — | Pula o trace de 60s do `powercfg /energy` |
| `-PastaBase` | `Área de Trabalho\Relatório Monitor Sistema` | Onde salvar os relatórios |
| `-AbrirRelatorio` | — | Abre o relatório ao final |

Execução rápida para validar a ferramenta (sem esperar 30 minutos):

```powershell
.\src\Invoke-DiagnosticoCompleto.ps1 -DuracaoMonitoramentoMinutos 1 -IntervaloAmostragemSegundos 5 -PularEnergyReport
```

## Requisitos

- Windows 11 (ou Windows 10) com PowerShell 5.1+
- Privilégios de Administrador (necessário para `powercfg /energy` e `powercfg
  /requests`, e para leitura completa de serviços)
- Microsoft Edge instalado (já vem por padrão no Windows 11) — usado para gerar
  o PDF a partir do HTML, em modo headless, sem depender de bibliotecas externas

## Como interpretar o relatório

A seção **Resumo Executivo** traz os KPIs principais (bateria, dreno, desgaste)
e a contagem de suspeitos. A seção **Principais Suspeitos** lista, em ordem de
pontuação, os aplicativos com mais evidências combinadas — instalação recente +
item de inicialização + consumo real de CPU/memória durante o monitoramento +
sinais de energia do Windows. A lista completa (incluindo itens de pontuação
baixa) fica em `raw/suspeitos_completo.csv`.

## Estrutura do projeto

```
src/
  Invoke-DiagnosticoCompleto.ps1   Orquestrador principal
  Modules/
    Diag.Common.psm1        Log, elevação, utilitários
    Diag.Inventario.psm1    Software, inicialização, tarefas, serviços
    Diag.Energia.psm1       Bateria, powercfg
    Diag.Monitor.psm1       Amostragem contínua de recursos
    Diag.Eventos.psm1       Log de Eventos do Windows
    Diag.Relatorio.psm1     Pontuação de suspeitos + geração HTML/PDF
  assets/
    icon.png / icon.ico     Ícone do executável
build/
  Build-Exe.ps1              Compila o .exe standalone (ps2exe)
dist/
  MonitorSistema.exe          Executável gerado (não versionado — ver Releases)
```

## Compilando o executável a partir do código-fonte

```powershell
.\build\Build-Exe.ps1
```

O script funde todos os módulos em um único arquivo (para o `.exe` não depender
de arquivos externos), instala o módulo `ps2exe` se necessário, converte o
ícone e compila `dist\MonitorSistema.exe` com manifesto de elevação automática.
