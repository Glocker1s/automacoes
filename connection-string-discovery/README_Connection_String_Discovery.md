# Connection String Discovery

Automação Ansible para **descoberta centralizada de possíveis configurações de conexão com bancos de dados em servidores Windows**, utilizando inventário dinâmico por ambiente, scanner PowerShell embutido no playbook, seleção opcional de hosts, filtro textual de conexão, proteção de conteúdo sensível e consolidação de resultados em **CSV** e relatório **HTML**. A publicação do CSV utiliza CIFS, e o envio do e-mail é realizado por um Job Template independente, integrado ao Workflow por `set_stats`.

> **Escopo:** descoberta de referências em arquivos. A automação **não** consulta bancos de dados, não valida credenciais e não identifica necessariamente todas as dependências de um schema ou aplicação.

---

## 1. Operação

| Operação | Descrição |
| --- | --- |
| Descoberta sem filtro | Examina os arquivos elegíveis dos Windows selecionados e retorna as linhas candidatas a configurações de conexão. |
| Descoberta com filtro | Examina os mesmos arquivos, mas retorna somente ocorrências relacionadas ao texto informado no Survey, incluindo referências próximas. |
| Descoberta por ambiente | Seleciona um ou mais ambientes (`prd`, `dr`, `hml`, `dev`) ou `all`. |
| Descoberta por host | Restringe a execução a hosts previamente cadastrados nos ambientes selecionados. |

```text
Sem filtro      = todas as linhas candidatas encontradas
Com filtro      = linhas candidatas relacionadas ao termo buscado
Um ambiente     = hosts cadastrados naquele ambiente
Múltiplos       = união dos hosts dos ambientes escolhidos
all             = prd + dr + hml + dev
```

A varredura é **somente leitura** nos servidores Windows. Não modifica arquivos de configuração nem executa comandos SQL.

---

## 2. Survey do AAP

| Campo | Variável | Tipo | Descrição |
| --- | --- | --- | --- |
| Ambientes | `survey_environment` | Multiple Choice (multiple select) | Seleção obrigatória de `prd`, `dr`, `hml`, `dev` ou `all`. |
| Servidores específicos | `survey_hosts` | Text Area | Opcional. Hostnames ou IPs exatos, separados por vírgula ou quebra de linha; vazio utiliza todos os hosts dos ambientes escolhidos. |
| Filtro de conexão | `survey_connection_filter` | Text | Opcional. Busca textual parcial, sem diferenciação de maiúsculas/minúsculas; vazio desativa o filtro. Máximo de 128 caracteres e uma única linha. |

Exemplo de execução:

```yaml
survey_environment:
  - prd
  - hml
survey_hosts: ""
survey_connection_filter: AGR_COTA
```

O filtro `AGR_COTA` também encontra referências a `AGR_COTA_TESTE` ou `agr_cota_dev`. O scanner procura texto **literal**: não interpreta o termo como expressão regular ou wildcard.

Quando `all` é selecionado com outros ambientes, prevalece a seleção de todos os quatro ambientes. A lista final de hosts é deduplicada. Se `survey_hosts` contiver um nome fora dos ambientes selecionados, a preparação falha antes da varredura.

O arquivo `survey_spec.json` descreve as perguntas do Survey, mas **não cria nem atualiza automaticamente** o Survey no AAP pela simples sincronização do Git. As perguntas devem ser configuradas no Workflow/Job Template ou aplicadas por outro mecanismo administrativo.

---

## 3. Escopo da descoberta

A configuração `csd_scan_scope` aceita dois modos:

| Valor | Comportamento |
| --- | --- |
| `all_local` | Identifica as unidades lógicas locais fixas do Windows (`DriveType=3`) e percorre os caminhos elegíveis. |
| `custom` | Percorre somente as raízes definidas em `csd_custom_roots`. |

Exemplo de uso controlado:

