################################################
# Env vars for Terraform
################################################
# Secrets
export TF_VAR_SPN_CLIENT_ID=$spnClientId
export TF_VAR_SPN_CLIENT_SECRET=$spnClientSecret
export TF_VAR_SPN_TENANT_ID=$spnTenantId
export TF_VAR_SPN_SUBSCRIPTION_ID=$subscriptionId

# Module specific
export TF_VAR_resource_group_name='raki-csi-test-rg'
export TF_VAR_aks_name='aks-csi'

# ---------------------
# DEPLOY TERRAFORM
# ---------------------
cd terraform
terraform init
terraform plan 
terraform apply -auto-approve

# ---------------------
# DESTROY ENVIRONMENT
# ---------------------
# terraform destory

################################################
# Azure and AKS login
################################################

# Login to Azure
az login --service-principal -u $spnClientId -p $spnClientSecret --tenant $spnTenantId

# Login to AKS
az account set --subscription $subscriptionId
az aks get-credentials --resource-group $TF_VAR_resource_group_name --name $TF_VAR_aks_name

################################################
# Helm Charts for Vault
################################################
# Add helm chart
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# View charts
helm search repo vault --versions

# Install with Web UI and CSI and dev mode
helm install vault hashicorp/vault \
  --set "server.dev.enabled=true" \
  --set 'ui.enabled=true' \
  --set 'ui.serviceType=LoadBalancer' \
  --set "injector.enabled=true" \
  --set "csi.enabled=true"

# Get vault status
kubectl exec vault-0 -- vault status
# Key             Value
# ---             -----
# Seal Type       shamir
# Initialized     true
# Sealed          false
# Total Shares    1
# Threshold       1
# Version         1.9.2
# Storage Type    inmem
# Cluster Name    vault-cluster-d0793417
# Cluster ID      42baab71-4be2-01de-ff77-d945be6e6207
# HA Enabled      false

# Create token
# https://learn.hashicorp.com/tutorials/vault/getting-started-authentication
kubectl exec vault-0 -- vault token create
# Key                  Value
# ---                  -----
# token                s.Fp9igF8vEbMkfEypkoE4CPjq
# token_accessor       vntMP5yX9yyYmggl7tuYE4lR
# token_duration       ∞
# token_renewable      false
# token_policies       ["root"]
# identity_policies    []
# policies             ["root"]

# Get load balancer IP
kubectl get service vault-ui
# NAME       TYPE           CLUSTER-IP   EXTERNAL-IP     PORT(S)          AGE
# vault-ui   LoadBalancer   10.0.5.49    20.102.22.165   8200:32153/TCP   41s
# http://20.102.22.165:8200/

################################################
# Helm Charts for Vault pod and K8s auth
################################################
# Create secret in Vault
kubectl exec -it vault-0 -- /bin/sh
# >
# Create secret for demo
vault login s.Fp9igF8vEbMkfEypkoE4CPjq
vault kv put secret/db-pass-vault password="ThisIsHashicorp"
vault kv get secret/db-pass-vault
# Configure K8s authentication
vault auth enable kubernetes
vault write auth/kubernetes/config \
    issuer="https://kubernetes.default.svc.cluster.local" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# echo $KUBERNETES_PORT_443_TCP_ADDR is an env variable in pod
# cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt shows the file containing the secret

# Policy for CSI driver
vault policy write internal-app - <<EOF
path "secret/data/db-pass-vault" {
  capabilities = ["read"]
}
EOF

# Create a Kubernetes authentication role named database that binds this policy with a Kubernetes service account named "webapp-sa".
vault write auth/kubernetes/role/database \
    bound_service_account_names=webapp-sa \
    bound_service_account_namespaces=default \
    policies=internal-app \
    ttl=20m

# The role connects the Kubernetes service account: webapp-sa, 
# In the namespace: default,
# With the Vault policy: internal-app. 
# The tokens returned after authentication are valid for 20 minutes. 
# This Kubernetes service account name, webapp-sa, will be created below.

exit # exit from vault container

################################################
# Install Secrets Store CSI drivers
################################################
# Helm repo settings: https://github.com/kubernetes-sigs/secrets-store-csi-driver/tree/main/charts/secrets-store-csi-driver#configuration

# To clean install:
kubectl delete -f pod.yaml --grace-period=0 --force
kubectl delete -f spc-vault-database.yaml
kubectl delete crd secretproviderclasses.secrets-store.csi.x-k8s.io
kubectl delete crd secretproviderclasspodstatuses.secrets-store.csi.x-k8s.io
helm uninstall csi
helm repo remove csi-secrets-store-provider-azure

#⭐ The Azure managed Helm chart is used on purpose, the other ones don't work with auto rotation for some reason - maybe because we keep ours up to date
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts

# Install helm charts with 
# 1. Auto rotation: https://secrets-store-csi-driver.sigs.k8s.io/topics/secret-auto-rotation.html?highlight=enableSecretRotation#enable-auto-rotation
# 2. Auto rotation poll interval = 5s

helm install csi csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
            --set secrets-store-csi-driver.enableSecretRotation=true \
            --set secrets-store-csi-driver.rotationPollInterval=5s

