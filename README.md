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

Como o monitoramento roda por até 30–60 minutos, a janela pode ser minimizada
para a bandeja do sistema (perto do relógio) em vez de ocupar a barra de
tarefas — clique duas vezes no ícone para trazê-la de volta.

## Como usar

### Opção 1 — Executável (recomendado para o dia a dia)

Baixe `MonitorSistema.exe` (pasta `dist/` ou a [última release](../../releases))
e dê duplo clique. O programa pede elevação (UAC) automaticamente.

Os relatórios são salvos em:

```
Área de Trabalho\Relatório Monitor Sistema\
    Diagnostico_<PC>_<data_hora>\
        Relatorio.html
        Relatorio.pdf
        execucao.log
        powercfg_energy.html
        powercfg_batteryreport.html
        raw\   (CSVs com todos os dados brutos coletados)
    Diagnostico_<PC>_<data_hora>.zip   <- arquivo único para enviar à análise
```

Ao final, a ferramenta compacta automaticamente toda a pasta em um `.zip` ao
lado dela e abre o Explorer já selecionando o arquivo — é esse `.zip` que o
cliente/usuário deve enviar para quem for analisar.

### Quanto tempo de monitoramento é confiável?

| Duração | Uso recomendado |
|---|---|
| 30 min (padrão) | Suficiente para sinais de CPU/memória e itens de inicialização |
| **45–60 min, sem carregador** | Recomendado quando o sintoma é **dreno de bateria** — o Windows reporta a carga em passos de 1%, então janelas curtas produzem uma taxa de dreno pouco confiável |
| 2 coletas em momentos diferentes | Se o relatório ficar inconclusivo, repita em outro período de uso (ex.: uma sessão leve, outra mais pesada) |

Sempre rode com o notebook **desconectado do carregador** durante a janela de
monitoramento — a taxa de dreno só é calculada sobre as amostras sem energia
externa.

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
| `-SemCompactar` | — | Não gera o `.zip` final (útil em testes rápidos) |

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
