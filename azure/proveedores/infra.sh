#!/usr/bin/env bash
set -euo pipefail

sql_admin_pw() {
  local base
  base="$(openssl rand -base64 24 | tr -d '=+/ \n' | cut -c1-20)"
  echo "${base}Aa1!"
}
# =================== PLANs ===================

ASP_PLAN="B1"               # App Service Plan: B1 (Linux)
SQL_SERVICE_OBJECTIVE="S0"  # SQL DB: S0
SWA_SKU="Free"              # Static Web App: Free (F1)
STORAGE_SKU="Standard_LRS"  # Storage Account: Standard_LRS

# =================== GLOBAL PARAMS ===================
LOCATION="eastus2"
SUFFIX="acacoop"
AAD_ADMIN_NAME="proveedores-sql-admin"
AAD_ADMIN_OBJECT_ID="eff4527e-ddcf-4b6f-8e54-39533cb1174d"

GH_ORG="acacoop"
GH_REPO_BACKEND="proveedores-back"
GH_REPO_FRONTEND="proveedores-front"

GH_BRANCH_DEV="dev"
GH_BRANCH_TEST="test"
GH_BRANCH_PROD="main"

NODE_MAJOR_VERSION="24"
SQL_ADMIN_PASSWORD="$(sql_admin_pw)"

