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

# Verificar si el hash de la contraseña está presente, si no, generarlo
if [[ -z "${JENKINS_ADMIN_PASSWORD_HASH:-}" ]]; then
    echo "🔑 Generando el hash para la contraseña..."

    # Generar el hash bcrypt SIN el prefijo "#jbcrypt:" (JCasC lo agrega automáticamente)
    JENKINS_ADMIN_PASSWORD_HASH=$(python3 -c "import bcrypt; password = '${JENKINS_ADMIN_PASSWORD}'; hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt(12)).decode('utf-8'); print(hash)")

    # Asegurarse de que el hash tenga el formato correcto
    if [[ -z "$JENKINS_ADMIN_PASSWORD_HASH" || ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^\$2b\$.+ && ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^\$2a\$.+ ]]; then
        echo "❌ Error: El hash de la contraseña no se generó correctamente o no tiene el formato esperado."
        exit 1
    fi

    echo "✅ Hash de la contraseña generado correctamente."
    echo "🔒 Hash generado: $JENKINS_ADMIN_PASSWORD_HASH"

    # Actualizar el archivo .env con el hash generado (evitar duplicados)
    if grep -q "JENKINS_ADMIN_PASSWORD_HASH=" .env; then
        # Si ya existe, reemplázalo
        echo "Reemplazando el hash de la contraseña en .env..."
        sed -i "s|JENKINS_ADMIN_PASSWORD_HASH=.*|JENKINS_ADMIN_PASSWORD_HASH=${JENKINS_ADMIN_PASSWORD_HASH}|" .env
    else
        # Si no existe, agrégalo
        echo "JENKINS_ADMIN_PASSWORD_HASH=${JENKINS_ADMIN_PASSWORD_HASH}" >> .env
    fi
else
    echo "✅ Hash de contraseña ya existe en .env"
    echo "🔒 Hash existente: $JENKINS_ADMIN_PASSWORD_HASH"

    # Verificar que el hash tenga el formato correcto (sin prefijo #jbcrypt:)
    if [[ ! "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^\$2[ab]\$.+ ]]; then
        echo "❌ Error: El hash de la contraseña no tiene el formato correcto."
        echo "Formato esperado: \$2b\$12\$..."
        echo "Formato actual: $JENKINS_ADMIN_PASSWORD_HASH"

        # Si tiene el prefijo #jbcrypt:, removerlo
        if [[ "$JENKINS_ADMIN_PASSWORD_HASH" =~ ^#jbcrypt: ]]; then
            echo "🔧 Removiendo prefijo #jbcrypt: del hash..."
            JENKINS_ADMIN_PASSWORD_HASH="${JENKINS_ADMIN_PASSWORD_HASH#'#jbcrypt:'}"
            echo "🔒 Hash corregido: $JENKINS_ADMIN_PASSWORD_HASH"

            # Actualizar el archivo .env
            sed -i "s|JENKINS_ADMIN_PASSWORD_HASH=.*|JENKINS_ADMIN_PASSWORD_HASH=${JENKINS_ADMIN_PASSWORD_HASH}|" .env
        else
            exit 1
        fi
    fi
fi

NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"

# --- Función para eliminar secretos de Jenkins ---
delete_secrets() {
    echo "🗑️ Eliminando secretos de Jenkins existentes..."
    kubectl delete secret jenkins-admin -n "$NAMESPACE" 2>/dev/null || echo "🔴 No se encontró el secreto 'jenkins-admin'"
    kubectl delete secret dockerhub-credentials -n "$NAMESPACE" 2>/dev/null || echo "🔴 No se encontró el secreto 'dockerhub-credentials'"
    kubectl delete secret github-ci-token -n "$NAMESPACE" 2>/dev/null || echo "🔴 No se encontró el secreto 'github-ci-token'"
}

# --- Función para crear secrets en Kubernetes ---
create_secrets() {
    echo "🔑 (Re)Creando secretos necesarios en el namespace '$NAMESPACE'..."

    # Crear el secreto jenkins-admin con el usuario y la contraseña hash (SIN prefijo #jbcrypt:)
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

    echo "✅ Secretos creados exitosamente"
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

    echo "⏳ Esperando a que los recursos se eliminen..."
    sleep 10
fi

# 2. Crear o recrear namespace
echo "🚀 Creando namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Eliminar y recrear secretos
delete_secrets
create_secrets

# 4. Añadir repositorio Helm de Jenkins si no está
if ! helm repo list | grep -qE '^jenkins\s'; then
    echo "➕ Añadiendo repositorio Helm de Jenkins..."
    helm repo add jenkins https://charts.jenkins.io
fi
helm repo update

# 5. Instalar Jenkins con Helm
echo "📦 Instalando Jenkins con Helm..."
helm upgrade --install "$RELEASE" "$CHART" \
-n "$NAMESPACE" \
--create-namespace \
-f jenkins-values.yaml \
--timeout 10m

# 6. Esperar que Jenkins esté listo
echo "⏳ Esperando a que Jenkins esté listo..."
timeout=600
elapsed=0
while [[ $elapsed -lt $timeout ]]; do
    if kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=30s 2>/dev/null; then
        echo "✅ Jenkins está listo!"
        break
    fi
    echo "⏳ Jenkins aún no está listo. Intentando de nuevo... ($elapsed/$timeout segundos)"
    sleep 30
    elapsed=$((elapsed + 30))
done

if [[ $elapsed -ge $timeout ]]; then
    echo "⚠️ Timeout esperando que Jenkins esté listo. Verificando estado..."
    kubectl get pods -n "$NAMESPACE"
    echo "📋 Logs de Jenkins:"
    kubectl logs -n "$NAMESPACE" "$RELEASE"-0 -c jenkins --tail=50 || true
    exit 1
fi

# 7. Mostrar acceso
echo "✅ Jenkins desplegado correctamente. Pods:"
kubectl get pods -n "$NAMESPACE"

cat <<EOF

🌐 Accede a Jenkins en tu navegador:
    http://localhost:8080

👤 Usuario:     $JENKINS_ADMIN_USER
🔒 Contraseña:  $JENKINS_ADMIN_PASSWORD

📝 Nota: La contraseña se almacena como hash bcrypt en Kubernetes
🔑 Hash (sin prefijo): $JENKINS_ADMIN_PASSWORD_HASH

(🔁 Ctrl+C para cerrar el port-forward)

EOF

echo "🔗 Iniciando port-forward..."
kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080