```yaml
csd_scan_scope: custom
csd_custom_roots:
  - 'D:\Apps'
  - 'E:\Sites'
```

O padrão do arquivo `vars/config.yml` é `all_local`. No LAB, `vars/lab_config.yml` substitui esse modo por `custom` e limita a pesquisa a `C:\CSD-LAB`.

O scanner ignora pontos de reanálise (*reparse points*), arquivos fora das extensões permitidas e diretórios excluídos. Ele não realiza descoberta em compartilhamentos de rede como unidades mapeadas.

---

## 4. Fluxo da automação

```text
controller / localhost
  ├── carrega vars/environments.yml e vars/config.yml
  ├── valida Survey e parâmetros
  ├── normaliza ambientes, hosts e filtro textual
  ├── resolve hosts permitidos
  └── cria grupo dinâmico csd_targets (add_host)

Windows / csd_targets
  ├── verifica WinRM (win_ping)
  ├── identifica discos locais ou raízes customizadas
  ├── percorre diretórios e arquivos elegíveis
  ├── analisa linhas e padrões de conexão
  ├── aplica filtro textual e contexto de até 5 linhas
  ├── protege o conteúdo sensível
  └── retorna métricas, ocorrências e status

report / localhost
  ├── consolida resultados de todos os hosts
  ├── gera CSV (Servidor;Arquivo;Linha;Conteudo)
  ├── publica CSV no CIFS via host Linux delegado
  ├── gera HTML no padrão do relatório F5
  ├── publica send_mail_* via set_stats
  └── remove relatórios temporários do EE

Workflow AAP
  └── Job Template de e-mail existente
      ├── recebe set_stats
      ├── recupera anexo do CIFS
      └── envia HTML com CSV anexado
```

O scanner utiliza `ansible.windows.win_powershell` com PowerShell **embutido em** `tasks/20_scan.yml`. Não é necessário manter ou distribuir um arquivo `.ps1` independente.

---

## 5. Inventário dinâmico por ambiente

Os servidores são mantidos em `vars/environments.yml`:

```yaml
csd_environments:
  prd:
    - APP-PRD-01
    - APP-PRD-02
  dr:
    - APP-DR-01
  hml:
    - APP-HML-01
  dev:
    - APP-DEV-01
```

A task `tasks/00_prepare.yml` resolve os ambientes, valida os hosts opcionais e utiliza `ansible.builtin.add_host` para formar `csd_targets`. O grupo existe apenas durante o Job; não exige cadastro individual dos servidores no inventário estático do AAP.

Para adicionar ou remover um servidor, altere o YAML no repositório Git e sincronize o projeto no AAP. Uma alteração na planilha de referência não atualiza automaticamente esse arquivo.

**Atenção:** cada host deve pertencer preferencialmente a um único ambiente. Caso apareça em mais de um, a execução remove duplicidades, mas a atribuição do ambiente segue a prioridade `prd` → `dr` → `hml` → `dev` no código atual.

---

## 6. Seleção de arquivos

### 6.1 Extensões permitidas

A variável `csd_extensions` contém extensões **exatas**, não padrões de nome de arquivo:

```yaml
csd_extensions:
  - .ora
  - .config
  - .tns
  - .asp
  - .aspx
  - .properties
  - .ini
  - .conf
  - .json
  - .yaml
  - .yml
  - .env
```

Usar `.json` é válido; incluir `*.json` ou `appsettings*.json` nessa lista não produz o comportamento de wildcard.

### 6.2 Diretórios excluídos

`csd_excluded_directory_names` compara o **nome exato** da pasta, ignorando maiúsculas/minúsculas. Entre as exclusões padrão estão `Windows`, `Program Files`, `ProgramData`, `backup`, `logs`, `Temp`, `.git` e `node_modules`.

Por exemplo, excluir `backup` impede a entrada em `C:\Apps\backup` e `D:\Sistemas\backup`. O valor `backup*` não funciona como pattern nessa variável.

