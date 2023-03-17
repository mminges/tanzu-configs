k create ns packages
k create sa tkgm-gitops-sa --namespace=packages
k create clusterrolebinding tkgm-gitops-crb --clusterrole=cluster-admin --serviceaccount=packages:tkgm-gitops-sa
k create ns tanzu-continuousdelivery-resources
k apply -f gitrepository.yaml
k apply -f tanzu-packages-kustomization.yaml
