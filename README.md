```bash
k create ns tanzu-fluxcd-packageinstalls
```

```bash
tanzu package install fluxcd-source-controller -p fluxcd-source-controller.tanzu.vmware.com -v 0.24.4+vmware.1-tkg.1 -n tanzu-fluxcd-packageinstalls
```

```bash
tanzu package install fluxcd-kustomize-controller -p fluxcd-kustomize-controller.tanzu.vmware.com -v 0.24.4+vmware.1-tkg.1 -n tanzu-fluxcd-packageinstalls
```

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
k create secret generic tkgm-gitops --from-file=identity=./tkg --from-file=kmown_hosts=known_hosts -n tanzu-continuousdelivery-resources
```

```bash
k apply -f gitrepository.yaml
```
```bash
k apply -f tanzu-packages-kustomization.yaml
```
