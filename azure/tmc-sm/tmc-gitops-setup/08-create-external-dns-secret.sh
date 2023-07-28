#!/bin/bash

kubectl create namespace tanzu-system-service-discovery
kubectl -n tanzu-system-service-discovery create secret generic azure-config-file --from-file=azure.json
