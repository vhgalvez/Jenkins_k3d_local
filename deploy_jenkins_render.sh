#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Despliega Jenkins en K3d/K3s usando Helm + JCasC + Port-forward persistente
# ---------------------------------------------------------------------------

set -eu  # Compatible con /bin/sh

# ─────── 0. BINARIOS Y ENTORNO ──────────────────────────────────────────────
for bin in kubectl helm python3 envsubst; do
    command -v "$bin" >/dev/null || { echo "❌ Falta $bin"; exit 1; }
done

[[ -f .env ]] || { echo "❌ Falta archivo .env"; exit 1; }
set -a; source .env; set +a

: "${JENKINS_ADMIN_USER?}"; : "${JENKINS_ADMIN_PASSWORD?}"
: "${DOCKERHUB_USERNAME?}"; : "${DOCKERHUB_TOKEN?}"
: "${GITHUB_TOKEN?}"

HTTP_PORT="${HTTP_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"

# ─────── 1. FUNCIONES ────────────────────────────────────────────────────────

cleanup_previous() {
    echo "🧹 Limpiando despliegue anterior de Jenkins..."
    helm uninstall jenkins-local-k3d -n jenkins --wait || true
    kubectl delete all,pvc,secret,cm,svc,statefulset,deployment \
    -l app.kubernetes.io/instance=jenkins-local-k3d -n jenkins --ignore-not-found
}

kill_old_pf() {
    pkill -f "kubectl .*port-forward.*jenkins-local-k3d" 2>/dev/null || true
}

bcrypt_hash() {
  python3 - <<'PY' "$JENKINS_ADMIN_PASSWORD"
import bcrypt, sys
pwd = sys.argv[1].encode()
print('#jbcrypt:' + bcrypt.hashpw(pwd, bcrypt.gensalt(prefix=b'2a')).decode())
PY
}

create_secrets() {
    local hash="$1"
    kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n jenkins delete secret jenkins-admin dockerhub-credentials github-ci-token dockerhub-config --ignore-not-found
    
    kubectl -n jenkins create secret generic jenkins-admin \
    --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
    --from-literal=jenkins-admin-password="$hash"
    
    kubectl -n jenkins create secret generic dockerhub-credentials \
    --from-literal=username="$DOCKERHUB_USERNAME" \
    --from-literal=password="$DOCKERHUB_TOKEN"
    
    kubectl -n jenkins create secret generic github-ci-token \
    --from-literal=token="$GITHUB_TOKEN"
    
    mkdir -p "$HOME/.docker"
    echo "{\"auths\":{\"https://index.docker.io/v1/\":{\"auth\":\"$(echo -n "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" | base64)\"}}}" > "$HOME/.docker/config.json"
    
    kubectl -n jenkins create secret generic dockerhub-config \
    --from-file=config.json="$HOME/.docker/config.json" \
    --dry-run=client -o yaml | kubectl apply -f -
}

render_values() {
    envsubst < jenkins-values.template.yaml > jenkins-values.yaml
}

deploy_jenkins() {
    helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
    helm repo update >/dev/null
    helm upgrade --install jenkins-local-k3d jenkins/jenkins \
    -n jenkins -f jenkins-values.yaml --timeout 10m
}

wait_ready() {
    echo "⏳ Esperando a que Jenkins esté listo..."
    kubectl rollout status sts/jenkins-local-k3d -n jenkins --timeout=600s
}

# ─────── 2. EJECUCIÓN ────────────────────────────────────────────────────────

cleanup_previous
HASH=$(bcrypt_hash)

echo "👤 Usuario: $JENKINS_ADMIN_USER"
echo "🔑 Hash generado: $HASH"

export JENKINS_ADMIN_PASSWORD_HASH="$HASH"
render_values
create_secrets "$HASH"
deploy_jenkins
wait_ready
kill_old_pf

echo
echo "✅ Jenkins desplegado correctamente"
echo
echo "🌐 URL:        http://localhost:${HTTP_PORT}"
echo "👤 Usuario:    $JENKINS_ADMIN_USER"
echo "🔑 Contraseña: (la que definiste en .env)"
echo
echo "⏳ Abriendo puerto local persistente para Jenkins…"
echo "🔗 Visita:     http://localhost:${HTTP_PORT}"
echo

# Mantener el puerto abierto en primer plano
kubectl port-forward -n jenkins svc/jenkins-local-k3d \
"${HTTP_PORT}:8080" "${AGENT_PORT}:50000" \
--address 0.0.0.0