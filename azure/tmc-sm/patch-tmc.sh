#!/bin/bash

kubectl annotate packageinstalls tanzu-mission-control -n tmc-local ext.packaging.carvel.dev/ytt-paths-from-secret-name.0=tmc-overlay-override
kubectl patch -n tmc-local --type merge pkgi tanzu-mission-control --patch '{"spec": {"paused": true}}'
kubectl patch -n tmc-local --type merge pkgi tanzu-mission-control --patch '{"spec": {"paused": false}}'
