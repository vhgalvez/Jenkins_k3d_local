# Jenkins Helm values – plantilla para envsubst
# Corregido para garantizar la compatibilidad de plugins.
controller:
# Sección para instalar plugins específicos, evitando incompatibilidades.
# Estas versiones son conocidas por funcionar bien juntas.
installPlugins:
- kubernetes:4206.v2211_9329_d95c
- configuration-as-code:1889.v119b_9323d453
- workflow-aggregator:596.v802b_b_4fd69b_b
- git:5.2.2
- job-dsl:1.87

image:
# Usar una versión LTS (Long-Term Support) es generalmente más estable para producción.
# Si prefieres la última semanal, 2.518-jdk21 está bien, pero LTS es recomendado.
repository: jenkins/jenkins
tag: "2.452.2-jdk17"

admin:
# Usa el secreto que creamos para las credenciales de admin
existingSecret: jenkins-admin
userKey: jenkins-admin-user
passwordKey: jenkins-admin-password

# Variables de entorno que estarán disponibles en el contenedor de Jenkins
containerEnv:
- name: DOCKERHUB_USERNAME
value: "${DOCKERHUB_USERNAME}"
- name: GITHUB_TOKEN
value: "${GITHUB_TOKEN}"

# Configuración de Jenkins Configuration as Code (JCasC)
JCasC:
enabled: true
defaultConfig: false # Usamos nuestra propia configuración
configScripts:
main: |
jenkins:
systemMessage: "🚀 Jenkins sobre K3s – DevOps Ready | Corregido por Asistente de Programación"
securityRealm:
local:
allowsSignup: false
users:
- id: "${JENKINS_ADMIN_USER}"
# Las comillas simples son cruciales aquí porque el hash bcrypt contiene '$'
password: '${JENKINS_ADMIN_PASSWORD_HASH}'
authorizationStrategy:
loggedInUsersCanDoAnything:
allowAnonymousRead: false
clouds:
- kubernetes:
name: "kubernetes"
serverUrl: "https://kubernetes.default"
skipTlsVerify: true
namespace: "jenkins"
jenkinsUrl: "http://jenkins-local-k3d:8080"
jenkinsTunnel: "jenkins-local-k3d-agent:50000"
containerCap: 10
templates:
- name: default-agent
label: default
idleMinutes: 1
containers:
- name: jnlp
image: jenkins/inbound-agent:3206.vb_15dcf73f6a_9-2
args: '${computer.jnlpmac} ${computer.name}'
- name: nodejs
image: node:18-alpine
command: "cat"
ttyEnabled: true
- name: kaniko
# Usamos una imagen de Kaniko más reciente
image: gcr.io/kaniko-project/executor:v1.12.1-debug
command: "/busybox/cat"
ttyEnabled: true
# Montar el secreto de Docker como un volumen para Kaniko
volumeMounts:
- name: dockerhub-config-vol
mountPath: /kaniko/.docker
readOnly: true
# La sintaxis de volúmenes es correcta. El problema era la versión de los plugins.
volumes:
- secretVolume:
secretName: dockerhub-config
mountPath: /kaniko/.docker
# El nombre del volumen debe ser consistente con el volumeMounts
volumeName: dockerhub-config-vol

credentials:
system:
domainCredentials:
- credentials:
- usernamePassword:
id: "dockerhub-credentials"
scope: GLOBAL
username: "${DOCKERHUB_USERNAME}"
password: "${DOCKERHUB_TOKEN}"
description: "Credenciales de DockerHub"
- string:
id: "github-ci-token"
scope: GLOBAL
secret: "${GITHUB_TOKEN}"
description: "Token de GitHub para CI"

persistence:
enabled: true
storageClass: "local-path" # Asegúrate que este StorageClass exista en tu clúster k3d/k3s
size: 8Gi

# Port‑forward en background
kubectl -n jenkins port-forward svc/jenkins-local-k3d 8080:8080 >/dev/null 2>&1 &
echo "🔗 Port‑forward activo en http://localhost:8080"