### 6.3 Nomes de arquivos excluídos

`csd_excluded_filename_patterns` aceita curingas do PowerShell sobre o **nome do arquivo**, não sobre o caminho completo:

```yaml
csd_excluded_filename_patterns:
  - '*.log'
  - '*.bak'
  - '*test*'
  - '*sample*'
  - '*exemplo*'
```

Essas exclusões podem ocultar configurações legítimas. Devem ser revisadas com as equipes de aplicação e infraestrutura antes de expandir a descoberta em produção.

---

## 7. Detecção de connection strings

O scanner lê os arquivos de texto elegíveis linha por linha e aplica a expressão `$signalRegex` para identificar candidatos. Ela contempla padrões como:

```text
connectionString / ConnectionStrings
Data Source / Initial Catalog
server= / database= / host= / port=
user id= / uid= / password= / pwd=
SERVICE_NAME / SID / TNS_ADMIN / ORACLE_HOME
jdbc: / odbc: / oledb: / oracle: / postgresql: / mysql:
```

Uma **ocorrência** corresponde a uma linha candidata. Ela não equivale necessariamente a um banco, uma connection string completa ou uma conexão ativa.

`Get-ConnectionMeta` tenta identificar o tipo de banco (`ORACLE`, `POSTGRESQL`, `MYSQL`, `SQLSERVER`, `ODBC`, `OLEDB` ou `INDEFINIDO`) e extrair destino, database/service e porta quando os padrões permitem. Esses dados são indicativos, não uma validação de conectividade.

Comentários reconhecidos pelo scanner e algumas linhas estruturais genéricas são ignorados.

---

## 8. Filtro textual de conexão

O campo `survey_connection_filter` utiliza correspondência parcial e literal, sem diferenciar maiúsculas/minúsculas.

Exemplo de um arquivo `.properties`:

```properties
spring.datasource.url=jdbc:oracle:thin:@ORA-LAB-01:1521/FINLAB
spring.db.username=AGR_COTA_TESTE
```

Com `survey_connection_filter=AGR_COTA`, o scanner pode devolver a URL JDBC da linha anterior porque a referência foi encontrada na linha seguinte.

O contexto considera **até cinco linhas físicas próximas** do termo, inclusive quando o termo e o parâmetro de conexão não aparecem na mesma linha. A pesquisa é aplicada antes da proteção do conteúdo; o resultado exportado continua obedecendo às regras de mascaramento.

```text
Filtro vazio       -> todas as ocorrências candidatas
Filtro AGR_COTA    -> referências a AGR_COTA e substrings relacionadas
Filtro inexistente -> zero ocorrências, sem significar erro da execução
```

> **Limitação:** proximidade textual não comprova associação lógica. Em arquivos com diversas conexões próximas, o filtro pode associar uma referência a outra configuração. Ele também não consulta o catálogo do Oracle para determinar o schema real utilizado pela aplicação.

---

## 9. Proteção de conteúdo sensível

A função `Protect-Content` é executada **no Windows, antes de retornar o conteúdo ao AAP**.

- `$signalRegex` detecta candidatos de conexão.
- `$sensitiveRegex` identifica sinais de credenciais e informações sensíveis, como `password`, `pwd`, `passwd`, `token`, `secret`, `api_key`, `client_secret`, `credential`, `uid`, `User ID` e alguns padrões de URL autenticada.
- Quando a linha é considerada sensível, o texto original é substituído por `***CONTEUDO_SENSIVEL_OCULTADO***`; campos extraídos por allowlist, como destino, database e porta, podem ser preservados.
- As tasks de transporte e consolidação de dados potencialmente sensíveis utilizam `no_log: true`.

Exemplo fictício:

```text
Original:
Server=SQL-PRD-01;Database=ERP;User ID=app;Password=senha_ficticia

Resultado protegido:
Destino=SQL-PRD-01; Database=ERP; ***CONTEUDO_SENSIVEL_OCULTADO***
```

