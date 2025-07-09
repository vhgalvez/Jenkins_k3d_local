#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"
VALUES_FILE="$HOME/projects/Jenkins_k3d_local/jenkins-values.yaml"
ADMIN_USER="admin"
ADMIN_PASS="123456"

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

# 3. (Re)Crear Secret
echo "🔑 Creando Secret 'jenkins-admin'..."
kubectl delete secret jenkins-admin -n "$NAMESPACE" --ignore-not-found
kubectl create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$ADMIN_USER" \
  --from-literal=jenkins-admin-password="$ADMIN_PASS" \
  -n "$NAMESPACE"

# 4. Desplegar con Helm
echo "📦 Instalando Jenkins con Helm..."
helm repo update
helm upgrade --install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE"

# 5. Esperar rollout
echo "⏳ Esperando a que Jenkins esté listo..."
sleep 10
if ! kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=5m; then
  echo "⚠️  Error en despliegue. Logs del pod:"
  kubectl get pods -n "$NAMESPACE"
  kubectl logs -n "$NAMESPACE" pod/"$RELEASE"-0 -c jenkins || true
  exit 1
fi

# 6. Mostrar info y abrir port-forward
echo "✅ Jenkins está UP. Pods:"
kubectl get pods -n "$NAMESPACE"

cat <<EOF

🌐 Abre en tu navegador:
    http://localhost:8080

👤 Usuario: $ADMIN_USER  
🔒 Contraseña: $ADMIN_PASS  

(🔁 Ctrl+C para cerrar el port-forward)

EOF

kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080