# =================== MAIN ===================
create_env () {
  ENV="$1"
  BRANCH="$2"

  echo "=== Creating environment: $ENV ==="

  # ---------- RESOURCE NAMES ----------
  RG="RSG_PortalProveedores"
  RG_NETWORKING="RSG_Networking_Dev"0

  ASP_API="asp-proveedores-api-${ENV}"
  APP_API="app-proveedores-api-${ENV}"

  SQL_SERVER="sqlsv-proveedores-${ENV}-${SUFFIX}"
  SQL_DB="sqldb-proveedores-${ENV}"

  VNET="acavnet-azure-${ENV}"
  SNET_APP="AppServices-In"
  SNET_PE_SQL="Private-Endpoints"
  
  PE_SQL="pe-sql-proveedores-${ENV}"
  PDZ_SQL="pdz-sql-${ENV}"

  KV="kv-proveedores-${ENV}"

  ST_ACCOUNT="stproveedores${ENV}${SUFFIX}"
  ST_CONTAINER="uploads"

  SWA="swa-proveedores-${ENV}"
  SWA_REPO="https://github.com/${GH_ORG}/${GH_REPO_FRONTEND}"
  LAW="law-proveedores-${ENV}"

  # ---------- RESOURCE GROUP ----------
  echo "Using existing Resource Group: $RG"

  # ---------- LOG ANALYTICS ----------
  az monitor log-analytics workspace show -g "$RG" -n "$LAW" >/dev/null 2>&1 || \
  az monitor log-analytics workspace create -g "$RG" -n "$LAW" -l "$LOCATION" >/dev/null

  # ---------- KEY VAULT ----------
  az keyvault create -g "$RG" -n "$KV" -l "$LOCATION" --enable-rbac-authorization true >/dev/null

  # ---------- APP SERVICE PLAN (API) ----------
  az appservice plan show -g "$RG" -n "$ASP_API" >/dev/null 2>&1 || \
  az appservice plan create -g "$RG" -n "$ASP_API" --is-linux --sku $ASP_PLAN >/dev/null

  # ---------- WEB APP (API Node) ----------
  az webapp show -g "$RG" -n "$APP_API" >/dev/null 2>&1 || \
  az webapp create -g "$RG" -p "$ASP_API" -n "$APP_API" \
    --runtime "NODE|${NODE_MAJOR_VERSION}-lts" >/dev/null

  az webapp identity show -g "$RG" -n "$APP_API" >/dev/null 2>&1 || \
  az webapp identity assign -g "$RG" -n "$APP_API" >/dev/null

  # ---------- SQL SERVER + DB ----------
  az sql server show -g "$RG" -n "$SQL_SERVER" >/dev/null 2>&1 || \
  az sql server create -g "$RG" -n "$SQL_SERVER" -l "$LOCATION" \
    --enable-public-network false -u "sqladminlocal" -p "$SQL_ADMIN_PASSWORD" >/dev/null

  az sql server ad-admin list -g "$RG" -s "$SQL_SERVER" --query '[?displayName==`'$AAD_ADMIN_NAME'`]' -o tsv | grep -q "$AAD_ADMIN_NAME" || \
  az sql server ad-admin create -g "$RG" -s "$SQL_SERVER" \
    --display-name "$AAD_ADMIN_NAME" --object-id "$AAD_ADMIN_OBJECT_ID" >/dev/null

  az sql db show -g "$RG" -s "$SQL_SERVER" -n "$SQL_DB" >/dev/null 2>&1 || \
  az sql db create -g "$RG" -s "$SQL_SERVER" -n "$SQL_DB" --service-objective $SQL_SERVICE_OBJECTIVE >/dev/null

  # ---------- NETWORKING ----------
  # Asegurar que la VNet existe y obtener su ID (está en RG_NETWORKING)
  VNET_ID="$(az network vnet show -g "$RG_NETWORKING" -n "$VNET" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$VNET_ID" ]]; then
    echo "ERROR: VNet $VNET not found in RG $RG_NETWORKING. Create it manually before running this script." >&2
    exit 1
  fi

  # Verify required subnets exist in RG_NETWORKING. VNet/subnets are managed
  # externally (RSG_Networking_Dev). This script will not create them.
  az network vnet subnet show -g "$RG_NETWORKING" --vnet-name "$VNET" -n "$SNET_PE_SQL" >/dev/null 2>&1 || {
    echo "ERROR: Subnet $SNET_PE_SQL not found in VNet $VNET (RG $RG_NETWORKING). Create it before running this script." >&2
    exit 1
  }

  az network vnet subnet show -g "$RG_NETWORKING" --vnet-name "$VNET" -n "$SNET_APP" >/dev/null 2>&1 || {
    echo "ERROR: Subnet $SNET_APP not found in VNet $VNET (RG $RG_NETWORKING). Create it before running this script." >&2
    exit 1
  }

  # Obtener IDs de subnets para operaciones que requieren referencia completa
  APP_SUBNET_ID="$(az network vnet subnet show -g "$RG_NETWORKING" --vnet-name "$VNET" -n "$SNET_APP" --query id -o tsv)"
  PE_SUBNET_ID="$(az network vnet subnet show -g "$RG_NETWORKING" --vnet-name "$VNET" -n "$SNET_PE_SQL" --query id -o tsv)"

  # Integrar Web App con la VNet (usar VNET_ID y subnet id/nombre según necesite)
  az webapp vnet-integration list -g "$RG" -n "$APP_API" --query '[?vnetResourceId!=null]' -o tsv | grep -q "$VNET_ID" >/dev/null 2>&1 || \
  az webapp vnet-integration add -g "$RG" -n "$APP_API" --vnet "$VNET_ID" --subnet "$SNET_APP" >/dev/null

  # ---------- PRIVATE DNS + PRIVATE ENDPOINT (SQL) ----------
  az network private-dns zone show -g "$RG" -n "privatelink.database.windows.net" >/dev/null 2>&1 || \
  az network private-dns zone create -g "$RG" -n "privatelink.database.windows.net" >/dev/null
  
  az network private-dns link vnet show -g "$RG" -n "${PDZ_SQL}-link" -z "privatelink.database.windows.net" >/dev/null 2>&1 || \
  az network private-dns link vnet create -g "$RG" -n "${PDZ_SQL}-link" \
    -z "privatelink.database.windows.net" --virtual-network "$VNET_ID" -e true >/dev/null

  az network private-endpoint show -g "$RG" -n "$PE_SQL" >/dev/null 2>&1 || {
    SQL_ID=$(az sql server show -g "$RG" -n "$SQL_SERVER" --query id -o tsv)
    az network private-endpoint create -g "$RG" -n "$PE_SQL" -l "$LOCATION" \
      --subnet "$PE_SUBNET_ID" \
      --private-connection-resource-id "$SQL_ID" --group-id "sqlServer" \
      --connection-name "${PE_SQL}-conn" >/dev/null
  }

  # DNS Zone Group - Azure maneja automáticamente el registro DNS
  az network private-endpoint dns-zone-group show -g "$RG" --endpoint-name "$PE_SQL" -n "default" >/dev/null 2>&1 || \
  az network private-endpoint dns-zone-group create -g "$RG" --endpoint-name "$PE_SQL" -n "default" \
    --zone-name "privatelink.database.windows.net" --private-dns-zone "$(az network private-dns zone show -g "$RG" -n "privatelink.database.windows.net" --query id -o tsv)" >/dev/null

  # ---------- STORAGE ----------
  az storage account show -g "$RG" -n "$ST_ACCOUNT" >/dev/null 2>&1 || \
  az storage account create -g "$RG" -n "$ST_ACCOUNT" -l "$LOCATION" \
    --sku $STORAGE_SKU --kind StorageV2 >/dev/null
  
  az storage container show --account-name "$ST_ACCOUNT" -n "$ST_CONTAINER" >/dev/null 2>&1 || \
  az storage container create --auth-mode login --account-name "$ST_ACCOUNT" -n "$ST_CONTAINER" >/dev/null || \
  az storage container create --account-name "$ST_ACCOUNT" --account-key "${ST_ACCOUNT_KEY:-}" -n "$ST_CONTAINER" >/dev/null || \
  az storage container create --account-name "$ST_ACCOUNT" --sas-token "${ST_SAS:-}" -n "$ST_CONTAINER" >/dev/null

  # Assign Storage Blob Data Contributor role to the Web App managed identity
  APP_PRINCIPAL_ID=$(az webapp identity show -g "$RG" -n "$APP_API" --query principalId -o tsv || true)
  if [[ -n "$APP_PRINCIPAL_ID" ]]; then
    STORAGE_SCOPE=$(az storage account show -g "$RG" -n "$ST_ACCOUNT" --query id -o tsv)
    az role assignment list --assignee "$APP_PRINCIPAL_ID" --scope "$STORAGE_SCOPE" --role "Storage Blob Data Contributor" -o tsv | grep -q "$APP_PRINCIPAL_ID" >/dev/null 2>&1 || \
    az role assignment create --assignee-object-id "$APP_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
      --role "Storage Blob Data Contributor" --scope "$STORAGE_SCOPE" >/dev/null || true
  else
    echo "WARNING: Web App managed identity not found for $APP_API; cannot assign storage role now." >&2
  fi

  # ---------- APP SETTINGS (API) ----------
  SQL_CONN="Server=tcp:${SQL_SERVER}.database.windows.net,1433;Database=${SQL_DB};Encrypt=true;TrustServerCertificate=false;Authentication=ActiveDirectoryManagedIdentity;"
  az webapp config appsettings set -g "$RG" -n "$APP_API" --settings \
    NODE_ENV="$ENV" \
    WEBSITE_NODE_DEFAULT_VERSION="~${NODE_MAJOR_VERSION}" \
    SQL_AAD_CONNECTION_STRING="$SQL_CONN" \
    STORAGE_ACCOUNT_NAME="$ST_ACCOUNT" \
    STORAGE_CONTAINER_NAME="$ST_CONTAINER" >/dev/null

  # ---------- STATIC WEB APP (ADMIN) ----------
  if [[ "$ENV" == "test" ]]; then SWA_BRANCH="$GH_BRANCH_TEST"; else SWA_BRANCH="$GH_BRANCH_PROD"; fi
  az staticwebapp show -g "$RG" -n "$SWA" >/dev/null 2>&1 || \
  az staticwebapp create -g "$RG" -n "$SWA" -l "$LOCATION" \
    --sku $SWA_SKU --source "$SWA_REPO" --branch "$SWA_BRANCH" --login-with-github >/dev/null

  # ---------- TAGS ----------
  az tag create --resource-id "$(az group show -n "$RG" --query id -o tsv)" --tags app=proveedores env="$ENV" >/dev/null

  echo "RG: $RG"
  echo "API: $APP_API | SQL: $SQL_SERVER / $SQL_DB"
  echo "SWA(admin): $SWA"
  echo "KV: $KV | LAW: $LAW | VNET: $VNET"
  echo "Storage: $ST_ACCOUNT (container: $ST_CONTAINER)"
  echo
}

# =================== EXECUTION ===================
create_env "dev" "$GH_BRANCH_DEV"
# create_env "test" "$GH_BRANCH_TEST"
# create_env "prod" "$GH_BRANCH_PROD"

echo "Run the SQL step to create the AAD user for the Web App MI in each DB."
echo "Remember to set up GitHub Actions for backend: $GH_REPO_BACKEND"
