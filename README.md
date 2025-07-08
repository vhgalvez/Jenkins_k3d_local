
helm upgrade --install jenkins jenkins/jenkins \
  -n jenkins --create-namespace \
  -f jenkins-values.yaml


kubectl get pods -n jenkins

kubectl exec -it -n jenkins jenkins-0 -- bash

docker version