**Esse mascaramento protege a saída do Discovery; não altera senhas nem dados nos bancos.** É diferente do *data masking* executado após um restore pelo Oracle Manager.

> **Atenção:** o reconhecimento é baseado em padrões. Não há garantia de detecção de todo segredo, sobretudo quando a aplicação utiliza chaves personalizadas ou formatos desconhecidos. O CSV e o compartilhamento CIFS continuam exigindo controle de acesso.

---

## 10. Limites e desempenho

Valores definidos em `vars/config.yml`:

| Variável | Padrão | Comportamento |
| --- | --- | --- |
| `csd_max_file_mb` | `10` | Ignora arquivo cujo tamanho seja igual ou superior a 10 MB. |
| `csd_max_files_per_host` | `100000` | Limite de arquivos elegíveis tentados por host. |
| `csd_max_matches_per_host` | `5000` | Limite de ocorrências por host. |
| `csd_max_duration_seconds` | `3600` | Limite de duração verificado durante a varredura por host. |
| `csd_max_content_chars` | `900` | Limita a quantidade de caracteres de linhas não sensíveis retornadas. |
| `csd_parallel_hosts` | `8` | Número de hosts processados em cada lote (`serial`). |

Os limites de arquivos, ocorrências e duração são **por servidor**, não por Workflow. O limite de tempo é verificado durante a execução; não é garantia de interrupção instantânea de uma leitura já iniciada.

O indicador **Arquivos** no HTML soma os arquivos elegíveis que entraram na contagem de análise em cada host, inclusive quando uma tentativa de leitura posteriormente falha. Não inclui todos os arquivos existentes nos discos nem apenas os arquivos com ocorrência.

Quando ocorre limite de quantidade/tempo ou erro de leitura/enumeração, o scanner registra `PARCIAL`. O processamento pode provocar I/O relevante em servidores com grande volume de arquivos; recomenda-se iniciar por caminhos `custom` e ampliar gradualmente.

---

## 11. Conectividade Windows

O playbook utiliza conexão WinRM com as configurações padrão:

```yaml
csd_winrm_transport: ntlm
csd_winrm_port: 5985
csd_winrm_server_cert_validation: validate
csd_winrm_operation_timeout_sec: 120
csd_winrm_read_timeout_sec: 150
csd_parallel_hosts: 8
```

A porta `5985` utiliza HTTP no modelo configurado; a `5986` utiliza HTTPS. Usuário e senha devem ser obtidos das **Credentials do AAP**. O Execution Environment precisa incluir `ansible.windows` e dependências para WinRM.

O `win_ping` valida a conectividade antes do scanner. Um host que não responde é registrado como `UNREACHABLE` e não impede necessariamente a consolidação dos demais resultados.

---

## 12. Consolidação, status e relatório

O `tasks/40_consolidate.yml` reúne os resultados de `csd_targets` e calcula:

```text
servidores selecionados
servidores concluídos
servidores parciais
servidores com erro/inacessíveis
arquivos examinados
ocorrências candidatas
erros de leitura/enumeração
```

| Status | Significado |
| --- | --- |
| `OK` (host) | Scanner terminou sem erro detectado nem limite atingido. |
| `PARCIAL` (host) | Ocorreram erros de acesso/leitura/enumeração ou limite atingido. |
| `UNREACHABLE` (host) | Falha no precheck WinRM. |
| `ERROR` (host) | O scanner não concluiu corretamente. |
| `SUCESSO` (e-mail) | Descoberta concluída sem ressalvas registradas. |
| `SUCESSO COM AVISO` (e-mail) | Há hosts com ressalvas ou falhas de descoberta não fatais. |
| `FALHA CIFS` (e-mail) | Não foi possível publicar o CSV no compartilhamento. |

