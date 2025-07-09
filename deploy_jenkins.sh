#!/bin/bash

set -euo pipefail

# 📌 Variables
NAMESPACE="jenkins"
RELEASE="jenkins-local-k3d"
CHART="jenkins/jenkins"
VALUES_FILE="$HOME/projects/Jenkins_k3d_local/jenkins-values.yaml"
ADMIN_USER="admin"
ADMIN_PASS="123456"

# 🧪 Verificar dependencias
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl no está instalado."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "❌ helm no está instalado."; exit 1; }

echo "📦 Verificando si Jenkins ya está instalado..."
if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "🧼 Eliminando despliegue anterior de Jenkins..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" || true
  kubectl delete pvc -l app.kubernetes.io/instance="$RELEASE" -n "$NAMESPACE" || true
  kubectl delete secret jenkins-admin -n "$NAMESPACE" --ignore-not-found || true
  echo "⏳ Esperando a que se eliminen los recursos..."
  sleep 5
else
  echo "📦 Jenkins no estaba instalado, se procederá a instalarlo desde cero."
fi

echo "🚀 Creando namespace '$NAMESPACE' si no existe..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

echo "🔑 Creando Secret 'jenkins-admin'..."
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
  echo "⚠️  Jenkins no se desplegó correctamente. Revisa los logs:"
  kubectl get pods -n "$NAMESPACE"
  echo "📜 Logs:"
  kubectl logs -n "$NAMESPACE" pod/"$RELEASE"-0 || true
  exit 1
fi

echo "✅ Jenkins desplegado correctamente. Pods:"
kubectl get pods -n "$NAMESPACE"

echo -e "\n🌐 Accede a Jenkins en: http://localhost:8080"
echo "👤 Usuario: $ADMIN_USER"
echo "🔒 Contraseña: $ADMIN_PASS"
echo -e "🔁 Presiona Ctrl+C para cerrar el port-forward\n"

kubectl port-forward -n "$NAMESPACE" svc/"$RELEASE" 8080:8080