# 🧪 Jenkins en K3d Local

Este repositorio contiene la configuración necesaria para desplegar Jenkins en un clúster Kubernetes local utilizando K3d, con soporte para construir imágenes Docker dentro de Jenkins gracias a DinD (Docker in Docker).

## 📦 Requisitos

- Helm 3
- K3d (o cualquier clúster K8s local)
- kubectl
- Git

## 📁 Archivos

- `jenkins-values.yaml`: configuración personalizada de Jenkins para ejecución local sin almacenamiento persistente.
- `README.md`: esta guía.
- `LICENSE`: MIT.

## 🚀 Instalación

1. Crear el namespace e instalar Jenkins con Helm:

    ```bash
    helm upgrade --install jenkins-local-k3d jenkins/jenkins \
      -n jenkins --create-namespace \
      -f jenkins-values.yaml
    ```




kubectl exec -n jenkins -it svc/jenkins-local-k3d -c jenkins -- \
  /bin/cat /run/secrets/additional/chart-admin-password && echo


2. Verifica que el pod esté activo:

    ```bash
    kubectl get pods -n jenkins
    ```

3. Accede al contenedor y verifica que Docker funcione:

    ```bash
    kubectl exec -it -n jenkins jenkins-0 -- bash
    docker version
    ```

## 🔐 Acceso a Jenkins

El usuario y contraseña por defecto definidos en `jenkins-values.yaml` son:

- **Usuario**: admin
- **Contraseña**: admin

Recuerda cambiar estas credenciales tras el primer acceso.

## 📦 Plugins preinstalados

- docker-workflow
- workflow-aggregator
- git
- credentials
- credentials-binding
- blueocean

## 🧪 Modo laboratorio

Este despliegue no usa almacenamiento persistente, ideal para pruebas con K3d o Minikube. Todos los datos se perderán si el pod se elimina.

## 📜 Licencia

MIT © [https://github.com/vhgalvez]




____
🗑 Cómo eliminar por completo tu Jenkins en k3d paso a paso
Estos comandos borrarán todo lo que tenga que ver con Jenkins en tu clúster (pods, servicios, PVC/PV y el propio namespace).
Ejecuta todo con un usuario que tenga permisos de administrador en el clúster.

1. Ver qué releases de Helm existen
bash
Copiar
Editar
helm list -A | grep jenkins
Ejemplo de salida:

pgsql
Copiar
Editar
NAME               NAMESPACE  REVISION  STATUS   CHART           APP VERSION
jenkins-local-k3d  jenkins    1         deployed jenkins-5.1.12  2.452.2
Toma nota del NAME y NAMESPACE (en el ejemplo, jenkins-local-k3d y jenkins).

2. Desinstalar el release de Helm
bash
Copiar
Editar
helm uninstall jenkins-local-k3d -n jenkins
Esto borra el StatefulSet, Service, ConfigMaps, Secrets, etc. creados por el chart.

3. (Opcional) Borrar el namespace completo
Solo si dentro del namespace jenkins no tienes otros recursos que quieras conservar.

bash
Copiar
Editar
kubectl delete namespace jenkins
4. (Opcional) Eliminar volúmenes persistentes
Si mantuviste persistence.enabled: true, se habrá creado un PVC/PV con local-path.
Para limpiarlo:

bash
Copiar
Editar
# Buscar los PVC que aún existan
kubectl get pvc -A | grep jenkins

# Ejemplo de salida
# jenkins  jenkins-local-k3d  Bound  pvc-xyz123  4Gi  RWO  local-path  2d

# Borrar el PVC y su PV asociado
kubectl delete pvc jenkins-local-k3d -n jenkins
# El PV local-path asociado se eliminará automáticamente
Si ya eliminaste el namespace, los PVC/PV del mismo namespace se eliminan de forma automática.

5. Verificar que no queda nada
bash
Copiar
Editar
helm list -A | grep jenkins         # → debería no mostrar nada
kubectl get pods -A | grep jenkins  # → sin resultados
kubectl get pv | grep jenkins       # → sin resultados