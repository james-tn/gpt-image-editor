#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploy “GPT-Image interactive editor” to Azure Container Apps
# (Option-2: pull image with the Container App’s system-assigned identity)
# ---------------------------------------------------------------------------
#  USAGE
#     ./deploy.sh -g <resource-group>  [-l <location>] [-n <app-name>]
#                [-e <env-file>]       [-r <acr-name>]  [-t <tag>]
#                [-w <log-analytics-name>]
#
#  EXAMPLES
#     ./deploy.sh -g ai-playground -l westeurope
#     ./deploy.sh -g ai-playground -n gpt-image-demo -e .env.prod
#
#  The script:
#    1. Creates / reuses           :  Resource Group, ACR, ACA Environment
#    2. Builds + pushes container  :  <acr>/<image>:<tag>
#    3. Creates / updates          :  Container App (public HTTPS endpoint)
#       – Adds system-assigned identity
#       – Grants that identity AcrPull on the registry
#
#  Required env vars (taken from –e file or shell):
#    AZURE_OPENAI_ENDPOINT
#    AZURE_OPENAI_API_KEY
#    AZURE_OPENAI_IMAGE_DEPLOYMENT
#    AZURE_OPENAI_CHAT_DEPLOYMENT
#    AZURE_OPENAI_API_VERSION
# ---------------------------------------------------------------------------
set -eo pipefail

# ────────── defaults ────────────────────────────────────────────────────────
LOCATION="westeurope"
APP_NAME="gptimageeditor"
IMAGE_NAME="gpt-image-editor"
TAG="latest"
ENV_FILE=".env"
ACR_NAME=""
ACA_ENV_NAME="aca-${APP_NAME}"
LAW_NAME=""

# ────────── helper functions ───────────────────────────────────────────────
usage() { grep '^# ' "$0" | cut -c3-; exit 1; }

az_exists()      { az group show -n "$1"           &>/dev/null; }
acr_exists()     { az acr show   -n "$1"           &>/dev/null; }
aca_env_exists() {
  local env="$1"
  [[ -n "$env" ]] || return 1
  [[ "$(az containerapp env show \
           --name "$env" \
           --resource-group "$RG" \
           --query name -o tsv 2>/dev/null)" == "$env" ]]
}
aca_exists() {  
  local name="$1"  
  az containerapp show --name "$name" --resource-group "$RG" --query name -o tsv &>/dev/null  
}  
log() { echo -e "\033[1;34m==> $*\033[0m"; }

# ────────── CLI arguments ──────────────────────────────────────────────────
while getopts "g:l:n:e:r:t:w:h" opt; do
  case "$opt" in
    g) RG="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    n) APP_NAME="$OPTARG" ; ACA_ENV_NAME="aca-${APP_NAME}" ;;
    e) ENV_FILE="$OPTARG" ;;
    r) ACR_NAME="$OPTARG" ;;
    t) TAG="$OPTARG" ;;
    w) LAW_NAME="$OPTARG" ;;
    *) usage ;;
  esac
done
[[ -z "$RG" ]] && { echo "✖ Resource group (-g) required"; usage; }

# ────────── load .env file (optional) ──────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
  log "Loading env vars from $ENV_FILE"
  set -o allexport; source "$ENV_FILE"; set +o allexport
fi

required_vars=(
  AZURE_OPENAI_ENDPOINT AZURE_OPENAI_API_KEY
  AZURE_OPENAI_IMAGE_DEPLOYMENT AZURE_OPENAI_CHAT_DEPLOYMENT
  AZURE_OPENAI_API_VERSION
)
for v in "${required_vars[@]}"; do
  [[ -z "${!v}" ]] && { echo "✖ $v is missing (export it or place it in $ENV_FILE)"; exit 1; }
done

# ────────── login check ────────────────────────────────────────────────────
az account show -o none 2>/dev/null || { echo "✖ Run 'az login' first"; exit 1; }

# ────────── resource group ────────────────────────────────────────────────
if az_exists "$RG"; then
  log "Using existing resource group $RG"
else
  log "Creating resource group $RG"
  az group create -n "$RG" -l "$LOCATION" -o none
fi

# ────────── Log Analytics workspace (optional) ────────────────────────────
get_law_vals () {
  LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME"       --query id           -o tsv)
  LAW_CUST_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME"  --query customerId   -o tsv)
  LAW_KEY=$(az monitor log-analytics workspace get-shared-keys -g "$RG" -n "$LAW_NAME" --query primarySharedKey -o tsv)
}
if [[ -n "$LAW_NAME" ]]; then
  if az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME" &>/dev/null; then
    log "Using existing Log Analytics workspace $LAW_NAME"
  else
    log "Creating Log Analytics workspace $LAW_NAME"
    az monitor log-analytics workspace create -g "$RG" -n "$LAW_NAME" -l "$LOCATION" -o none
  fi
  get_law_vals
