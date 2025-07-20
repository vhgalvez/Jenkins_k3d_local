#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Despliega Jenkins en k3d/k3s usando el chart oficial + JCasC 
# Corregido y mejorado.
# -----------------------------------------------------------------------------
# deploy_jenkins_render.sh

set -eu # -o pipefail no es universalmente soportado en /bin/sh

# --- 0. Comprobaciones de prerrequisitos ---
echo "🔎 Verificando herramientas necesarias..."
for bin in kubectl helm python3 envsubst; do
  command -v "$bin" >/dev/null || { echo "❌ La herramienta '$bin' no se encuentra. Por favor, instálala."; exit 1; }
done
[[ -f .env ]] || { echo "❌ No se encuentra el archivo de configuración '.env'."; exit 1; }
echo "✅ Prerrequisitos cumplidos."

# --- 1. Cargar variables de entorno desde .env ---
set -a
source .env
set +a

# Validar que las variables necesarias no estén vacías
for v in JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN; do
  [[ -z "${!v:-}" ]] && { echo "❌ La variable '$v' está vacía en el archivo .env."; exit 1; }
done
echo "✅ Variables de entorno cargadas."

# --- 2. Generar Hash BCrypt para la contraseña (en memoria) ---
echo "🔐 Generando hash bcrypt para la contraseña del administrador..."
JENKINS_ADMIN_PASSWORD_HASH="$(
  python3 - <<'PY'
import bcrypt, os, sys
try:
    password = os.environ['JENKINS_ADMIN_PASSWORD'].encode('utf-8')
    salt = bcrypt.gensalt(prefix=b'2a', rounds=10)
    hashed_password = bcrypt.hashpw(password, salt)
    print('#jbcrypt:' + hashed_password.decode('utf-8'))
except Exception as e:
    print(f"Error generando hash: {e}", file=sys.stderr)
    sys.exit(1)
PY
)"

# Verificación robusta del hash
[[ $JENKINS_ADMIN_PASSWORD_HASH =~ ^#jbcrypt:\$2a\$10\$ ]] \
  || { echo "❌ Error al generar un hash bcrypt válido."; exit 1; }
echo "✅ Hash generado correctamente."

# --- 3. Renderizar jenkins-values.yaml desde la plantilla ---
export JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD_HASH \
       DOCKERHUB_USERNAME DOCKERHUB_TOKEN GITHUB_TOKEN

echo "📝 Renderizando el archivo de configuración 'jenkins-values.yaml'..."
envsubst < jenkins-values.template.yaml > jenkins-values.yaml
echo "✅ 'jenkins-values.yaml' renderizado."

# --- 4. Crear Namespace y Secrets en Kubernetes ---
echo "🔧 Preparando namespace y secrets en Kubernetes..."
kubectl create ns jenkins --dry-run=client -o yaml | kubectl apply -f -

# Borrar secretos antiguos para un despliegue limpio
for secret_name in jenkins-admin dockerhub-credentials github-ci-token dockerhub-config; do
    kubectl -n jenkins delete secret "$secret_name" --ignore-not-found=true
done

# Crear secretos
kubectl -n jenkins create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD_HASH"

kubectl -n jenkins create secret generic dockerhub-credentials \
  --from-literal=username="$DOCKERHUB_USERNAME" \
  --from-literal=password="$DOCKERHUB_TOKEN"

kubectl -n jenkins create secret generic github-ci-token \
  --from-literal=token="$GITHUB_TOKEN"

# Crear secret de config.json para Kaniko de forma segura y sin archivos temporales
DOCKER_AUTH=$(echo -n "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" | base64 | tr -d '\n')
DOCKER_CONFIG_JSON=$(printf '{"auths":{"https://index.docker.io/v1/":{"auth":"%s"}}}' "$DOCKER_AUTH")

kubectl -n jenkins create secret generic dockerhub-config \
  --from-literal=config.json="$DOCKER_CONFIG_JSON" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Namespace y secrets creados/actualizados."

# --- 5. Instalar / Actualizar Jenkins con Helm ---
echo "🚀 Desplegando Jenkins con Helm..."
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins >/dev/null

helm upgrade --install jenkins-local-k3d jenkins/jenkins \
  -n jenkins \
  -f jenkins-values.yaml \
  --timeout 10m

# --- 6. Esperar a que Jenkins esté completamente listo ---
echo "⏳ Esperando a que el pod de Jenkins esté listo (esto puede tardar varios minutos)..."
kubectl rollout status statefulset/jenkins-local-k3d -n jenkins --timeout=10m
echo "🎉 ¡El StatefulSet de Jenkins está listo!"

# --- 7. Iniciar Port-Forward y mostrar información ---
# Detener cualquier proceso de port-forward anterior en el puerto 8080
pkill -f "kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080" >/dev/null 2>&1 || true

# Iniciar nuevo port-forward en segundo plano
nohup kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080 >/dev/null 2>&1 &
PF_PID=$!
echo "🔗 Port-forward iniciado en segundo plano (PID: $PF_PID)."
echo "   Para detenerlo, ejecuta: kill $PF_PID"
sleep 2 # Dar un momento para que se establezca

cat <<EOF

✅ Despliegue de Jenkins completado.

🌐 URL de Acceso Local: http://localhost:8080
👤 Usuario:             $JENKINS_ADMIN_USER
🔑 Contraseña:          (la que definiste en tu archivo .env)

EOF

# Port‑forward en background
kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080 >/dev/null 2>&1 &
echo "🔗 Port‑forward activo en http://localhost:8080"
