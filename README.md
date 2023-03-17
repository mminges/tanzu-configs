k create sa tkgm-gitops-sa --namespace=packages
k create clusterrolebinding tkgm-gitops-crb --clusterrole=cluster-admin --serviceaccount=packages:tkgm-gitops-sa
