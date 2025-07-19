#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────
# 0) Comprobaciones iniciales
# ────────────────────────────────
for c in kubectl helm python3 envsubst; do
  command -v "$c" >/dev/null || { echo "❌ Falta $c"; exit 1; }
done

[[ -f .env ]] || { echo "❌ Falta .env"; exit 1; }

# Cargar variables
set -a
source .env
set +a

# Validar que no hay variables vacías
for var in JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN; do
  [[ -z "${!var:-}" ]] && { echo "❌ Variable no definida: $var"; exit 1; }
done

# ────────────────────────────────
# 1) Generar hash bcrypt
# ────────────────────────────────
echo "🔐 Generando hash bcrypt..."
JENKINS_ADMIN_PASSWORD_HASH=$(
  python3 - <<EOF
import bcrypt, os
pwd = os.environ['JENKINS_ADMIN_PASSWORD'].encode()
h = bcrypt.hashpw(pwd, bcrypt.gensalt(prefix=b'2a'))
print("#jbcrypt:" + h.decode())
EOF
)

# Validar formato
[[ "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt:\$2a\$.* ]] || {
  echo "❌ Hash inválido"; exit 1
}

# ────────────────────────────────
# 2) Renderizar jenkins-values.yaml (temporal + permisos seguros)
# ────────────────────────────────
export JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD_HASH \
       DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN

echo "📝 Renderizando jenkins-values.yaml…"
tmpfile=$(mktemp /tmp/jenkins-values.XXXXXX.yaml)
envsubst < jenkins-values.template.yaml > "$tmpfile"
mv -f "$tmpfile" jenkins-values.yaml

# ────────────────────────────────
# 3) Crear namespace + secrets
# ────────────────────────────────
echo "🔐 Creando secretos en namespace jenkins"
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -

kubectl delete secret jenkins-admin dockerhub-credentials github-ci-token dockerhub-config -n jenkins --ignore-not-found

kubectl create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD_HASH" \
  -n jenkins

kubectl create secret generic dockerhub-credentials \
  --from-literal=username="$DOCKERHUB_USERNAME" \
  --from-literal=password="$DOCKERHUB_TOKEN" \
  -n jenkins

kubectl create secret generic github-ci-token \
  --from-literal=token="$GITHUB_TOKEN" \
  -n jenkins

# Docker config para Kaniko
echo "🛠️  Generando docker config.json para Kaniko..."
mkdir -p ~/.docker
echo "{
  \"auths\": {
    \"https://index.docker.io/v1/\": {
      \"auth\": \"$(echo -n "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" | base64)\"
    }
  }
}" > ~/.docker/config.json

kubectl create secret generic dockerhub-config \
  --from-file=config.json=$HOME/.docker/config.json \
  -n jenkins --dry-run=client -o yaml | kubectl apply -f -

# ────────────────────────────────
# 4) Instalar Jenkins con Helm
# ────────────────────────────────
echo "📦 Instalando Jenkins con Helm..."
helm repo add jenkins https://charts.jenkins.io >/dev/null || true
helm repo update >/dev/null

helm upgrade --install jenkins-local-k3d jenkins/jenkins \
  -n jenkins \
  -f jenkins-values.yaml \
  --timeout 10m

# ────────────────────────────────
# 5) Esperar a que Jenkins esté listo
# ────────────────────────────────
echo "⏳ Esperando a que Jenkins esté listo..."
kubectl rollout status statefulset/jenkins-local-k3d -n jenkins --timeout=600s

# ────────────────────────────────
# 6) Acceso y port-forward
# ────────────────────────────────
cat <<EOF

✅ Jenkins desplegado correctamente

🌐 URL local:      http://localhost:8080
👤 Usuario:        $JENKINS_ADMIN_USER
🔑 Contraseña:     $JENKINS_ADMIN_PASSWORD

EOF

echo "🔗 Iniciando port-forward en background..."
kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080 &