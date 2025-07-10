#!/usr/bin/env bash
set -euo pipefail

# Cargar variables del entorno
set -a
source .env
set +a

NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"
VALUES_FILE="$HOME/projects/Jenkins_k3d_local/jenkins-values.yaml"

# 1. Limpieza condicional
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
  echo "🗑️  Desinstalando release existente..."
  helm uninstall "$RELEASE" -n "$NAMESPACE"
  echo "🗑️  Eliminando PVCs y namespace..."
  kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
fi

# 2. Crear namespace
echo "🚀 Creando namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE"

# 3. Crear Secret jenkins-admin
echo "🔑 Creando Secret 'jenkins-admin'..."
kubectl delete secret jenkins-admin -n "$NAMESPACE" --ignore-not-found
kubectl create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$JENKINS_ADMIN_USER" \
  --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD" \
  -n "$NAMESPACE"

# 4. Crear Secret dockerhub-credentials
echo "🐳 Creando Secret 'dockerhub-credentials'..."
kubectl delete secret dockerhub-credentials -n "$NAMESPACE" --ignore-not-found
kubectl create secret generic dockerhub-credentials \
  --from-literal=username="$DOCKERHUB_USERNAME" \
  --from-literal=password="$DOCKERHUB_TOKEN" \
  -n "$NAMESPACE"

# 5. Desplegar Jenkins con Helm
echo "📦 Instalando Jenkins con Helm..."
helm repo update
helm upgrade --install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE"

# 6. Esperar rollout
echo "⏳ Esperando a que Jenkins esté listo..."
sleep 10
if ! kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=5m; then
  echo "⚠️  Error en despliegue. Logs del pod:"
  kubectl get pods -n "$NAMESPACE"
  kubectl logs -n "$NAMESPACE" pod/"$RELEASE"-0 -c jenkins || true
  exit 1
fi

# 7. Mostrar info y abrir port-forward
echo "✅ Jenkins está UP. Pods:"
kubectl get pods -n "$NAMESPACE"

cat <<EOF

🌐 Abre en tu navegador:
    http://localhost:8080

👤 Usuario: $JENKINS_ADMIN_USER  
🔒 Contraseña: $JENKINS_ADMIN_PASSWORD  

(🔁 Ctrl+C para cerrar el port-forward)

EOF

kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080