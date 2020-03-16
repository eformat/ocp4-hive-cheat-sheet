## 🐝 OpenShift HIVE 🐝

Document links:

- https://github.com/openshift/hive/blob/master/docs/install.md
- https://github.com/openshift/hive/blob/master/docs/using-hive.md

Video Links:

How to deliver Openshift as a service (Just like Red Hat) - Jeremy Eder (Red Hat)
- https://www.youtube.com/watch?v=b_NOrGxfH5Y

OCM (to be explored further...)
```
https://github.com/openshift-online/ocm-sdk-go
http://api.openshift.com/

$ dnf copr enable ocm/tools
$ dnf install ocm-cli -y
$ ocm login ...
$ ocm cluster create --region us-west-2 my-osd-name (and soon adding something like --cloud-provider=XYZ)
```

Case Study: OpenShift Hive at Worldpay with Bernd Malmqvist & Matt Simons (Worldpay)
- https://www.youtube.com/watch?v=A8rd2WZfa1U

### Hive from scratch (developers)

Deploy deps
```
GO111MODULE=on go get github.com/golang/mock/mockgen@latest
curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin v1.23.8
```

Make hive golang binaries
```
-- hive
cd $GOPATH/src/github.com/openshift
git clone https://github.com/openshift/hive.git
cd hive
make
```

Build and Push Hive image
```
IMG=quay.io/eformat/hive:latest make buildah-push
```

Deploy hive to control OpenShift cluster
```
oc login -u <admin> -p <password> --server=https://api.foo.eformat.me:6443
DEPLOY_IMAGE=quay.io/eformat/hive:latest make deploy
```

#### Hive Configuration

In OpenShift project `hive`

Create global (or per cluster) secret
```
-- pull secret
#oc create secret generic mycluster-pull-secret --from-file=.dockerconfigjson=/path/to/pull-secret --type=kubernetes.io/dockerconfigjson --namespace hive
oc create secret generic global-pull-secret --from-file=.dockerconfigjson=$HOME/tmp/pull-secret --type=kubernetes.io/dockerconfigjson --namespace hive
```

If using a global secret for all clusters set here:
```
oc edit hiveconfig hive

spec:
  globalPullSecretRef:
    name: global-pull-secret
```

Create Image Reference to OpenShift Release
```
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: ocp-release-4.3.3-x86-64
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:4.3.3-x86_64
EOF
```

AWS credentials (see docs for other clouds)
```
cat <<EOF | oc apply -f -
apiVersion: v1
data:
  aws_access_key_id: $(echo -n REDACTED | base64)
  aws_secret_access_key: $(echo -n REDACTED | base64)
kind: Secret
metadata:
  name: hivec-aws-creds
  namespace: hive
type: Opaque
EOF
```

Create an ssh key for this cluster (using `hivec` as its name), then load it into a secret
```
ssh-keygen -f ~/.ssh/cluster-hivec-key -N ''

oc create secret generic hivec-ssh-key --from-literal=ssh-privatekey=$(echo -n $(sed 's/^/      /' /home/mike/.ssh/cluster-hivec-key) | base64 -w0) --from-literal=ssh-publickey=$(echo -n $(sed 's/^/      /' /home/mike/.ssh/cluster-hivec-key.pub) | base64 -w0) -n hive
```

Create install config (yes, the pull secret and ssh key duplicate - why ? dunno ? see docs)
```
cat <<'EOF' > hive-install-config.yaml
apiVersion: v1
baseDomain: cluster.com
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
pullSecret: '{"auths":{"cloud.openshift.com" ... REDACTED'
sshKey: 'ssh-rsa AAA ... REDACTED'
EOF
```

Create secret
```
oc create secret generic hivec-install-config --from-file=install-config.yaml=./hive-install-config.yaml
```

This will create the Cluster
```
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
      name: ocp-release-4.3.3-x86-64
    installConfigSecretRef:
      name: hivec-install-config
    sshPrivateKeySecretRef:
      name: hivec-ssh-key
EOF
```

Another handy ClusterDeployment annotation:
```
  annotations:
    hive.openshift.io/delete-after: "24h"
```

Watch for errors in the cluster install pod
```
export CLUSTER_NAME=hivec
stern hivec
```

Tail install log
```
oc exec -c hive <install-pod-name> -- tail -f /tmp/openshift-install-console.log
```

Get temp kubeadmin login and URL to cluster
```
./hack/get-kubeconfig.sh ${CLUSTER_NAME} > ${CLUSTER_NAME}.kubeconfig
export KUBECONFIG=${CLUSTER_NAME}.kubeconfig
oc get nodes

oc get cd ${CLUSTER_NAME} -o jsonpath='{ .status.webConsoleURL }'
oc extract secret/$(oc get cd ${CLUSTER_NAME} -o jsonpath='{.spec.clusterMetadata.adminPasswordSecretRef.name}') --to=-
```

Delete the cluster using Hive
```
oc delete clusterdeployment hivec --wait=false
```

### Configure cluster using SyncSets

- https://github.com/openshift/hive/blob/master/docs/syncset.md

The default syncSetReapplyInterval can be overridden by specifying a string duration within the hiveconfig such as
```
oc edit hiveconfig hive -n hive
 syncSetReapplyInterval: "1h"
```
for a one hour reapply interval.

Get the `syncset-gen` go binary
```
cd $GOPATH/src/github.com/matt-simons
git clone https://github.com/eformat/syncset-gen
cd syncset-gen
make build
```

Some example SyncSets are here
- https://github.com/eformat/hive-sync-sets

```
git clone https://github.com/eformat/hive-sync-sets
cd hive-sync-sets
```
Apply them to our control cluster
```
syncset-gen view hivec-sync-set --cluster-name=hivec --resources resources/ | oc apply -n hive -f-
```

Check applied to `hivec` cluster
```
# check chronyd machine config applied via sync set
export KUBECONFIG=~/.kube/${CLUSTER_NAME}.kubeconfig
oc get mc 50-examplecorp-chrony -o yaml
```
