#!/bin/bash

mkdir certs

# heredoc to create the CA config
cat <<EOF > certs/ca.cnf
[ req ]
default_bits = 4096
default_md = sha256
prompt = no
encrypt_key = no
distinguished_name = dn
[ dn ]
countryName = US
stateOrProvinceName = Colorado
localityName = Denver
organizationName = lab
organizationalUnitName = IT
commonName = tmcsmlab.io
[ ext ]
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
basicConstraints=critical,CA:true,pathlen:1
subjectAltName=DNS:tmcsmlab.io
EOF

# generate the CA cert and key
openssl req -x509 -new -nodes -newkey rsa:4096 -keyout certs/ca.key -sha256 -days 3650 -extensions ext -config certs/ca.cnf -out certs/ca.crt

# heredoc to create the harbor config for the CSR
cat <<EOF > certs/harbor.cnf
[ req ]
prompt = no
default_bits = 4096
distinguished_name = req_distinguished_name
req_extensions = req_ext

[ req_distinguished_name ]
C=US
ST=Colorado
L=Denver
O=lab
OU=IT
CN=harbor.tmcsmlab.io

[ req_ext ]
subjectAltName = @alt_names

[alt_names]
DNS.1 = harbor.tmcsmlab.io
DNS.2 = notary.tmcsmlab.io
EOF

# Generate a CSR for Harbor
openssl req -sha256 -nodes -new -newkey rsa:4096 -out certs/harbor.csr -keyout certs/harbor.key -config certs/harbor.cnf

# heredoc for SANs to be applied to harbor's csr
cat <<EOF > certs/v3.ext
subjectAltName = @alt_names
[alt_names]
DNS.1=harbor.tmcsmlab.io
DNS.2=notary.tmcsmlab.io
EOF

# Sign Harbor CSR using the CA we created
openssl x509 -req -sha256 -days 3650 -CA certs/ca.crt -CAkey certs/ca.key -extfile certs/v3.ext -in certs/harbor.csr -out certs/harbor.crt

# Verify CA signed harbor cert
openssl verify -CAfile certs/ca.crt certs/harbor.crt
