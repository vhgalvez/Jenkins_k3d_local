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

NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"
VALUES_FILE="$HOME/projects/Jenkins_k3d_local/jenkins-values.yaml"

# 1. Eliminar Jenkins si existe
echo "🔍 Verificando si Jenkins ya está desplegado..."
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
    echo "🗑️  Desinstalando Jenkins existente..."
    helm uninstall "$RELEASE" -n "$NAMESPACE" || true
    
    echo "🧹 Eliminando PVCs asociados..."
    kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
    
    echo "🧼 Eliminando namespace '$NAMESPACE'..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    
    echo "⏳ Esperando a que el namespace se elimine completamente..."
    while kubectl get namespace "$NAMESPACE" &>/dev/null; do
        sleep 2
    done
fi

# 2. Crear namespace
echo "🚀 Creando namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Crear Secrets
echo "🔑 (Re)Creando secretos necesarios..."
kubectl create secret generic jenkins-admin \
--from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
--from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD" \
-n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic dockerhub-credentials \
--from-literal=username="$DOCKERHUB_USERNAME" \
--from-literal=password="$DOCKERHUB_TOKEN" \
-n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic github-ci-token \
--from-literal=username="$GITHUB_USERNAME" \
--from-literal=token="$GITHUB_TOKEN" \
-n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 4. Asegurar repositorio Helm de Jenkins
if ! helm repo list | grep -qE '^jenkins\s'; then
    echo "➕ Añadiendo repositorio Helm de Jenkins..."
    helm repo add jenkins https://charts.jenkins.io
fi
helm repo update

# 5. Instalar Jenkins
echo "📦 Instalando Jenkins con Helm..."
helm upgrade --install "$RELEASE" "$CHART" \
-n "$NAMESPACE" \
-f "$VALUES_FILE"

# 6. Esperar que Jenkins esté listo
echo "⏳ Esperando rollout de Jenkins..."
sleep 10
if ! kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=5m; then
    echo "⚠️  Error en el despliegue. Logs:"
    kubectl get pods -n "$NAMESPACE"
    kubectl logs -n "$NAMESPACE" pod/"$RELEASE"-0 -c jenkins || true
    exit 1
fi

# 7. Mostrar acceso y abrir port-forward
echo "✅ Jenkins desplegado correctamente. Pods:"
kubectl get pods -n "$NAMESPACE"

cat <<EOF

🌐 Accede a Jenkins en tu navegador:
    http://localhost:8080

👤 Usuario:     $JENKINS_ADMIN_USER
🔒 Contraseña:  $JENKINS_ADMIN_PASSWORD

(🔁 Ctrl+C para cerrar el port-forward)

EOF

kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080