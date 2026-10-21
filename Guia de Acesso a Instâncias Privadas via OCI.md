# Guia de Acesso a Instâncias Privadas via OCI Bastion Service

Este documento reúne os conceitos de arquitetura, o fluxo de pares de chaves SSH com infraestrutura provisionada via Terraform, o passo a passo de conexão via OCI CLI e o guia detalhado de resolução de problemas (troubleshooting) baseado em erros reais de configuração.

---

## 1. Visão Geral da Arquitetura

O **OCI Bastion Service** é uma solução *serverless* e gerenciada da Oracle Cloud Infrastructure. Diferente do Bastion tradicional (uma VM mantida 24/7 com IP público), ele oferece:

* **Ponto de presença sem IP público dedicado:** O serviço cria uma interface interna diretamente conectada à sua VCN.
* **Sessões efêmeras sob demanda:** O acesso só existe mediante abertura explícita de uma sessão com tempo de vida limitado (TTL de 30 a 180 minutos).
* **Isolamento de credenciais:**
  * O **Terraform** distribui apenas a **chave pública** nas instâncias durante a criação (metadados do SO).
  * A **chave privada** nunca vai para a nuvem; ela fica armazenada com segurança na máquina local do administrador.
  * O tráfego trafega encapsulado por um túnel criptografado de ponta a ponta.

---

## 2. Parâmetros e Variáveis de Ambiente

Antes de iniciar, identifique as seguintes variáveis da sua infraestrutura:

| Variável | Descrição | Exemplo |
| :--- | :--- | :--- |
| `<OCID_DO_BASTION>` | OCID do recurso Bastion provisionado na OCI | `ocid1.bastion.oc1.sa-saopaulo-1...` |
| `<IP_PRIVADO_DA_VM>` | Endereço IP interno da instância privada | `10.0.2.108` |
| `<REGIAO>` | Identificador da região OCI | `sa-saopaulo-1` |
| `<PORTA_LOCAL>` | Porta livre no seu computador para abrir o túnel | `2222` |
| `<CHAVE_SSH>` | Caminho da sua chave privada e pública local | `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub` |

---

## 3. Passo a Passo de Conexão (Port Forwarding)

### Passo 1: Criar a Sessão no Bastion
Crie a sessão temporária de encaminhamento de portas usando a OCI CLI:

```bash
oci bastion session create-port-forwarding \
  --bastion-id <OCID_DO_BASTION> \
  --display-name "session-ssh" \
  --key-type PUB \
  --ssh-public-key-file ~/.ssh/id_rsa.pub \
  --target-private-ip <IP_PRIVADO_DA_VM> \
  --target-port 22 \
  --session-ttl 3600
```

> **Atenção:** Copie o valor do campo `"id"` da resposta JSON. Ele começa com `ocid1.bastionsession...` e representa o `<OCID_DA_SESSAO>`.

---

### Passo 2: Validar se a Sessão está Ativa
A OCI leva alguns instantes para provisionar o túnel. Verifique o status da sessão:

```bash
oci bastion session get \
  --session-id <OCID_DA_SESSAO> \
  --query "data.\"lifecycle-state\"" \
  --raw-output
```

Aguarde até que o retorno mude de `"CREATING"` para `"ACTIVE"`.

---

### Passo 3: Abrir o Túnel SSH Local
Em um terminal dedicado, inicie o túnel vinculando a porta local (`2222`) à porta `22` da máquina remota através do endpoint do Bastion:

```bash
ssh -i ~/.ssh/id_rsa \
  -N -L 2222:<IP_PRIVADO_DA_VM>:22 -p 22 \
  <OCID_DA_SESSAO>@host.bastion.<REGIAO>.oci.oraclecloud.com
```

*Exemplo real para a região São Paulo:*
```bash
ssh -i ~/.ssh/id_rsa \
  -N -L 2222:10.0.2.108:22 -p 22 \
  ocid1.bastionsession.oc1.sa-saopaulo-1.amaaaaaazdw3ghaasq673gqajcmigupogfon3mbitiwynyjf6elsfcfeomvq@host.bastion.sa-saopaulo-1.oci.oraclecloud.com
```

> **Nota:** Esse comando permanece executando sem exibir saídas extras. **Mantenha esse terminal aberto** enquanto precisar do acesso.

---

### Passo 4: Conectar à Máquina Privada via Localhost
Abra uma **segunda aba ou janela de terminal** e efetue o login SSH apontando para `127.0.0.1` na porta `2222`:

```bash
ssh -i ~/.ssh/id_rsa -p 2222 <USUARIO>@127.0.0.1
```

---

## 4. Guia de Troubleshooting

### Problema 1: Erro de `displayName` Inválido (`InvalidParameter`)

* **Mensagem de Erro:**
  ```text
  ServiceError:
  {
      "code": "InvalidParameter",
      "message": "You provided an invalid resource name (displayName). Allowable characters include alphanumeric characters and some special characters. Special characters must be ., -, _, +, or @. The resource name also must not exceed 255 characters."
  }
  ```
