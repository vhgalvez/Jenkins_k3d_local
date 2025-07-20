# deploy_jenkins_render.sh
#!/usr/bin/env bash
set -euo pipefail

# 0. Comprobaciones
for c in kubectl helm python3 envsubst; do
  command -v "$c" >/dev/null || { echo "❌ Falta $c"; exit 1; }
done
[[ -f .env ]] || { echo "❌ Falta .env"; exit 1; }

# 1. Cargar variables
set -a; source .env; set +a
for v in JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD \
         DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN; do
  [[ -z "${!v:-}" ]] && { echo "❌ Variable $v vacía"; exit 1; }
done

# 2. Generar hash bcrypt
echo "🔐 Generando hash bcrypt..."
JENKINS_ADMIN_PASSWORD_HASH=$(python3 - <<'EOF'
import bcrypt, os
print("#jbcrypt:" + bcrypt.hashpw(
  os.environ["JENKINS_ADMIN_PASSWORD"].encode(),
  bcrypt.gensalt(prefix=b"2a")
).decode())
EOF
)
[[ $JENKINS_ADMIN_PASSWORD_HASH =~ ^#jbcrypt:\$2a\$ ]] || \
  { echo "❌ Hash inválido"; exit 1; }

# 3. Renderizar values
echo "📝 Renderizando jenkins-values.yaml…"
export JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD_HASH \
       DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN
envsubst < jenkins-values.template.yaml > jenkins-values.yaml

# 4. Namespace y secretos
kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins delete secret jenkins-admin dockerhub-credentials github-ci-token dockerhub-config --ignore-not-found

kubectl -n jenkins create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD_HASH"

kubectl -n jenkins create secret generic dockerhub-credentials \
  --from-literal=username="$DOCKERHUB_USERNAME" \
  --from-literal=password="$DOCKERHUB_TOKEN"

kubectl -n jenkins create secret generic github-ci-token \
  --from-literal=token="$GITHUB_TOKEN"

mkdir -p ~/.docker
echo "{\"auths\":{\"https://index.docker.io/v1/\":{\"auth\":\"$(echo -n \"$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN\" | base64)\"}}}" > ~/.docker/config.json
kubectl -n jenkins create secret generic dockerhub-config \
  --from-file=config.json=$HOME/.docker/config.json \
  --dry-run=client -o yaml | kubectl apply -f -

# 5. Instalar o actualizar Jenkins
helm repo add jenkins https://charts.jenkins.io >/dev/null || true
helm repo update >/dev/null
helm upgrade --install jenkins-local-k3d jenkins/jenkins \
     -n jenkins -f jenkins-values.yaml --timeout 10m

# 6. Esperar y mostrar info
kubectl rollout status sts/jenkins-local-k3d -n jenkins --timeout=600s
echo -e "\n✅ Jenkins listo en: http://localhost:8080"
echo   "👤 Usuario: $JENKINS_ADMIN_USER"
echo   "🔑 Contraseña: $JENKINS_ADMIN_PASSWORD"
kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080 &