fi

# ────────── ACR ────────────────────────────────────────────────────────────
if [[ -z "$ACR_NAME" ]]; then
  ACR_NAME="${APP_NAME//-/}acr$RANDOM"           # must be globally unique
fi
if acr_exists "$ACR_NAME"; then
  log "Using existing ACR $ACR_NAME"
else
  log "Creating ACR $ACR_NAME"
  # Admin user OFF  → we rely on managed identity instead
  az acr create -n "$ACR_NAME" -g "$RG" --sku Basic -o none
fi
LOGIN_SERVER=$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)

# ────────── build & push image ─────────────────────────────────────────────
FULL_IMAGE="$LOGIN_SERVER/$IMAGE_NAME:$TAG"
log "Building container image $FULL_IMAGE"
az acr build -r "$ACR_NAME" -t "$FULL_IMAGE" .        # ACR Cloud Build

# ────────── ACA environment ────────────────────────────────────────────────
if aca_env_exists "$ACA_ENV_NAME"; then
  log "Using existing ACA environment $ACA_ENV_NAME"
else
  log "Creating ACA environment $ACA_ENV_NAME"
  if [[ -n "$LAW_NAME" ]]; then
    az containerapp env create \
      -n "$ACA_ENV_NAME" -g "$RG" -l "$LOCATION" \
      --logs-workspace-id "$LAW_CUST_ID" \
      --logs-workspace-key "$LAW_KEY" -o none
  else
    az containerapp env create \
      -n "$ACA_ENV_NAME" -g "$RG" -l "$LOCATION" -o none
  fi
fi

# ────────── secrets & env-vars ─────────────────────────────────────────────
SECRET_NAME="azureopenaikey"
SECRET_VALUE="$AZURE_OPENAI_API_KEY"

ENV_VARS=(
  AZURE_OPENAI_ENDPOINT=$AZURE_OPENAI_ENDPOINT
  AZURE_OPENAI_IMAGE_DEPLOYMENT=$AZURE_OPENAI_IMAGE_DEPLOYMENT
  AZURE_OPENAI_CHAT_DEPLOYMENT=$AZURE_OPENAI_CHAT_DEPLOYMENT
  AZURE_OPENAI_API_VERSION=$AZURE_OPENAI_API_VERSION
  AZURE_OPENAI_API_KEY=secretref:$SECRET_NAME
)

# Turn the array into a single space-separated string
ENV_VARS_STRING="${ENV_VARS[*]}"
# ────────── create / update Container App ─────────────────────────────────
ACR_ID=$(az acr show -n "$ACR_NAME" --query id -o tsv)

# 2. update or create the Container App
# -----------------------------------------------------------------------------
if aca_exists "$APP_NAME"; then
  log "Updating existing Container App $APP_NAME"

  az containerapp identity assign -n "$APP_NAME" -g "$RG" --system-assigned -o none
  PRINCIPAL_ID=$(az containerapp show -n "$APP_NAME" -g "$RG" --query identity.principalId -o tsv)
  az role assignment create --assignee "$PRINCIPAL_ID" --role acrpull --scope "$ACR_ID" 2>/dev/null || true

  az containerapp secret set -n "$APP_NAME" -g "$RG" --secrets $SECRET_NAME="$SECRET_VALUE" -o none

  az containerapp update \
      -n "$APP_NAME" -g "$RG" \
      --image "$FULL_IMAGE" \
      --set-env-vars "$ENV_VARS_STRING" \
else
  log "Creating Container App $APP_NAME"

  az containerapp create \
      -n "$APP_NAME" -g "$RG" \
      --environment "$ACA_ENV_NAME" \
      --system-assigned \
      --image "$FULL_IMAGE" \
      --secrets $SECRET_NAME="$SECRET_VALUE" \
      --env-vars "$ENV_VARS_STRING" \
      --ingress external --target-port 8501 \
      --registry-server "$LOGIN_SERVER" \
      --registry-identity system -o none

  PRINCIPAL_ID=$(az containerapp show -n "$APP_NAME" -g "$RG" --query identity.principalId -o tsv)
  az role assignment create --assignee "$PRINCIPAL_ID" --role acrpull --scope "$ACR_ID" -o none
fi


# ────────── output URL ─────────────────────────────────────────────────────
URL=$(az containerapp show -n "$APP_NAME" -g "$RG" \
        --query properties.configuration.ingress.fqdn -o tsv)
echo -e "\n✅ Deployed!  Open your app at: https://$URL\n"