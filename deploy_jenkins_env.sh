#!/usr/bin/env bash
set -euo pipefail

# --- Verifica herramientas ---
for cmd in kubectl helm python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ '$cmd' no está instalado."
    exit 1
  fi
done

export PATH="$PATH:/usr/local/bin:/usr/bin:/snap/bin"

# --- Verifica .env ---
if [[ ! -f .env ]]; then
  echo "❌ Archivo .env no encontrado."
  exit 1
fi

# --- Cargar .env ---
set -a
source .env
set +a

# --- Verifica variables necesarias ---
required_vars=(JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ '$var' no está definido en .env"
    exit 1
  fi
done

# --- Generar hash (solo en memoria) ---
echo "🔑 Generando hash bcrypt..."
JENKINS_ADMIN_PASSWORD_HASH=$(python3 - <<EOF
import bcrypt, os
password = os.environ['JENKINS_ADMIN_PASSWORD'].encode()
hashed = bcrypt.hashpw(password, bcrypt.gensalt(prefix=b'2a'))
print("#jbcrypt:" + hashed.decode())
EOF
)

# --- Verifica hash válido ---
if [[ ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt:\$2a\$.* ]]; then
  echo "❌ Hash inválido"
  exit 1
fi
echo "✅ Hash generado"

# --- Variables ---
NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"

# --- Funciones ---
delete_secrets() {
  kubectl delete secret jenkins-admin dockerhub-credentials github-ci-token dockerhub-config -n "$NAMESPACE" --ignore-not-found
}

create_secrets() {
  kubectl create secret generic jenkins-admin \
    --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
    --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD_HASH" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic dockerhub-credentials \
    --from-literal=username="$DOCKERHUB_USERNAME" \
    --from-literal=password="$DOCKERHUB_TOKEN" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic github-ci-token \
    --from-literal=token="$GITHUB_TOKEN" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  mkdir -p ~/.docker
  echo '{
    "auths": {
      "https://index.docker.io/v1/": {
        "auth": "'$(echo -n "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" | base64)'"
      }
    }
  }' > ~/.docker/config.json

  kubectl create secret generic dockerhub-config \
    --from-file=config.json=$HOME/.docker/config.json \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

# --- Desinstalar Jenkins y borrar PVC ---
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
  helm uninstall "$RELEASE" -n "$NAMESPACE"
  kubectl delete pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" --ignore-not-found
  sleep 10
fi

# --- Crear namespace ---
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- Crear secretos ---
delete_secrets
create_secrets

# --- Instalar Jenkins ---
helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update
helm upgrade --install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  --create-namespace \
  -f jenkins-values.yaml \
  --timeout 10m

# --- Esperar que Jenkins esté listo ---
timeout=600
elapsed=0
while [[ $elapsed -lt $timeout ]]; do
  if kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=30s; then
    echo "✅ Jenkins listo"
    break
  fi
  sleep 30
  elapsed=$((elapsed + 30))
done

if [[ $elapsed -ge $timeout ]]; then
  echo "❌ Jenkins no arrancó a tiempo"
  kubectl get pods -n "$NAMESPACE"
  kubectl logs -n "$NAMESPACE" statefulset/"$RELEASE" -c jenkins --tail=100
  exit 1
fi

# --- Acceso ---
cat <<EOF

🎉 Jenkins desplegado

🌐 URL: http://localhost:8080
👤 Usuario: $JENKINS_ADMIN_USER
🔒 Contraseña: $JENKINS_ADMIN_PASSWORD

EOF

echo "🔗 Port-forward activado..."
kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080