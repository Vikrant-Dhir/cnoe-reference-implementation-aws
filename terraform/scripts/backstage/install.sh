#!/bin/bash
set -e -o pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)

export POSTGRES_PASSWORD=${1}
export BACKSTAGE_DOMAIN_NAME=${2}
export KEYCLOAK_DOMAIN_NAME=${3}
export ARGO_WORKFLOWS_DOMAIN_NAME=${4}
export GITHUB_APP_YAML=$(cat ${REPO_ROOT}/private/github-integration.yaml | base64)

kubectl wait --for=jsonpath=.status.health.status=Healthy -n argocd application/keycloak
kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak  --timeout=30s
echo "Creating keycloak client for Backstage"

ADMIN_PASSWORD=$(kubectl get secret -n keycloak keycloak-config -o go-template='{{index .data "KEYCLOAK_ADMIN_PASSWORD" | base64decode}}')

kubectl port-forward -n keycloak svc/keycloak 8080:8080 > /dev/null 2>&1 &
pid=$!
trap '{
  rm config-payloads/*-to-be-applied.json || true
  kill $pid
}' EXIT
echo "waiting for port forward to be ready"
while ! nc -vz localhost 8080 > /dev/null 2>&1 ; do
    sleep 2
done

KEYCLOAK_TOKEN=$(curl -sS  --fail-with-body -X POST -H "Content-Type: application/x-www-form-urlencoded" \
--data-urlencode "username=cnoe-admin" \
--data-urlencode "password=${ADMIN_PASSWORD}" \
--data-urlencode "grant_type=password" \
--data-urlencode "client_id=admin-cli" \
localhost:8080/realms/master/protocol/openid-connect/token | jq -e -r '.access_token')

envsubst < config-payloads/client-payload.json > config-payloads/client-payload-to-be-applied.json

curl -sS -H "Content-Type: application/json" \
-H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
-X POST --data @config-payloads/client-payload-to-be-applied.json \
localhost:8080/admin/realms/cnoe/clients

CLIENT_ID=$(curl -sS -H "Content-Type: application/json" \
-H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
-X GET localhost:8080/admin/realms/cnoe/clients | jq -e -r  '.[] | select(.clientId == "backstage") | .id')

export CLIENT_SECRET=$(curl -sS -H "Content-Type: application/json" \
-H "Authorization: bearer ${KEYCLOAK_TOKEN}" \
-X GET localhost:8080/admin/realms/cnoe/clients/${CLIENT_ID} | jq -e -r '.secret')

CLIENT_SCOPE_GROUPS_ID=$(curl -sS -H "Content-Type: application/json" -H "Authorization: bearer ${KEYCLOAK_TOKEN}" -X GET  localhost:8080/admin/realms/cnoe/client-scopes | jq -e -r  '.[] | select(.name == "groups") | .id')

curl -sS -H "Content-Type: application/json" -H "Authorization: bearer ${KEYCLOAK_TOKEN}" -X PUT  localhost:8080/admin/realms/cnoe/clients/${CLIENT_ID}/default-client-scopes/${CLIENT_SCOPE_GROUPS_ID}

echo 'storing client secrets to backstage namespace'
envsubst < secret-env-var.yaml | kubectl apply -f -
envsubst < secret-integrations.yaml | kubectl apply -f -

#If TLS secret is available in /private, use it. Could be empty...
if ls ${REPO_ROOT}/private/backstage-tls-backup-* 1> /dev/null 2>&1; then
    TLS_FILE=$(ls -t ${REPO_ROOT}/private/backstage-tls-backup-* | head -n1)
    kubectl apply -f ${TLS_FILE}
fi