O relatório HTML apresenta cabeçalho grafite (Modelo A, padrão visual F5), ambiente(s), Job, data/hora em `America/Sao_Paulo`, filtro aplicado quando houver, indicadores por ambiente e por servidor, duração e avisos curtos.

O parâmetro `csd_fail_on_partial: false` preserva a conclusão do Job para que o Workflow siga para o e-mail, mesmo com hosts parciais/inacessíveis. Se for alterado para `true`, o Job poderá falhar após a publicação e o nó de e-mail deverá ter uma ligação de falha ou *always*, além da condição de sucesso.

---

## 13. CSV de resultados

O único anexo detalhado gerado é um arquivo `.csv`, compatível com o formato original da equipe:

```text
Servidor;Arquivo;Linha;Conteudo
```

- O arquivo é **consolidado**, reunindo as ocorrências de todos os hosts da execução.
- Utiliza ponto e vírgula como delimitador e campos entre aspas quando necessário.
- Preserva a linha e o caminho da ocorrência, com o conteúdo já protegido pelo scanner.
- O template adiciona uma proteção básica contra interpretação de fórmulas em planilhas para valores iniciados por caracteres específicos.
- O HTML não contém amostras das ocorrências; o detalhamento deve ser consultado no CSV.

O nome segue o padrão:

```text
Connection_String_Discovery_<timestamp_UTC>_<job_id>.csv
```

O timestamp do nome do arquivo permanece em UTC; a data apresentada no e-mail utiliza o fuso de São Paulo.

---

## 14. CIFS e envio de e-mail

A publicação segue o padrão das automações já existentes, incluindo PostgreSQL Manager:

```text
CSV gerado no Execution Environment
  ↓
CSV copiado para host Linux delegado
  ↓
arquivo temporário .cifs-pass (permissão 0600)
  ↓
teste de acesso ao CIFS via smbclient
  ↓
publicação do CSV
  ↓
remoção do arquivo de senha e staging (always)
  ↓
HTML + set_stats
  ↓
Job Template de e-mail existente
```

Principais variáveis em `vars/config.yml`:

| Variável | Descrição |
| --- | --- |
| `csd_publish_email_payload` | Habilita geração do payload para o Workflow e tentativa de publicação CIFS. |
| `csd_cifs_enabled` | Habilita o upload no compartilhamento. |
| `csd_cifs_label` | Alias de destino, como `producao` ou `tutihofix`. |
| `csd_cifs_address` | Mapeamento de aliases para endereços CIFS. |
| `csd_cifs_attachment_path` | Diretório remoto dos anexos. |
| `csd_cifs_workgroup` | Workgroup/domínio utilizado pelo `smbclient`. |
| `csd_controller_tmp_dir` | Área temporária para o estágio de publicação. |
| `csd_keep_reports_on_controller` | Define se os relatórios temporários no EE serão preservados. |
| `csd_aap_base_url` | Endereço base opcional do AAP, utilizado para referência ao Job. |

**Na versão v1.9 homologada no LAB**, `tasks/55_publish_cifs.yml` utiliza diretamente `delegate_to: "192.168.122.34"`. Esse endereço é **do laboratório** e deve ser substituído pelo host delegado autorizado no ambiente do cliente antes da implantação. Também devem ser conferidos os shares/aliases, permissões, autenticação e destino dos anexos.

O job principal **não** faz envio SMTP. `tasks/60_build_email_payload.yml` publica via `ansible.builtin.set_stats`:

```yaml
send_mail_subject: "..."
send_mail_body: "..."
send_mail_attachments:
  - "Connection_String_Discovery_...csv"
send_mail_cifs_remote_files:
  - "Connection_String_Discovery_...csv"
send_mail_cifs: "..."
send_mail_cifs_path: "..."
send_mail_cifs_address: {}
cifs_workgroup: "..."
```