# This runs as a daemonset
# pod/csi-csi-secrets-store-provider-azure-9xvd7   1/1     Running   0          47s
# pod/secrets-store-csi-driver-2mxbx               3/3     Running   0          47s

################################################
# Create a SecretProviderClass: Vault
################################################
cd kubernetes/vault

cat > spc-vault-database.yaml <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-database
spec:
  provider: vault
  parameters:
    vaultAddress: "http://vault.default:8200"
    roleName: "database"
    objects: |
      - objectName: "db-pass-vault"
        secretPath: "secret/data/db-pass-vault"
        secretKey: "password"
EOF

# Note that it will be vault.default because it's hitting the "vault" k8s service in default namespace
kubectl apply -f spc-vault-database.yaml

# Check
kubectl get SecretProviderClass

# Interesting! We can sync to other secret stores via the CRD indepentently - we will try AKV identically below.

################################################
# Create a pod with secret mounted
################################################
# Service account to pull from vault
kubectl create serviceaccount webapp-sa

# Pod
cat > pod.yaml <<EOF
kind: Pod
apiVersion: v1
metadata:
  name: busybox-vault
spec:
  serviceAccountName: webapp-sa # This is the service account we created earlier that has permissions to Vault
  containers:
  - name: busybox
    image: k8s.gcr.io/e2e-test-images/busybox:1.29
    command:
      - "/bin/sleep"
      - "10000"
    volumeMounts:
    - name: secrets-store-inline
      mountPath: "/mnt/secrets-store"
      readOnly: true
  volumes:
    - name: secrets-store-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: "vault-database"
EOF

# Create the pod
kubectl apply -f pod.yaml

# Read secret from pod
kubectl exec busybox-vault -- cat /mnt/secrets-store/db-pass-vault
# ThisIsHashicorp

################################################
# Secret version
################################################
# Get Secret Version 1
kubectl get secretproviderclasspodstatus busybox-vault-default-vault-database -o yaml
# apiVersion: secrets-store.csi.x-k8s.io/v1
# kind: SecretProviderClassPodStatus
# metadata:
#   creationTimestamp: "2022-02-22T01:36:29Z"
#   generation: 1
#   labels:
#     internal.secrets-store.csi.k8s.io/node-name: aks-agentpool-58140103-vmss000000
#   name: busybox-vault-default-vault-database
#   namespace: default
#   ownerReferences:
#   - apiVersion: v1
#     kind: Pod
#     name: busybox-vault
#     uid: 212d7b8b-55ce-42e3-9ea2-95219c576a7d
#   resourceVersion: "14204"
#   uid: 3e5b1cc8-109d-44c2-bddd-532570d8de79
# status:
#   mounted: true
#   objects:
#   - id: 'db-pass-vault:secret/data/db-pass-vault:'
#     version: "0"
#   podName: busybox-vault
#   secretProviderClassName: vault-database
#   targetPath: /var/lib/kubelet/pods/212d7b8b-55ce-42e3-9ea2-95219c576a7d/volumes/kubernetes.io~csi/secrets-store-inline/mount

# Update secret in Vault Pod
kubectl exec -it vault-0 -- /bin/sh
# >
# Update secret
vault login s.Fp9igF8vEbMkfEypkoE4CPjq
vault kv put secret/db-pass-vault password="ThisIsHashicorp2"
# vault kv get secret/db-pass-vault
# ======= Metadata =======
# Key                Value
# ---                -----
# created_time       2022-02-22T01:42:01.74593273Z
# custom_metadata    <nil>
# deletion_time      n/a
# destroyed          false
# version            2             <-- Updated

# ====== Data ======
# Key         Value
# ---         -----
# password    ThisIsHashicorp2

# Read secret from pod
kubectl exec busybox-vault -- cat /mnt/secrets-store/db-pass-vault
# ThisIsHashicorp2

# Get Secret Version 2
kubectl get secretproviderclasspodstatus busybox-vault-default-vault-database -o yaml
# apiVersion: secrets-store.csi.x-k8s.io/v1
# kind: SecretProviderClassPodStatus
# metadata:
#   creationTimestamp: "2022-02-22T01:36:29Z"
#   generation: 1
#   labels:
#     internal.secrets-store.csi.k8s.io/node-name: aks-agentpool-58140103-vmss000000
#   name: busybox-vault-default-vault-database
#   namespace: default
#   ownerReferences:
#   - apiVersion: v1
#     kind: Pod
#     name: busybox-vault
#     uid: 212d7b8b-55ce-42e3-9ea2-95219c576a7d
#   resourceVersion: "14204"
#   uid: 3e5b1cc8-109d-44c2-bddd-532570d8de79
# status:
#   mounted: true
#   objects:
#   - id: 'db-pass-vault:secret/data/db-pass-vault:'
#     version: "0"
#   podName: busybox-vault
#   secretProviderClassName: vault-database
#   targetPath: /var/lib/kubelet/pods/212d7b8b-55ce-42e3-9ea2-95219c576a7d/volumes/kubernetes.io~csi/secrets-store-inline/mount

# Issue is being tracked here: https://github.com/hashicorp/vault-csi-provider/issues/146