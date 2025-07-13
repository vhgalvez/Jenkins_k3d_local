#!/usr/bin/env bash
set -euo pipefail

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

# --- Generar hash bcrypt si no está presente ---
if [[ -z "${JENKINS_ADMIN_PASSWORD_HASH:-}" ]]; then
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

    echo "✅ Hash generado: $JENKINS_ADMIN_PASSWORD_HASH"
    # Actualizar o agregar en .env
    if grep -q "^JENKINS_ADMIN_PASSWORD_HASH=" .env; then
        sed -i.bak "s|^JENKINS_ADMIN_PASSWORD_HASH=.*|JENKINS_ADMIN_PASSWORD_HASH=${JENKINS_ADMIN_PASSWORD_HASH}|" .env
    else
        echo "JENKINS_ADMIN_PASSWORD_HASH=${JENKINS_ADMIN_PASSWORD_HASH}" >> .env
    fi
else
    echo "✅ Hash ya presente en .env"
    echo "🔒 $JENKINS_ADMIN_PASSWORD_HASH"
    if [[ ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt:\$2a\$.* ]]; then
        echo "❌ Error: Hash inválido en .env"
        exit 1
    fi
fi

# --- Variables de despliegue ---
NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"

# --- Funciones ---
delete_secrets() {
    echo "🗑️ Eliminando secretos anteriores..."
    kubectl delete secret jenkins-admin dockerhub-credentials github-ci-token -n "$NAMESPACE" --ignore-not-found
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

    echo "✅ Secretos cargados correctamente."
}

# --- Eliminar despliegue previo ---
echo "🔍 Verificando despliegue existente..."
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
    echo "🗑️ Eliminando Jenkins anterior..."
    helm uninstall "$RELEASE" -n "$NAMESPACE"
    echo "🧼 Limpiando recursos previos..."
    kubectl delete pvc,all -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
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
🧾 Hash:      $JENKINS_ADMIN_PASSWORD_HASH

(Usa Ctrl+C para detener el port-forward si lo dejas abierto)

EOF

echo "🔗 Iniciando port-forward..."
kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080