O Job Template genérico de e-mail recebe essas variáveis pelo Workflow. Se a publicação CIFS falhar, o relatório sinaliza `FALHA CIFS` e a lista de anexos remotos permanece vazia, em vez de afirmar que o CSV foi anexado.

---

## 15. Estrutura principal

| Arquivo/Diretório | Descrição |
| --- | --- |
| `connection_discovery.yml` | Playbook corporativo; prepara inventário, executa scanner e consolida relatórios. |
| `vars/environments.yml` | Relação de hosts por `prd`, `dr`, `hml` e `dev`. |
| `vars/config.yml` | Extensões, exclusões, limites, WinRM, CIFS e relatório. |
| `survey_spec.json` | Especificação das três perguntas do Survey. |
| `requirements.yml` | Collection `ansible.windows`. |
| `tasks/00_prepare.yml` | Normalização do Survey, validações e `add_host`. |
| `tasks/20_scan.yml` | WinRM, scanner PowerShell, filtro textual, proteção e resultado por host. |
| `tasks/40_consolidate.yml` | Consolidação, métricas, timestamp e data no fuso de São Paulo. |
| `tasks/50_report.yml` | Geração do CSV/HTML, publicação e limpeza de temporários. |
| `tasks/55_publish_cifs.yml` | Publicação do CSV no CIFS pelo host Linux delegado. |
| `tasks/60_build_email_payload.yml` | Publica o contrato `send_mail_*` via `set_stats`. |
| `templates/connections.csv.j2` | CSV com quatro colunas originais. |
| `templates/report.html.j2` | Relatório HTML no visual escolhido (Modelo A/F5). |

Arquivos exclusivos dos testes, **não necessários no projeto corporativo**:

| Arquivo/Diretório | Uso |
| --- | --- |
| `connection_discovery_lab.yml` | Executa descoberta somente na área fictícia do laboratório. |
| `lab_prepare.yml` | Cria massa de arquivos de configuração fictícios. |
| `lab_cleanup.yml` | Remove a massa de teste mediante condições de segurança. |
| `vars/lab_environments.yml` | Hosts das quatro VMs de teste. |
| `vars/lab_config.yml` | Limites e caminho `C:\CSD-LAB` para testes. |
| `tasks/lab_validate.yml`, `tasks/lab_assert.yml` | Validadores exclusivos do LAB. |
| `tests/*.py` | Verificações estáticas do projeto e do filtro. |

---

## 16. Testes e homologação

A massa fictícia do LAB é criada em `C:\CSD-LAB`. Por Windows são gerados **12 arquivos**, dos quais **8 são elegíveis** para a varredura, com **9 ocorrências** na execução sem filtro.

Cenários homologados durante os testes:

| Cenário | Resultado esperado |
| --- | --- |
| HML sem filtro | 1 host, 8 arquivos, 9 ocorrências. |
| `all` sem filtro | 4 hosts, 32 arquivos, 36 ocorrências. |
| HML com `AGR_COTA` | 1 ocorrência relacionada a `AGR_COTA_TESTE` em configuração próxima. |
| `prd` + `hml` com `AGR_COTA` | 2 ocorrências na massa simulada. |
| HML com termo inexistente | Zero ocorrências. |
| Host inacessível | Status/aviso e consolidação dos demais. |
| Destino CIFS inválido | Falha CIFS sinalizada no relatório. |
| Multiselect | União dos ambientes selecionados, sem duplicação de hosts. |

Esses resultados comprovam os cenários simulados, **não** garantem identificação exaustiva em arquivos reais de aplicações. Antes da execução corporativa recomenda-se piloto controlado em HML, revisão das exclusões e dos limites, teste de precisão em formatos reais e validação das permissões do CIFS.

---

## 17. Configuração efetiva

