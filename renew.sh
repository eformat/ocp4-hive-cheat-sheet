#!/bin/bash

LATEST_RELEASE=4.4.3
AWS_ACCESS_KEY_ID=$(echo -n <redacted> | base64)
AWS_SECRET_ACCESS_KEY=$(echo -n <redacted> | base64)
CLUSTER_BASE_DOMAIN=sandbox1559.opentlc.com

oc login -u kubeadmin -p <redacted> --server=https://api.foo.eformat.me:6443
oc project hive
oc delete $(oc get cd -o name) --wait=false
oc patch clusterdeployment hivec -n hive --type='json' -p='[{"op": "replace", "path": "/metadata/finalizers", "value":[]}]'

cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: ocp-release-${LATEST_RELEASE}-x86-64
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:${LATEST_RELEASE}-x86_64
EOF

cat <<EOF | oc apply -f -
apiVersion: v1
data:
  aws_access_key_id: ${AWS_ACCESS_KEY_ID}
  aws_secret_access_key: ${AWS_SECRET_ACCESS_KEY}
kind: Secret
metadata:
  name: hivec-aws-creds
  namespace: hive
type: Opaque
EOF

cat <<'EOF' > ${HOME}/tmp/hivec-install-config.yaml
apiVersion: v1
baseDomain: CLUSTER_BASE_DOMAIN
compute:
- name: worker
  platform:
    aws:
      type: m5a.xlarge
  replicas: 3
controlPlane:
  name: master
  platform:
    aws:
      type: m4.xlarge
metadata:
  name: hivec
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineCIDR: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16  
platform:
  aws:
    region: ap-southeast-2
pullSecret: '<redacted>'
sshKey: '<redacted>'
EOF

sed -i "s|CLUSTER_BASE_DOMAIN|${CLUSTER_BASE_DOMAIN}|" ${HOME}/tmp/hivec-install-config.yaml

oc delete secret hivec-install-config
oc create secret generic hivec-install-config --from-file=install-config.yaml=${HOME}/tmp/hivec-install-config.yaml

cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: hivec
  namespace: hive
  labels:
    environment: "dev"
  annotations:
    hive.openshift.io/try-install-once: "true"
    hive.openshift.io/try-uninstall-once: "false"  
spec:
  baseDomain: hive.example.com
  clusterName: hivec
  platform:
    aws:
      credentialsSecretRef:
        name: hivec-aws-creds
      region: ap-southeast-2
  provisioning:
    imageSetRef:
      name: ocp-release-${LATEST_RELEASE}-x86-64
    installConfigSecretRef:
      name: hivec-install-config
    sshPrivateKeySecretRef:
      name: hivec-ssh-key
EOF

stern hivec-