#!/usr/bin/env bash
# Provisiona o GitLab Runner do Trabalho Final, reaproveitando o codigo do
# Modulo 02 (terraform-gitlab-runner + playbook Ansible). O objetivo e tirar a
# friccao: o provisionamento do runner nao e o que se avalia no Trabalho Final,
# entao ele vem pronto — o aluno roda UM comando e passa a focar no codigo.
#
# PRE-REQUISITO (feito na Parte 0 do README, na UI do GitLab):
#   1. criar o projeto e o runner (tags shell,terraform) -> copiar o token glrt-
#   2. guardar o token no SSM:
#        aws ssm put-parameter --name /fiap/gitlab-runner/token \
#          --type SecureString --value "glrt-SEU-TOKEN" --region us-east-1 --overwrite
#
# Uso:  bash provisionamento/subir-runner.sh [nome-do-runner]
#
# Convencao de saida: stdout = resultado util; stderr = progresso.
set -euo pipefail
log() { printf '>> %s\n' "$*" >&2; }

REPO="/workspaces/FIAP-Platform-Engineering"
RUNNER_TF="$REPO/02-Ansible/01-provisionando-gitlab-runner/terraform-gitlab-runner"
ANSIBLE_DIR="$REPO/02-Ansible/01-provisionando-gitlab-runner/ansible-gitlab-runner"
RUNNER_NAME="${1:-gitlab-runner-trabalho-final}"
TOKEN_SSM_PATH="/fiap/gitlab-runner/token"
REGION="us-east-1"

log "1/6 Validando credenciais AWS..."
aws sts get-caller-identity >/dev/null || { echo "ERRO: credenciais AWS invalidas/expiradas." >&2; exit 1; }

log "2/6 Confirmando o token do runner no SSM ($TOKEN_SSM_PATH)..."
aws ssm get-parameter --name "$TOKEN_SSM_PATH" --with-decryption --region "$REGION" >/dev/null 2>&1 || {
  echo "ERRO: token nao encontrado em $TOKEN_SSM_PATH." >&2
  echo "Grave com: aws ssm put-parameter --name $TOKEN_SSM_PATH --type SecureString --value 'glrt-SEU-TOKEN' --region $REGION --overwrite" >&2
  exit 1
}

log "3/6 Descobrindo o bucket de state (base-config-*)..."
BUCKET="$(aws s3 ls | awk '{print $3}' | grep '^base-config' | head -1)"
[ -n "$BUCKET" ] || { echo "ERRO: nenhum bucket 'base-config-*' encontrado. Crie o do setup (Modulo 01)." >&2; exit 1; }
log "    bucket = $BUCKET"

log "4/6 Preparando o tooling do Ansible (venv, boto3, collections, session-manager-plugin)..."
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y python3 python3-venv python3-pip jq curl >/dev/null 2>&1
[ -d "$HOME/venv" ] || python3 -m venv "$HOME/venv"
# shellcheck disable=SC1091
source "$HOME/venv/bin/activate"
pip install --quiet ansible boto3 botocore
ansible-galaxy collection install --force community.aws amazon.aws >/dev/null
if ! command -v session-manager-plugin >/dev/null; then
  curl -sSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/smp.deb
  sudo dpkg -i /tmp/smp.deb >/dev/null
fi

log "5/6 Provisionando a EC2 do runner com Terraform..."
# Passamos o bucket por -backend-config em vez de editar o state.tf: assim NAO
# sujamos os arquivos versionados do Modulo 02 (o aluno pode roda-los de novo).
cd "$RUNNER_TF"
terraform init -input=false -reconfigure -backend-config="bucket=$BUCKET" >/dev/null
terraform apply -auto-approve -input=false >/dev/null
INSTANCE_ID="$(terraform output -raw instance_id)"
log "    EC2 = $INSTANCE_ID"

log "6/6 Configurando a EC2 como GitLab Runner (Ansible via SSM)..."
# Inventario gerado num arquivo temporario — nao tocamos no 'hosts' versionado.
HOSTS_FILE="$(mktemp)"
cat > "$HOSTS_FILE" <<EOF
[runner]
$INSTANCE_ID

[all:vars]
ansible_connection=community.aws.aws_ssm
ansible_aws_ssm_bucket_name=$BUCKET
ansible_aws_ssm_region=$REGION
ansible_become=true
EOF
cd "$ANSIBLE_DIR"
ansible-playbook -i "$HOSTS_FILE" --extra-vars "gitlab_runner_name=$RUNNER_NAME" play.yaml
rm -f "$HOSTS_FILE"

log "OK! Runner '$RUNNER_NAME' provisionado. Confira em Settings > CI/CD > Runners (online)."
# stdout = o dado util (id da instancia), para quem quiser capturar
echo "$INSTANCE_ID"
