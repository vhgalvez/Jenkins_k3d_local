#!/usr/bin/env bash
set -euo pipefail

# 0. Verificar existencia del archivo .env
if [[ ! -f .env ]]; then
    echo "❌ Archivo .env no encontrado. Crea uno con tus credenciales."
    exit 1
fi

# Cargar variables del entorno
set -a
source .env
set +a

# Verificar que las variables básicas estén correctamente cargadas
if [[ -z "${JENKINS_ADMIN_USER:-}" || -z "${JENKINS_ADMIN_PASSWORD:-}" || -z "${DOCKERHUB_USERNAME:-}" || -z "${DOCKERHUB_TOKEN:-}" || -z "${GITHUB_TOKEN:-}" ]]; then
    echo "❌ Las variables de entorno necesarias no están definidas en el archivo .env."
    echo "Variables requeridas: JENKINS_ADMIN_USER, JENKINS_ADMIN_PASSWORD, DOCKERHUB_USERNAME, DOCKERHUB_TOKEN, GITHUB_TOKEN"
    exit 1
fi

# Generar hash bcrypt con $2a$ si no existe
if [[ -z "${JENKINS_ADMIN_PASSWORD_HASH:-}" ]]; then
    echo "🔑 Generando el hash para la contraseña..."

    JENKINS_ADMIN_PASSWORD_HASH=$(python3 - <<EOF
import bcrypt, os
password = os.environ['JENKINS_ADMIN_PASSWORD'].encode()
hashed = bcrypt.hashpw(password, bcrypt.gensalt(prefix=b'2a'))
print("#jbcrypt:" + hashed.decode())
EOF
)

    # Validar formato
    if [[ ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt:\$2a\$.* ]]; then
        echo "❌ Error: Hash inválido. No cumple con formato #jbcrypt:\$2a\$"
        exit 1
    fi

    echo "✅ Hash generado correctamente."
    echo "🔒 Hash: $JENKINS_ADMIN_PASSWORD_HASH"

    # Actualizar .env
    if grep -q "JENKINS_ADMIN_PASSWORD_HASH=" .env; then
        sed -i "s|^JENKINS_ADMIN_PASSWORD_HASH=.*|JENKINS_ADMIN_PASSWORD_HASH=${JENKINS_ADMIN_PASSWORD_HASH}|" .env
    else
        echo "JENKINS_ADMIN_PASSWORD_HASH=${JENKINS_ADMIN_PASSWORD_HASH}" >> .env
    fi
else
    echo "✅ Hash ya presente en .env"
    echo "🔒 Hash existente: $JENKINS_ADMIN_PASSWORD_HASH"
    
    if [[ ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt:\$2a\$.* ]]; then
        echo "❌ Error: Hash inválido en .env. Debe tener prefijo #jbcrypt:\$2a\$"
        exit 1
    fi
fi

NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"

# --- Eliminar secretos anteriores ---
delete_secrets() {
    echo "🗑️ Eliminando secretos anteriores..."
    kubectl delete secret jenkins-admin -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete secret dockerhub-credentials -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete secret github-ci-token -n "$NAMESPACE" 2>/dev/null || true
}

# --- Crear secretos necesarios ---
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

    echo "✅ Secretos creados."
}

# --- Eliminar Jenkins si ya está ---
echo "🔍 Verificando despliegue previo..."
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
    echo "🗑️ Desinstalando Jenkins existente..."
    helm uninstall "$RELEASE" -n "$NAMESPACE" || true

    echo "🧼 Eliminando recursos anteriores..."
    kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
    kubectl delete all -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
    sleep 10
fi

# --- Crear namespace ---
echo "🚀 Creando namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- Cargar secretos ---
delete_secrets
create_secrets

# --- Añadir repositorio Jenkins ---
if ! helm repo list | grep -q "^jenkins"; then
    helm repo add jenkins https://charts.jenkins.io
fi
helm repo update

# --- Instalar Jenkins ---
echo "📦 Instalando Jenkins..."
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
        echo "✅ Jenkins listo."
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

# --- Mostrar información de acceso ---
echo "✅ Jenkins desplegado correctamente."
kubectl get pods -n "$NAMESPACE"

cat <<EOF

🌐 Accede a Jenkins:
  → http://localhost:8080

👤 Usuario:     $JENKINS_ADMIN_USER
🔒 Contraseña:  $JENKINS_ADMIN_PASSWORD
🧾 Hash usado:  $JENKINS_ADMIN_PASSWORD_HASH

(Usa Ctrl+C para detener el port-forward si lo inicias manualmente)

EOF

echo "🔗 Iniciando port-forward..."

kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080