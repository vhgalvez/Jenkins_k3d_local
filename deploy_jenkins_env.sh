#!/usr/bin/env bash
set -euo pipefail

#──────────────────────────────────────────────────────────────
#  Jenkins deployment with Kaniko + Docker Hub (k3d / k3s)
#──────────────────────────────────────────────────────────────

# 1) Cargar .env ------------------------------------------------
[[ -f .env ]] || { echo "❌ Falta .env"; exit 1; }
set -a; source .env; set +a

# 2) Verificar herramientas ------------------------------------
for c in kubectl helm python3; do
  command -v "$c" &>/dev/null || { echo "❌ Falta $c"; exit 1; }
done

# 3) Generar hash bcrypt (en memoria) --------------------------
echo "🔑 Generando hash bcrypt..."
JENKINS_ADMIN_PASSWORD_HASH=$(python3 - <<'PY'
import bcrypt, os, sys
pwd = os.environ['JENKINS_ADMIN_PASSWORD'].encode()
print("#jbcrypt:" + bcrypt.hashpw(pwd, bcrypt.gensalt(prefix=b'2a')).decode())
PY
)
[[ $JENKINS_ADMIN_PASSWORD_HASH =~ ^#jbcrypt:\$2a\$ ]] || { echo "❌ Hash inválido"; exit 1; }

# 4) Exportar para envsubst ------------------------------------
export JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD_HASH \
       DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN

envsubst < jenkins-values.template.yaml > jenkins-values.yaml

# 5) Crear/actualizar secretos ---------------------------------
NAMESPACE=jenkins
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

for s in jenkins-admin dockerhub-credentials github-ci-token; do
  kubectl delete secret "$s" -n "$NAMESPACE" --ignore-not-found
done

kubectl create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD_HASH" \
  -n "$NAMESPACE"

kubectl create secret generic dockerhub-credentials \
  --from-literal=username="$DOCKERHUB_USERNAME" \
  --from-literal=password="$DOCKERHUB_TOKEN" \
  -n "$NAMESPACE"

kubectl create secret generic github-ci-token \
  --from-literal=token="$GITHUB_TOKEN" \
  -n "$NAMESPACE"

# 6) Instalar / actualizar Jenkins -----------------------------
helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update

helm upgrade --install jenkins-local-k3d jenkins/jenkins \
  -n "$NAMESPACE" \
  -f jenkins-values-env.yaml \
  --timeout 10m

echo -e "\n🎉 Jenkins desplegado. Inicia sesión con:"
echo "   URL: http://localhost:8080"
echo "   Usuario: $JENKINS_ADMIN_USER"
echo "   Contraseña: $JENKINS_ADMIN_PASSWORD"
echo
echo "🔗 Port‑forward activo (Ctrl‑C para salir)…"
kubectl port-forward -n "$NAMESPACE" svc/jenkins-local-k3d 8080:8080
