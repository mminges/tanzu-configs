```bash
k create ns packages
```
```bash
k create sa tkgm-gitops-sa --namespace=packages
```
```bash
k create clusterrolebinding tkgm-gitops-crb --clusterrole=cluster-admin --serviceaccount=packages:tkgm-gitops-sa
```
```bash
k create ns tanzu-continuousdelivery-resources
```
```bash
k apply -f gitrepository.yaml
```
```bash
k apply -f tanzu-packages-kustomization.yaml
```
