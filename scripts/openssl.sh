#!/bin/bash
set -euo pipefail

CERTS_DIR="../certs"
NODE_NAME="pg"
mkdir -p \
  "${CERTS_DIR}/ca" \
  "${CERTS_DIR}/postgres" \
  "${CERTS_DIR}/etcd" \
  "${CERTS_DIR}/patroni" \
  "${CERTS_DIR}/dcs-client" \
  "${CERTS_DIR}/minio"

openssl genrsa \
  -out "${CERTS_DIR}/ca/ca.key" \
  2048

openssl req -x509 -new -nodes \
  -key "${CERTS_DIR}/ca/ca.key" \
  -subj "/CN=test-ca" \
  -days 7300 \
  -out "${CERTS_DIR}/ca/ca.crt"

for name in pgsrv-${NODE_NAME} etcd-${NODE_NAME} patroni-${NODE_NAME} dcsclient-${NODE_NAME} minio; do
  case "$name" in
    "pgsrv-${NODE_NAME}")
      eku="serverAuth"
      cert_dir="${CERTS_DIR}/postgres"
      ;;
    "etcd-${NODE_NAME}")
      eku="serverAuth,clientAuth"
      cert_dir="${CERTS_DIR}/etcd"
      ;;
    "patroni-${NODE_NAME}")
      eku="serverAuth,clientAuth"
      cert_dir="${CERTS_DIR}/patroni"
      ;;
    "dcsclient-${NODE_NAME}")
      eku="clientAuth"
      cert_dir="${CERTS_DIR}/dcs-client"
      ;;
    "minio")
      eku="serverAuth"
      cert_dir="${CERTS_DIR}/minio"
      ;;
  esac

  for i in {1..4}; do
    openssl genrsa \
      -out "${cert_dir}/${name}${i}.key" \
      2048

    if [[ "$name" == "dcsclient-${NODE_NAME}" ]]; then
      cn="pg${i}-dcs-client"
      dns="pg${i}.client"
    elif [[ "$name" == "minio" ]]; then
      cn="minio"
      dns="minio"
    else
      cn="pg${i}"
      dns="pg${i}"
    fi
    if [[ "$i" == 4 ]]; then
      ip="192.168.172.140"
    else
      ip="192.168.172.10${i}"
    fi

    if [[ "$name" == "minio" && "$i" != 4 ]]; then
      continue
    fi

    cat > "${CERTS_DIR}/temp.cnf" <<EOF
[ req ]
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_req

[ req_distinguished_name ]
C = PL
ST = State
L = City
O = corp
OU = DevOps
CN = ${cn}

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = ${eku}
subjectAltName = @alt_names

[ alt_names ]
IP.1 = ${ip}
IP.2 = 127.0.0.1
DNS.1 = ${dns}
DNS.2 = localhost
EOF

    openssl req -new \
      -key "${cert_dir}/${name}${i}.key" \
      -out "${cert_dir}/${name}${i}.csr" \
      -config "${CERTS_DIR}/temp.cnf"

    openssl x509 -req \
      -in "${cert_dir}/${name}${i}.csr" \
      -CA "${CERTS_DIR}/ca/ca.crt" \
      -CAkey "${CERTS_DIR}/ca/ca.key" \
      -CAcreateserial \
      -out "${cert_dir}/${name}${i}.crt" \
      -days 7300 \
      -sha256 \
      -extensions v3_req \
      -extfile "${CERTS_DIR}/temp.cnf"
  done
done

rm -f "${CERTS_DIR}/temp.cnf"
