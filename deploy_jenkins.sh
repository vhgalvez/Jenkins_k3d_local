#!/bin/bash
set -euo pipefail

# 📌 Variables
NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"
VALUES_FILE="$HOME/projects/Jenkins_k3d_local/jenkins-values.yaml"
ADMIN_USER="admin"
ADMIN_PASS="123456"

# 🧹 Limpieza condicional
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
  echo "🗑️  Desinstalando release existente..."
  helm uninstall "$RELEASE" -n "$NAMESPACE"
  echo "🗑️  Eliminando PVCs y namespace..."
  kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" --ignore-not-found
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
fi

# 🧪 Verificar dependencias
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl no encontrado"; exit 1; }
command -v helm   >/dev/null 2>&1 || { echo "❌ helm no encontrado"; exit 1; }

echo "🚀 Creando namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE"

echo "🔑 (Re)Creando Secret 'jenkins-admin'..."
kubectl delete secret jenkins-admin -n "$NAMESPACE" --ignore-not-found
kubectl create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user="$ADMIN_USER" \
  --from-literal=jenkins-admin-password="$ADMIN_PASS" \
  -n "$NAMESPACE"

echo "📦 Instalando Jenkins con Helm..."
helm upgrade --install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE"

echo "⏳ Esperando a que Jenkins esté listo..."
sleep 10
if ! kubectl rollout status statefulset/"$RELEASE" -n "$NAMESPACE" --timeout=5m; then
  echo "⚠️  Error en despliegue. Logs del pod:"
  kubectl get pods -n "$NAMESPACE"
  kubectl logs -n "$NAMESPACE" pod/"$RELEASE"-0 -c jenkins || true
  exit 1
fi

echo "✅ Jenkins está UP. Pods:"
kubectl get pods -n "$NAMESPACE"

echo -e "\n🌐 Accede a Jenkins en http://localhost:8080"
echo "👤 Usuario: $ADMIN_USER"
echo "🔒 Contraseña: $ADMIN_PASS"
echo "🔁 Ctrl+C para cerrar port-forward"
kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080