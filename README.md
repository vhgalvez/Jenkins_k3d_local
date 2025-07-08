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
