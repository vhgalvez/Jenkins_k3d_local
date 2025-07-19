#!/usr/bin/env bash
set -euo pipefail

# 0) Comprobaciones
for c in kubectl helm python3 envsubst; do command -v $c >/dev/null || { echo "❌ Falta $c"; exit 1; }; done
[[ -f .env ]] || { echo "❌ Falta .env"; exit 1; }
set -a; source .env; set +a

# 1) Hash bcrypt en RAM
JENKINS_ADMIN_PASSWORD_HASH=$(python3 - <<EOF
import bcrypt,os,sys; print("#jbcrypt:"+bcrypt.hashpw(os.environ['JENKINS_ADMIN_PASSWORD'].encode(),bcrypt.gensalt(prefix=b'2a')).decode())
EOF
)
[[ $JENKINS_ADMIN_PASSWORD_HASH =~ ^#jbcrypt:\$2a\$ ]] || { echo "❌ Hash inválido"; exit 1; }

# 2) Renderiza la plantilla
export JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD_HASH \
       DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN
envsubst < jenkins-values.template.yaml > jenkins-values.yaml

# 3) Namespace + Secrets
kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl delete secret jenkins-admin dockerhub-credentials github-ci-token dockerhub-config -n jenkins --ignore-not-found

kubectl -n jenkins create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD_HASH"

kubectl -n jenkins create secret generic dockerhub-credentials \
  --from-literal=username="$DOCKERHUB_USERNAME" \
  --from-literal=password="$DOCKERHUB_TOKEN"

kubectl -n jenkins create secret generic github-ci-token \
  --from-literal=token="$GITHUB_TOKEN"

# config.json para Kaniko
mkdir -p ~/.docker
echo "{\"auths\":{\"https://index.docker.io/v1/\":{\"auth\":\"$(echo -n "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" | base64)\"}}}" > ~/.docker/config.json
kubectl -n jenkins create secret generic dockerhub-config --from-file=config.json=$HOME/.docker/config.json --dry-run=client -o yaml | kubectl apply -f -

# 4) Instala/actualiza Jenkins
helm repo add jenkins https://charts.jenkins.io >/dev/null || true
helm repo update >/dev/null
helm upgrade --install jenkins-local-k3d jenkins/jenkins -n jenkins -f jenkins-values.yaml --timeout 10m

# 5) Espera Ready
kubectl rollout status statefulset/jenkins-local-k3d -n jenkins --timeout=600s
echo "✅ Jenkins listo → http://localhost:8080 (usuario ${JENKINS_ADMIN_USER})"
kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080