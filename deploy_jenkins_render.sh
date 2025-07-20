
#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Despliega Jenkins en k3d/k3s usando el chart oficial + JCasC 
# -----------------------------------------------------------------------------
# deploy_jenkins_render.sh

set -eu  # no usamos -o pipefail porque algunos shells /bin/sh no lo soportan

# 0. Comprobaciones básicas ----------------------------------------------------
for bin in kubectl helm python3 envsubst; do
  command -v "$bin" >/dev/null || { echo "❌ Falta $bin"; exit 1; }
done
[[ -f .env ]] || { echo "❌ Falta .env"; exit 1; }

# 1. Cargar variables de entorno ----------------------------------------------
set -a
source .env
set +a

for v in JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD \
         DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN; do
  [[ -z "${!v:-}" ]] && { echo "❌ Variable $v vacía en .env"; exit 1; }
done

# 2. Hash BCrypt solo en RAM ---------------------------------------------------
echo "🔐 Generando hash bcrypt..."
JENKINS_ADMIN_PASSWORD_HASH="$(
  python3 - <<'PY'
import bcrypt, os
hp = bcrypt.hashpw(os.environ['JENKINS_ADMIN_PASSWORD'].encode(),
                   bcrypt.gensalt(prefix=b'2a'))
print('#jbcrypt:' + hp.decode())
PY
)"

[[ $JENKINS_ADMIN_PASSWORD_HASH =~ ^#jbcrypt:\$2a\$ ]] \
  || { echo "❌ Hash inválido"; exit 1; }

# 3. Renderizar jenkins-values.yaml -------------------------------------------
export JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD_HASH \
       DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN

echo "📝 Renderizando jenkins-values.yaml"
envsubst < jenkins-values.template.yaml > jenkins-values.yaml

# 4. Namespace + Secrets -------------------------------------------------------
kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins delete secret \
  jenkins-admin dockerhub-credentials github-ci-token dockerhub-config \
  --ignore-not-found

kubectl -n jenkins create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD_HASH"

kubectl -n jenkins create secret generic dockerhub-credentials \
  --from-literal=username="$DOCKERHUB_USERNAME" \
  --from-literal=password="$DOCKERHUB_TOKEN"

kubectl -n jenkins create secret generic github-ci-token \
  --from-literal=token="$GITHUB_TOKEN"

# Docker config para Kaniko
mkdir -p "$HOME/.docker"
echo "{\"auths\":{\"https://index.docker.io/v1/\":{\
\"auth\":\"$(echo -n "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" | base64)\"}}}" \
  > "$HOME/.docker/config.json"

kubectl -n jenkins create secret generic dockerhub-config \
  --from-file=config.json="$HOME/.docker/config.json" \
  --dry-run=client -o yaml | kubectl apply -f -

# 5. Instalar / actualizar Jenkins --------------------------------------------
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install jenkins-local-k3d jenkins/jenkins \
  -n jenkins -f jenkins-values.yaml --timeout 10m

# 6. Esperar a que el StatefulSet esté listo ----------------------------------
echo "⏳ Esperando a que Jenkins esté listo..."
kubectl rollout status sts/jenkins-local-k3d -n jenkins --timeout=600s

# 7. Información final ---------------------------------------------------------
cat <<EOF

✅ Jenkins desplegado correctamente

URL local:   http://localhost:8080
Usuario:     $JENKINS_ADMIN_USER
Contraseña:  (la definida en tu .env)

EOF

# Port‑forward en background
kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080 >/dev/null 2>&1 &
echo "🔗 Port‑forward activo en http://localhost:8080"
