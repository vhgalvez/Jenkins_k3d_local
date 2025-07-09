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

2. Verifica que el pod esté activo:

   ```bash
   kubectl get pods -n jenkins
   ```

3. Accede al contenedor y verifica que Docker funcione:

   ```bash
   kubectl exec -it -n jenkins jenkins-0 -- bash
   docker version
   ```

## Espera a que el pod quede 2/2 Running

```bash
kubectl get pods -n jenkins -w
```

## Comprueba que Docker funciona dentro de Jenkins

```bash
kubectl exec -it -n jenkins jenkins-local-k3d-0 -- docker version
```

```bash
kubectl exec -n jenkins -it svc/jenkins-local-k3d -c jenkins -- \
 /bin/cat /run/secrets/additional/chart-admin-password && echo
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

## 🗑 Cómo eliminar por completo tu Jenkins en k3d paso a paso

Estos comandos borrarán todo lo que tenga que ver con Jenkins en tu clúster (pods, servicios, PVC/PV y el propio namespace). Ejecuta todo con un usuario que tenga permisos de administrador en el clúster.

1. Ver qué releases de Helm existen:

   ```bash
   helm list -A | grep jenkins
   ```

   Ejemplo de salida:

   ```
   NAME                NAMESPACE   REVISION    STATUS      CHART           APP VERSION
   jenkins-local-k3d  jenkins     1           deployed    jenkins-5.1.12  2.452.2
   ```

   Toma nota del NAME y NAMESPACE (en el ejemplo, jenkins-local-k3d y jenkins).

2. Desinstalar el release de Helm:

   ```bash
   helm uninstall jenkins-local-k3d -n jenkins
   ```

   Esto borra el StatefulSet, Service, ConfigMaps, Secrets, etc. creados por el chart.

3. (Opcional) Borrar el namespace completo:

   Solo si dentro del namespace jenkins no tienes otros recursos que quieras conservar.

   ```bash
   kubectl delete namespace jenkins
   ```

4. (Opcional) Eliminar volúmenes persistentes:

   Si mantuviste `persistence.enabled: true`, se habrá creado un PVC/PV con local-path. Para limpiarlo:

   ```bash
   # Buscar los PVC que aún existan
   kubectl get pvc -A | grep jenkins

   # Ejemplo de salida
   # jenkins jenkins-local-k3d Bound pvc-xyz123 4Gi RWO local-path 2d

   # Borrar el PVC y su PV asociado
   kubectl delete pvc jenkins-local-k3d -n jenkins
   ```

   El PV local-path asociado se eliminará automáticamente. Si ya eliminaste el namespace, los PVC/PV del mismo namespace se eliminan de forma automática.

5. Verificar que no queda nada:

   ```bash
   helm list -A | grep jenkins # → debería no mostrar nada
   kubectl get pods -A | grep jenkins # → sin resultados
   kubectl get pv | grep jenkins # → sin resultados
   ```

6. Detén cualquier port-forward que tengas abierto (Ctrl-C en la terminal).

7. Instala de nuevo con el YAML corregido:

   ```bash
   helm upgrade --install jenkins-local-k3d jenkins/jenkins \
     -n jenkins --create-namespace \
     -f jenkins-values.yaml
   ```

8. Sigue el log del pod hasta que pase a Running:

   ```bash
   kubectl get pods -n jenkins -w
   ```

## 📜 Licencia

MIT © [https://github.com/vhgalvez]


helm uninstall jenkins-local-k3d -n jenkins
kubectl delete pvc --all -n jenkins
kubectl delete ns jenkins
kubectl get ns
kubectl get pods -n jenkins -w
kubectl get pvc -n jenkins


Puedes hacerlo todo en un solo comando seguro:

```bash

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
kubectl -n jenkins create secret generic jenkins-admin \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password='123456'
  
```
  

```bash
helm upgrade --install jenkins-local-k3d jenkins/jenkins \
  -n jenkins --create-namespace \
  -f jenkins-values.yaml

```


🌐 Cómo acceder a Jenkins (web UI)
🧩 Opción A – Usando port-forward (rápido y fácil)
Ejecuta este comando:

```bash
kubectl port-forward -n jenkins svc/jenkins-local-k3d 8080:8080
```

Luego abre tu navegador en:



```arduino
http://localhost:8080
bash
Copiar
Editar
kubectl port-forward -n jenkins svc/jenkins-local-k3d 8080:8080
Luego abre tu navegador en:

arduino
Copiar
Editar
http://localhost:8080
Inicia sesión con las credenciales definidas:

makefile
Copiar
Editar
Usuario: admin
Contraseña: admin
⚠️ Cambia estas credenciales en producción.

🧩 Opción B – Usando NodePort (si estás en K3d o Minikube)
Verifica la IP de tu clúster (si usas K3d):

bash
Copiar
Editar
docker inspect k3d-yourclustername-server-0 | grep "IPAddress"
O usa esta IP local: 127.0.0.1

Abre tu navegador en:

cpp
Copiar
Editar
http://127.0.0.1:32000
(32000 es el nodePort que definiste en jenkins-values.yaml)

Inicia sesión con admin / admin.

🗝️ Cómo obtener la contraseña del administrador si la hubieras generado aleatoriamente
bash
Copiar
Editar
kubectl exec -n jenkins svc/jenkins-local-k3d -c jenkins -- \
  cat /run/secrets/additional/chart-admin-password
✅ Verifica que Docker funciona dentro de Jenkins
Para confirmar que Docker está listo para usar dentro del contenedor Jenkins (gracias a DinD):

bash
Copiar
Editar
kubectl exec -it -n jenkins jenkins-local-k3d-0 -- docker version





helm upgrade --install jenkins-local-k3d jenkins/jenkins \
  -n jenkins --create-namespace \
  -f ~/projects/Jenkins_k3d_local/jenkins-values.yaml
