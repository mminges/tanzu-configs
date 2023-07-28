#!/bin/bash

kubectl create ns cert-manager

kubectl create secret tls local-ca --key certs/ca.key --cert certs/ca.crt -n cert-manager
