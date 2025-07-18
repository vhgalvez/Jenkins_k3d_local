#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# 📦 Jenkins Deployment Script con soporte para Kaniko + DockerHub
# ──────────────────────────────────────────────────────────────

# --- Validar herramientas necesarias ---
for cmd in kubectl helm python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Error: '$cmd' no está instalado o no está en el PATH."
    exit 1
  fi
done

# --- Asegurar PATH útil si se ejecuta con sudo ---
export PATH="$PATH:/usr/local/bin:/usr/bin:/snap/bin"

# --- Verificar archivo .env ---
if [[ ! -f .env ]]; then
  echo "❌ Archivo .env no encontrado. Crea uno con tus credenciales."
  exit 1
fi

# --- Cargar variables del entorno ---
set -a
source .env
set +a

# --- Validar variables críticas ---
required_vars=(JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ La variable '$var' no está definida en .env"
    exit 1
  fi
done

# --- Generar hash bcrypt de la contraseña (siempre en memoria) ---
echo "🔑 Generando hash bcrypt..."
JENKINS_ADMIN_PASSWORD_HASH=$(python3 - <<EOF
import bcrypt, os
password = os.environ['JENKINS_ADMIN_PASSWORD'].encode()
hashed = bcrypt.hashpw(password, bcrypt.gensalt(prefix=b'2a'))
print("#jbcrypt:" + hashed.decode())
EOF
)

if [[ ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt:\$2a\$.* ]]; then
  echo "❌ Error: Hash inválido. Debe empezar con '#jbcrypt:\$2a\$'"
  exit 1
fi

echo "✅ Hash generado correctamente"

# --- Variables de despliegue ---
NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"

# --- Funciones ---
delete_secrets() {
  echo "🗑️ Eliminando secretos anteriores..."
  kubectl delete secret jenkins-admin dockerhub-credentials github-ci-token dockerhub-config -n "$NAMESPACE" --ignore-not-found
}

create_secrets() {
  echo "🔐 Creando secretos..."

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

  # DockerHub Auth para Kaniko
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

  echo "✅ Secretos cargados correctamente."
}

# --- Eliminar despliegue previo y PVC ---
echo "🔍 Verificando despliegue existente..."
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
  echo "🗑️ Eliminando Jenkins anterior..."
  helm uninstall "$RELEASE" -n "$NAMESPACE"
  echo "🧼 Borrando volumen persistente (PVC)..."
  kubectl delete pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" --ignore-not-found
  sleep 10
fi

# --- Crear namespace si no existe ---
echo "🚀 Creando namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- Crear secretos ---
delete_secrets
create_secrets

# --- Instalar Jenkins via Helm ---
echo "📦 Instalando Jenkins vía Helm..."
helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update
helm upgrade --install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  --create-namespace \
  -f jenkins-values.yaml \
  --timeout 10m

# --- Esperar Jenkins listo ---
echo "⏳ Esperando que Jenkins esté listo..."
timeout=600
elapsed=0
while [[ $elapsed -lt $timeout ]]; do
  if kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=30s; then
    echo "✅ Jenkins está listo."
    break
  fi
  echo "⏳ Esperando... ($elapsed/$timeout)"
  sleep 30
  elapsed=$((elapsed + 30))
done

if [[ $elapsed -ge $timeout ]]; then
  echo "❌ Jenkins no arrancó a tiempo."
  kubectl get pods -n "$NAMESPACE"
  kubectl logs -n "$NAMESPACE" statefulset/"$RELEASE" -c jenkins --tail=100
  exit 1
fi

# --- Mostrar info de acceso ---
cat <<EOF

🎉 Jenkins desplegado correctamente

🌐 URL:       http://localhost:8080
👤 Usuario:   $JENKINS_ADMIN_USER
🔒 Contraseña: $JENKINS_ADMIN_PASSWORD
🧾 Hash (usado en el secreto): $JENKINS_ADMIN_PASSWORD_HASH

EOF

echo "🔗 Iniciando port-forward..."
kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080