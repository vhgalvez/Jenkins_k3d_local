#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Despliega Jenkins en k3d/k3s usando el chart oficial + JCasC
# ---------------------------------------------------------------------------
set -eu  # (-o pipefail omitido por /bin/sh)

# deploy_jenkins_render.sh


# ───────────────────────── 0. BINARIOS Y ENV  ────────────────────────────────
for bin in kubectl helm python3 envsubst; do
    command -v "$bin" >/dev/null || { echo "❌ Falta $bin"; exit 1; }
done
[[ -f .env ]] || { echo "❌ Falta .env"; exit 1; }

# shellcheck disable=SC1091
set -a; source .env; set +a

: "${JENKINS_ADMIN_USER?}";   : "${JENKINS_ADMIN_PASSWORD?}"
: "${DOCKERHUB_USERNAME?}";   : "${DOCKERHUB_TOKEN?}"
: "${GITHUB_TOKEN?}"

# Puertos locales (se pueden sobre‑escribir en .env)
HTTP_PORT="${HTTP_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"

# ──────────────────────── 1. FUNCIONES UTILIDAD ──────────────────────────────
cleanup_previous() {
    echo "🧹 Eliminando despliegue Jenkins anterior…"
    helm uninstall jenkins-local-k3d -n jenkins --wait || true
    kubectl delete all,pvc,secret,cm,svc,statefulset,deploy -l app.kubernetes.io/instance=jenkins-local-k3d -n jenkins --ignore-not-found
}

kill_old_pf() {
    # Mata port‑forward antiguos para evitar “address already in use”
    pkill -f "kubectl .*port-forward.*jenkins-local-k3d" 2>/dev/null || true
}

bcrypt_hash() {
  python3 - <<'PY' "$JENKINS_ADMIN_PASSWORD"
import bcrypt, os, sys
pwd=sys.argv[1].encode()
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
  cat >"$HOME/.docker/config.json" <<EOF
{"auths":{"https://index.docker.io/v1/":{"auth":"$(echo -n "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" | base64)"}}}
EOF
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
    echo "⏳ Esperando StatefulSet…"
    kubectl rollout status sts/jenkins-local-k3d -n jenkins --timeout=600s
}

start_port_forward() {
    kill_old_pf
    kubectl -n jenkins port-forward svc/jenkins-local-k3d \
    "$HTTP_PORT":8080 "$AGENT_PORT":50000 \
    --address 0.0.0.0 >/dev/null 2>&1 &
    echo "🔗 Port‑forward activo:  http://localhost:${HTTP_PORT}  (agente: ${AGENT_PORT})"
}

# ─────────────────────────────── 2. FLUJO ────────────────────────────────────
cleanup_previous
HASH=$(bcrypt_hash)
echo "👤 Usuario: $JENKINS_ADMIN_USER"
echo "🔑 Hash:    $HASH"

export JENKINS_ADMIN_PASSWORD_HASH="$HASH"
render_values
create_secrets "$HASH"
deploy_jenkins
wait_ready
start_port_forward

cat <<EOF

✅ Jenkins desplegado correctamente

🌐 URL:       http://localhost:${HTTP_PORT}
👤 Usuario:   $JENKINS_ADMIN_USER
🔑 Contraseña: (la definida en tu .env)

EOF
