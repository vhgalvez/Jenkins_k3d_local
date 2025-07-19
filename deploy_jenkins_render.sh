#!/usr/bin/env bash
set -euo pipefail

# 0. Requisitos
for c in kubectl helm python3 envsubst; do
  command -v "$c" >/dev/null || { echo "❌ Falta $c"; exit 1; }
done

[[ -f .env ]] || { echo "❌ Falta .env"; exit 1; }

# 1. Cargar variables
set -a
source .env
set +a

for var in JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN; do
  [[ -z "${!var:-}" ]] && { echo "❌ Variable no definida: $var"; exit 1; }
done

# 2. Generar hash bcrypt
echo "🔐 Generando hash bcrypt..."
JENKINS_ADMIN_PASSWORD_HASH=$(
  python3 - <<EOF
import bcrypt, os
pwd = os.environ['JENKINS_ADMIN_PASSWORD'].encode()
h = bcrypt.hashpw(pwd, bcrypt.gensalt(prefix=b'2a'))
print("#jbcrypt:" + h.decode())
EOF
)

[[ "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt:\$2a\$.* ]] || {
  echo "❌ Hash inválido"; exit 1
}

# 3. Renderizar values
echo "📝 Renderizando jenkins-values.yaml…"
tmpfile=$(mktemp /tmp/jenkins-values.XXXXXX.yaml)
export JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD_HASH \
       DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN
envsubst < jenkins-values.template.yaml > "$tmpfile"
mv -f "$tmpfile" jenkins-values.yaml

# 4. Eliminar Jenkins viejo (opcional, asegura configuración limpia)
echo "🧹 Eliminando Jenkins anterior..."
helm uninstall jenkins-local-k3d -n jenkins || true
kubectl delete pvc jenkins-local-k3d -n jenkins || true

# 5. Crear namespace y secrets
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

# 6. Instalar Jenkins
echo "📦 Instalando Jenkins con Helm..."
helm repo add jenkins https://charts.jenkins.io >/dev/null || true
helm repo update >/dev/null

helm upgrade --install jenkins-local-k3d jenkins/jenkins \
  -n jenkins \
  -f jenkins-values.yaml \
  --timeout 10m

# 7. Esperar
echo "⏳ Esperando a que Jenkins esté listo..."
kubectl rollout status statefulset/jenkins-local-k3d -n jenkins --timeout=600s

# 8. Acceso
cat <<EOF

✅ Jenkins desplegado correctamente

🌐 URL local:      http://localhost:8080
👤 Usuario:        $JENKINS_ADMIN_USER
🔑 Contraseña:     $JENKINS_ADMIN_PASSWORD

EOF

echo "🔗 Iniciando port-forward en background..."
kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080 &