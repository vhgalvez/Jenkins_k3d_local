#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# deploy_jenkins_render.sh
#   ▸ Despliega Jenkins en K3d / K3s con Helm + JCasC
#   ▸ Genera TODOS los secrets (admin, DockerHub, GitHub PAT, Kaniko config)
#   ▸ Mantiene el puerto 8080 abierto en segundo plano (reconecta si se cae)
# ──────────────────────────────────────────────────────────────────────────────
set -eu
shopt -s huponexit        # mata port‑forward si se hace Ctrl‑C

# ═══ 0. PRERREQUISITOS ════════════════════════════════════════════════════════
for bin in kubectl helm python3 envsubst; do
    command -v "$bin" >/dev/null || { echo "❌ Falta $bin"; exit 1; }
done

[[ -f .env ]] || { echo "❌ Falta archivo .env"; exit 1; }
set -a; source .env; set +a   # exporta vars de .env

: "${JENKINS_ADMIN_USER?}"   "${JENKINS_ADMIN_PASSWORD?}"
: "${DOCKERHUB_USERNAME?}"   "${DOCKERHUB_TOKEN?}"
: "${GITHUB_TOKEN?}"

NAMESPACE="jenkins"
HTTP_PORT="${HTTP_PORT:-8080}"

# ═══ 1. UTILIDADES ═══════════════════════════════════════════════════════════
log() { printf "\e[1;36m» %s\e[0m\n" "$*"; }

kill_old_pf() {
    pkill -f "kubectl .*port-forward.*svc/jenkins-local-k3d" 2>/dev/null || true
}

bcrypt_hash() {
python3 - <<'PY' "$JENKINS_ADMIN_PASSWORD"
import bcrypt, sys
print('#jbcrypt:' + bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(prefix=b'2a')).decode())
PY
}

keep_port_forward() {
    kill_old_pf
    while true; do
        kubectl -n "$NAMESPACE" port-forward svc/jenkins-local-k3d \
        "${HTTP_PORT}:8080" --address 0.0.0.0 >/dev/null 2>&1 || true
        sleep 2
    done &
}

# ═══ 2. LIMPIEZA PREVIA ══════════════════════════════════════════════════════
log "🧹 Eliminando despliegue previo (si existe)…"
helm uninstall jenkins-local-k3d -n "$NAMESPACE" --wait >/dev/null 2>&1 || true
kubectl delete all,pvc,secret,cm,svc,sts,deploy \
-l app.kubernetes.io/instance=jenkins-local-k3d \
-n "$NAMESPACE" --ignore-not-found

# ═══ 3. RENDER Y SECRETS ═════════════════════════════════════════════════════
HASH=$(bcrypt_hash)
log "👤 Usuario admin:  $JENKINS_ADMIN_USER"
log "🔑 Hash bcrypt:   $HASH"

export JENKINS_ADMIN_PASSWORD_HASH="$HASH"
envsubst < jenkins-values.template.yaml > jenkins-values.yaml

log "🔐 Creando namespace y secrets"
kubectl create ns "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" delete secret jenkins-admin dockerhub-credentials \
github-ci-token dockerhub-config --ignore-not-found

# ▸ admin (usuario + hash)
kubectl -n "$NAMESPACE" create secret generic jenkins-admin \
--from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
--from-literal=jenkins-admin-password="$HASH"

# ▸ credenciales DockerHub (username/password → plugin credentials)
kubectl -n "$NAMESPACE" create secret generic dockerhub-credentials \
--from-literal=username="$DOCKERHUB_USERNAME" \
--from-literal=password="$DOCKERHUB_TOKEN"

# ▸ GitHub PAT para GitOps
kubectl -n "$NAMESPACE" create secret generic github-ci-token \
--from-literal=token="$GITHUB_TOKEN"

# ▸ dockerhub-config (auth json para Kaniko)
mkdir -p "$HOME/.docker"
cat >"$HOME/.docker/config.json" <<EOF
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "$(echo -n "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" | base64)"
    }
  }
}
EOF
kubectl -n "$NAMESPACE" create secret generic dockerhub-config \
--from-file=config.json="$HOME/.docker/config.json" \
--dry-run=client -o yaml | kubectl apply -f -

# ═══ 4. INSTALACIÓN / UPGRADE DEL CHART ══════════════════════════════════════
log "📦 Instalando / actualizando Jenkins (Helm chart)"
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install jenkins-local-k3d jenkins/jenkins \
-n "$NAMESPACE" -f jenkins-values.yaml --timeout 10m

log "⏳ Esperando StatefulSet…"
kubectl rollout status sts/jenkins-local-k3d -n "$NAMESPACE" --timeout=600s

# ═══ 5. PORT‑FORWARD PERSISTENTE ═════════════════════════════════════════════
log "🔗 Abriendo port‑forward persistente (http://localhost:${HTTP_PORT})"
keep_port_forward

cat <<EOF

╭─────────────────────────────  Jenkins listo  ─────────────────────────────╮
│  🌐  URL          : http://localhost:${HTTP_PORT}                         │
│  👤  Usuario      : ${JENKINS_ADMIN_USER}                                 │
│  🔑  Contraseña   : (la que definiste en .env)                            │
╰───────────────────────────────────────────────────────────────────────────╯

EOF