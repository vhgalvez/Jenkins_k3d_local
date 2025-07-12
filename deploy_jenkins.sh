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

# Verificar que las variables están correctamente cargadas
if [[ -z "${JENKINS_ADMIN_USER:-}" || -z "${JENKINS_ADMIN_PASSWORD:-}" || -z "${DOCKERHUB_USERNAME:-}" || -z "${DOCKERHUB_TOKEN:-}" || -z "${GITHUB_TOKEN:-}" ]]; then
    echo "❌ Las variables de entorno necesarias no están definidas en el archivo .env."
    exit 1
fi

# Verificar si el hash de la contraseña está presente
if [[ -z "${JENKINS_ADMIN_PASSWORD_HASH:-}" ]]; then
    echo "🔑 Generando el hash para la contraseña..."
    
    # Generar el hash bcrypt y asegurarse de que tenga el prefijo "#jbcrypt:"
    # Usar la variable correctamente pasando la contraseña desde el entorno de bash a python
    JENKINS_ADMIN_PASSWORD_HASH=$(python3 -c "import bcrypt; password = '${JENKINS_ADMIN_PASSWORD}'; print('#jbcrypt:' + bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'))")
    
    # Validar que el hash generado tenga el formato correcto
    if [[ -z "$JENKINS_ADMIN_PASSWORD_HASH" || ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt: ]]; then
        echo "❌ Error: El hash de la contraseña no se generó correctamente o no tiene el formato esperado."
        exit 1
    fi
    
    echo "✅ Hash de la contraseña generado."
fi

# Asegurarse de que la variable de hash esté correctamente seteada
if [[ -z "$JENKINS_ADMIN_PASSWORD_HASH" ]]; then
    echo "❌ No se pudo generar el hash de la contraseña. Asegúrate de que Python esté instalado correctamente."
    exit 1
fi

NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"

# --- Función para eliminar secretos de Jenkins ---
delete_secrets() {
    echo "🗑️ Eliminando secretos de Jenkins existentes..."
    kubectl delete secret jenkins-admin -n "$NAMESPACE" || echo "🔴 No se encontró el secreto 'jenkins-admin'"
    kubectl delete secret dockerhub-credentials -n "$NAMESPACE" || echo "🔴 No se encontró el secreto 'dockerhub-credentials'"
    kubectl delete secret github-ci-token -n "$NAMESPACE" || echo "🔴 No se encontró el secreto 'github-ci-token'"
}

# --- Función para crear secrets en Kubernetes ---
create_secrets() {
    echo "🔑 (Re)Creando secretos necesarios en el namespace '$NAMESPACE'..."
    
    # Crear el secreto jenkins-admin con el usuario y la contraseña hash en Kubernetes
    kubectl create secret generic jenkins-admin \
    --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
    --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD_HASH" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Crear el secreto dockerhub-credentials
    kubectl create secret generic dockerhub-credentials \
    --from-literal=username="$DOCKERHUB_USERNAME" \
    --from-literal=password="$DOCKERHUB_TOKEN" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Crear el secreto github-ci-token
    kubectl create secret generic github-ci-token \
    --from-literal=token="$GITHUB_TOKEN" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

# 1. Eliminar Jenkins si ya está desplegado
echo "🔍 Verificando si Jenkins ya está desplegado..."
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
    echo "🗑️  Desinstalando Jenkins existente..."
    helm uninstall "$RELEASE" -n "$NAMESPACE" || true
    
    echo "🧹 Eliminando PVCs asociados..."
    kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
    
    echo "🧼 Eliminando recursos asociados..."
    kubectl delete all -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
    
    echo "⏳ Eliminando namespace '$NAMESPACE'..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    
    echo "⏳ Esperando a que el namespace se elimine completamente..."
    while kubectl get namespace "$NAMESPACE" &>/dev/null; do
        sleep 2
    done
fi

# 2. Eliminar secretos de Jenkins
delete_secrets

# 3. Crear namespace
echo "🚀 Creando namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 4. Crear Secrets
create_secrets

# 5. Añadir repositorio Helm de Jenkins si no está
if ! helm repo list | grep -qE '^jenkins\s'; then
    echo "➕ Añadiendo repositorio Helm de Jenkins..."
    helm repo add jenkins https://charts.jenkins.io
fi
helm repo update

# 6. Instalar Jenkins con Helm
echo "📦 Instalando Jenkins con Helm..."
helm upgrade --install "$RELEASE" "$CHART" \
-n "$NAMESPACE" \
--create-namespace \
-f jenkins-values.yaml \
--timeout 10m

# 7. Esperar que Jenkins esté listo
echo "⏳ Esperando a que Jenkins esté listo..."
timeout=300
elapsed=0
while [[ $elapsed -lt $timeout ]]; do
    kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=30s && break
    echo "⏳ Jenkins aún no está listo. Intentando de nuevo... ($elapsed/$timeout segundos)"
    sleep 30
    elapsed=$((elapsed + 30))
done

if [[ $elapsed -ge $timeout ]]; then
    echo "⚠️ Error en el despliegue. Logs:"
    kubectl get pods -n "$NAMESPACE"
    kubectl logs -n "$NAMESPACE" pod/"$RELEASE"-0 -c jenkins || true
    exit 1
fi

# 8. Mostrar acceso
echo "✅ Jenkins desplegado correctamente. Pods:"
kubectl get pods -n "$NAMESPACE"

cat <<EOF

🌐 Accede a Jenkins en tu navegador:
    http://localhost:8080

👤 Usuario:     $JENKINS_ADMIN_USER
🔒 Contraseña:  $JENKINS_ADMIN_PASSWORD_HASH  # Usamos el hash de la contraseña

(🔁 Ctrl+C para cerrar el port-forward)

EOF

kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080