* **Causa:** O parâmetro `--display-name` continha espaços em branco, caracteres acentuados (como `ã`, `é`) ou símbolos especiais não autorizados.
* **Solução:** Utilize apenas caracteres alfanuméricos simples, traços (`-`) ou underlines (`_`):
  * **Incorreto:** `--display-name "sessão privada"`
  * **Correto:** `--display-name "session-ssh"` ou `--display-name "acesso_vm_app"`

---

### Problema 2: Falha de Resolução de Nome de Host (`Name or service not known`)

* **Mensagem de Erro:**
  ```text
  ssh: Could not resolve hostname ocid1.bastionsession...: Name or service not known
  Connection closed by UNKNOWN port 65535
  ```
* **Causa:** 
  1. Tentativa de usar a flag `-o ProxyCommand` (exclusiva de *Managed SSH Sessions*) em uma sessão criada como `PORT_FORWARDING`.
  2. O cliente SSH interpretou o OCID isolado como sendo o endereço de internet.
* **Solução:** Em sessões de Port Forwarding, não use o ProxyCommand direto. Use o formato com túnel local (`-N -L`) apontando para o hostname regional completo:
  ```text
  <OCID_DA_SESSAO>@host.bastion.<REGIAO>.oci.oraclecloud.com
  ```

---

### Problema 3: Alerta de Violação de Host Key (`REMOTE HOST IDENTIFICATION HAS CHANGED`)

* **Mensagem de Erro:**
  ```text
  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
  @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
  Host key for [127.0.0.1]:2222 has changed and you have requested strict checking.
  Host key verification failed.
  ```
* **Causa:** A porta local `2222` já foi associada anteriormente a outro servidor ou máquina virtual. O arquivo `known_hosts` local detectou que a assinatura digital enviada pela máquina atual é diferente da gravada previamente.
* **Solução:** Remova o registro da porta conflitante com o utilitário `ssh-keygen`:
  ```bash
  ssh-keygen -f ~/.ssh/known_hosts -R '[127.0.0.1]:2222'
  ```
  *Dica para túneis temporários (ignora a gravação no known_hosts):*
  ```bash
  ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 <USUARIO>@127.0.0.1
  ```

---

### Problema 4: Rejeição do Usuário do Sistema Operacional

* **Mensagem de Erro:**
  ```text
  Please login as the user "ubuntu" rather than the user "opc".
  Connection to 127.0.0.1 closed.
  ```
* **Causa:** Tentativa de conectar com o usuário `opc` (padrão de distribuições Oracle Linux) em uma imagem Ubuntu.
* **Solução:** Conecte com o usuário padrão da imagem provisionada:
  * **Ubuntu:** `ubuntu`
  * **Oracle Linux:** `opc`
  * **CentOS / RHEL:** `opc` ou `centos`
  * **Debian:** `debian`

  ```bash
  ssh -i ~/.ssh/id_rsa -p 2222 ubuntu@127.0.0.1
  ```

---

## 5. Dica Bônus: Automatização com Script Bash

Para evitar rodar múltiplos comandos manualmente, salve o seguinte script como `conectar_oci.sh`:

```bash
#!/bin/bash
set -e

BASTION_ID="<OCID_DO_BASTION>"
TARGET_IP="10.0.2.108"
REGION="sa-saopaulo-1"
KEY_PUB="$HOME/.ssh/id_rsa.pub"
KEY_PRIV="$HOME/.ssh/id_rsa"
LOCAL_PORT=2222
SSH_USER="ubuntu"

echo "==> 1. Criando sessão efêmera no OCI Bastion..."
SESSION_ID=$(oci bastion session create-port-forwarding \
  --bastion-id "$BASTION_ID" \
  --display-name "auto-session" \
  --key-type PUB \
  --ssh-public-key-file "$KEY_PUB" \
  --target-private-ip "$TARGET_IP" \
  --target-port 22 \
  --session-ttl 3600 \
  --query "data.id" \
  --raw-output)

echo "Sessão criada: $SESSION_ID"

echo "==> 2. Aguardando status ACTIVE..."
oci bastion session get --session-id "$SESSION_ID" --wait-for-state ACTIVE > /dev/null

echo "==> 3. Limpando fingerprint local da porta $LOCAL_PORT..."
ssh-keygen -f ~/.ssh/known_hosts -R "[127.0.0.1]:$LOCAL_PORT" 2>/dev/null || true

echo "==> 4. Abrindo túnel SSH em segundo plano..."
ssh -i "$KEY_PRIV" -f -N -L ${LOCAL_PORT}:${TARGET_IP}:22 -p 22 \
  ${SESSION_ID}@host.bastion.${REGION}.oci.oraclecloud.com

echo "==> 5. Conectando na VM ($SSH_USER@127.0.0.1)..."
ssh -i "$KEY_PRIV" -o StrictHostKeyChecking=no -p $LOCAL_PORT ${SSH_USER}@127.0.0.1
```