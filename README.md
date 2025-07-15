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

## 🌐 Cómo acceder a Jenkins (web UI)

### 🧩 Opción A – Usando port-forward (rápido y fácil)

Ejecuta este comando:

```bash
kubectl port-forward -n jenkins svc/jenkins-local-k3d 8080:8080
```

Luego abre tu navegador en:

```text
http://localhost:8080
```

Inicia sesión con las credenciales definidas:

- **Usuario**: admin
- **Contraseña**: admin

⚠️ Cambia estas credenciales en producción.

### 🧩 Opción B – Usando NodePort (si estás en K3d o Minikube)

Verifica la IP de tu clúster (si usas K3d):

```bash
docker inspect k3d-yourclustername-server-0 | grep "IPAddress"
```

O usa esta IP local: `127.0.0.1`

Abre tu navegador en:

```text
http://127.0.0.1:32000
```

(32000 es el nodePort que definiste en `jenkins-values.yaml`)

Inicia sesión con:

- **Usuario**: admin
- **Contraseña**: admin

### 🗝️ Cómo obtener la contraseña del administrador si la hubieras generado aleatoriamente

```bash
kubectl exec -n jenkins svc/jenkins-local-k3d -c jenkins -- \
  cat /run/secrets/additional/chart-admin-password
```


## 🗑 Cómo eliminar por completo tu Jenkins en k3d paso a paso

1. Detén cualquier port-forward que tengas abierto:

   ```bash
   Ctrl-C en la terminal
   ```

2. Ver qué releases de Helm existen:

   ```bash
   helm list -A | grep jenkins
   ```

   Ejemplo de salida:

   ```
   NAME                NAMESPACE   REVISION    STATUS      CHART           APP VERSION
   jenkins-local-k3d  jenkins     1           deployed    jenkins-5.1.12  2.452.2
   ```

   Toma nota del NAME y NAMESPACE (en el ejemplo, jenkins-local-k3d y jenkins).

3. Desinstalar el release de Helm:

   ```bash
   helm uninstall jenkins-local-k3d -n jenkins
   ```

   Esto borra el StatefulSet, Service, ConfigMaps, Secrets, etc. creados por el chart.

4. (Opcional) Borrar el namespace completo:

   Solo si dentro del namespace jenkins no tienes otros recursos que quieras conservar.

   ```bash
   kubectl delete namespace jenkins
   ```

5. (Opcional) Eliminar volúmenes persistentes:

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

6. Verificar que no queda nada:

   ```bash
   helm list -A | grep jenkins # → debería no mostrar nada
   kubectl get pods -A | grep jenkins # → sin resultados
   kubectl get pv | grep jenkins # → sin resultados
   ```

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

## 🛠 Cómo desplegar Jenkins en K3d

```bash
sudo chmod +x deploy_jenkins.sh
```

Luego ejecuta el script para desplegar Jenkins en tu clúster K3d:

```bash
./deploy_jenkins.sh
```

```bash
sudo chmod u+w .env
```



Si solo quieres desplegar los secretos necesarios para Jenkins, puedes ejecutar:

```bash
./deploy_jenkins.sh --only-secrets
```

## 📝 Cómo crear un token de acceso para Docker Hub

Para poder hacer push de imágenes a Docker Hub desde Jenkins, necesitas un token de acceso. Aquí te explico cómo crearlo de forma sencilla y rápida:

1. Inicias sesión en tu cuenta de Docker Hub (gratuita o de pago).

2. Vas a Account Settings → Security → +New Access Token.

3. Asignas un nombre y permisos (por ejemplo, Read & Write).

4. Generas el token, lo copias y lo guardas.

5. En Jenkins, vas a Manage Jenkins → Manage Credentials → (seleccionas el dominio global o el que necesites) → Add Credentials.

6. Seleccionas "Secret text" como tipo de credencial.

7. En "Secret", introduces el siguiente comando para crear el secreto en Kubernetes:

```bash
sudo nano .env
```

. env
# Jenkins Admin
JENKINS_ADMIN_USER=admin
JENKINS_ADMIN_PASSWORD=admin1234

# DockerHub Credentials
DOCKERHUB_USERNAME=vhgalvez
DOCKERHUB_TOKEN=your_dockerhub_token_here

# GitHub CI Token
GITHUB_USERNAME=vhgalvez
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

```bash
kubectl create secret generic dockerhub-credentials \
  --from-literal=username=vhgalvez \
  --from-literal=password=TU_TOKEN_DE_DOCKER_HUB \
  -n jenkins
```

Sustituye TU_TOKEN_DE_DOCKER_HUB por el token generado desde:
https://hub.docker.com/settings/security

## 📝 Cómo crear un token de acceso para GitHub

En Jenkins:

Ve a "Dashboard" > "Manage Jenkins" > "Credentials".

Selecciona el almacenamiento global (ej. (global)).

Agrega una nueva credencial de tipo:

"Username with password":

Username: tu nombre de usuario de GitHub (o un token ghp\_\*\*\* como username).

Password: un GitHub personal access token (PAT) con permisos de repo y workflow.

O mejor aún, usa tipo "Secret Text" si solo necesitas el token.

Asigna un ID como: github-ci-token


## 🔐 Generación de Hash Bcrypt Compatible con Jenkins

Jenkins **requiere** que los hashes bcrypt usen **exclusivamente** el prefijo `$2a$`. Otros como `$2b$`, `$2x$` o `$2y$` causarán errores en la configuración con JCasC:

```
IllegalArgumentException: The hashed password was hashed with the correct algorithm, but the format was not correct
```

### ✅ Buenas Prácticas:

* El hash debe comenzar con: `#jbcrypt:$2a$`
* Usar al menos 12 rondas de coste (`gensalt(12)`)
* Evitar prefijos como `$2b$`

### 🛠 Ejemplo en Python:

```python
import bcrypt
password = b"TuContraseña"
hashed = bcrypt.hashpw(password, bcrypt.gensalt(prefix=b'2a'))
print("#jbcrypt:" + hashed.decode())
```

Este hash es válido para Jenkins tanto en configuración manual como mediante Configuration as Code (JCasC).



---

## 🗝️ Cómo ver los secretos de Jenkins
Para ver los secretos creados en el namespace de Jenkins, puedes usar:

```bash
kubectl get secrets -n jenkins
```

permisos:

```bash
sudo chown $USER:$USER .env && chmod 600 .env
```


Verifica los secretos creados:

```bash
kubectl get secrets -n jenkins
```
kubectl get pods -n jenkins -w

## 📜 Licencia

MIT © [https://github.com/vhgalvez](https://github.com/vhgalvez)