```text
Survey / Extra Variables
  -> determina ambientes, hosts opcionais e filtro

vars/environments.yml
  -> determina quais hosts podem ser selecionados

vars/config.yml
  -> define varredura, limites, WinRM, CIFS e relatório

vars/lab_config.yml (somente LAB)
  -> substitui opções técnicas por valores restritos de teste

Credentials e Execution Environment do AAP
  -> fornecem autenticação e dependências de execução
```

Recomendação operacional: manter **somente os três campos funcionais no Survey**. Extensões, exclusões, limites, credenciais e destinos CIFS devem ser controlados tecnicamente e versionados/configurados conforme a política do cliente.

---

## 18. Execução no AAP

Configurar um Job Template apontando para `connection_discovery.yml`, com Project, inventário-base, Execution Environment e credenciais compatíveis. O campo **Limit** deve ficar vazio, pois os hosts são criados dinamicamente durante a execução.

Workflow recomendado:

```text
CSD - Connection String Discovery
  └── On Success
      └── Job Template de envio de e-mail existente
```

A execução é iniciada pelo Workflow, com o Survey configurado. A sincronização do repositório deve ocorrer antes de novos testes após alteração de ambientes ou configurações.

Para a versão LAB, a preparação de arquivos fictícios (`lab_prepare.yml`) é executada separadamente; depois utiliza-se `connection_discovery_lab.yml` no Workflow de descoberta e e-mail.

---

## 19. Execução via CLI

A execução por CLI exige inventário-base com `localhost`, conectividade WinRM aos Windows, collections instaladas e credenciais disponibilizadas por mecanismo seguro. Os exemplos abaixo ilustram somente os parâmetros de execução; não fornecem senhas.

### Um ambiente, sem filtro

```bash
ansible-playbook -i 'localhost,' connection_discovery.yml \
  -e '{"survey_environment":"hml","survey_hosts":"","survey_connection_filter":""}'
```

### Múltiplos ambientes com filtro

```bash
ansible-playbook -i 'localhost,' connection_discovery.yml \
  -e '{"survey_environment":["prd","hml"],"survey_hosts":"","survey_connection_filter":"AGR_COTA"}'
```

### Um host cadastrado com filtro

```bash
ansible-playbook -i 'localhost,' connection_discovery.yml \
  -e '{"survey_environment":"hml","survey_hosts":"APP-HML-01","survey_connection_filter":"FINANCEIRO"}'
```

### Todos os ambientes, sem filtro

```bash
ansible-playbook -i 'localhost,' connection_discovery.yml \
  -e '{"survey_environment":"all","survey_hosts":"","survey_connection_filter":""}'
```

Para executar apenas a descoberta sem publicar payload de e-mail, pode-se definir `csd_publish_email_payload: false` em um contexto de teste autorizado. O fluxo operacional homologado utiliza o Workflow do AAP com a publicação CIFS e o Job Template de e-mail.

---

## 20. Limitações e cuidados de produção

- A solução identifica **referências textuais candidatas** em arquivos; não inventaria automaticamente schemas existentes, conexões em memória, segredos externos ou endpoints que não estejam registrados nos caminhos elegíveis.
- Arquivos criptografados, fora do escopo, com extensões não permitidas ou dentro de diretórios excluídos podem não ser encontrados.
- A classificação do banco pode aparecer como `INDEFINIDO` quando a linha não contém indícios suficientes.
- O filtro textual utiliza contexto por proximidade; uma correspondência não confirma, por si só, dependência da aplicação com o schema pesquisado.
- O mascaramento é baseado em padrões e precisa ser validado para os formatos reais de configuração do cliente.
- `SUCESSO` indica que a **varredura configurada** terminou sem ressalvas detectadas; não garante cobertura integral de todo o servidor.
- O volume de I/O pode ser significativo no modo `all_local`. Avalie `custom`, limites e concorrência antes de expandir para PRD/DR.
- Antes da entrega corporativa, substitua os endereços e parâmetros específicos do LAB (principalmente o delegado CIFS), configure credenciais no AAP e revise o controle de acesso aos anexos.

