################################################
# Env vars
################################################
export AKS="Arc-Data-AKS"

# Login to Azure
az login --service-principal -u $spnClientId -p $spnClientSecret --tenant $spnTenantId

# Login to AKS
az account set --subscription $subscriptionId
az aks get-credentials --resource-group "raki-arc-aks-1-rg" --name $AKS

################################################
# Helm Charts for Vault
################################################
# Add helm chart
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# View charts
helm search repo vault --versions

# Install with Web UI and CSI
helm install vault hashicorp/vault \
  --set 'ui.enabled=true' \
  --set 'ui.serviceType=LoadBalancer' \
  --set "injector.enabled=true" \
  --set "csi.enabled=true"

# Get vault status
kubectl exec vault-0 -- vault status

# Get load balancer IP
kubectl get service vault-ui
# http://40.87.23.135:8200/

################################################
# Helm Charts for Vault pod and K8s auth
################################################
# Create secret in Vault
kubectl exec -it vault-0 -- /bin/sh
#
vault login s.XbcJXPcNoOgZMqpz4a63qHeb
vault kv put secret/db-pass password="db-secret-password"
vault kv get secret/db-pass

# Configure K8s authentication
kubectl exec -it vault-0 -- /bin/sh
# 
vault login s.XbcJXPcNoOgZMqpz4a63qHeb
vault auth enable kubernetes
vault write auth/kubernetes/config \
    issuer="https://kubernetes.default.svc.cluster.local" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# echo $KUBERNETES_PORT_443_TCP_ADDR is an env variable in pod
# cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt shows the file

# Policy for CSI driver
vault policy write internal-app - <<EOF
path "secret/data/db-pass" {
  capabilities = ["read"]
}
EOF

# Create a Kubernetes authentication role named database that binds this policy with a Kubernetes service account named "webapp-sa".
vault write auth/kubernetes/role/database \
    bound_service_account_names=webapp-sa \
    bound_service_account_namespaces=default \
    policies=internal-app \
    ttl=20m

# The role connects the Kubernetes service account, webapp-sa, 
# In the namespace, default,
# With the Vault policy, internal-app. The tokens returned after authentication are valid for 20 minutes. This Kubernetes service account name, webapp-sa, will be created below.

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

#⭐ The Azure one is used on purpose, the other ones don't work with auto rotation for some reason - maybe because we keep ours up to date
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts
helm install csi csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
            --set secrets-store-csi-driver.enableSecretRotation=true \
            --set secrets-store-csi-driver.rotationPollInterval=5s

# Create with auto rotate
# default       csi-secrets-store-csi-driver-j52hr                               3/3     Running   0          28s
# default       csi-secrets-store-csi-driver-sn8xb                               3/3     Running   0          28s

################################################
# Create a SecretProviderClass
################################################
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
      - objectName: "db-password"
        secretPath: "secret/data/db-pass"
        secretKey: "password"
EOF

# Note that it will be vault.default because it's hitting the k8s service
kubectl apply -f spc-vault-database.yaml

# Check
kubectl get SecretProviderClass

# Interesting! We can sync to other secret stores via the CRD independetly - very cool!

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
  name: busybox-secrets-store-inline
spec:
  serviceAccountName: webapp-sa
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
kubectl exec busybox-secrets-store-inline -- cat /mnt/secrets-store/db-password
# db-secret-password

################################################
# Secret version
################################################
# Get Secret Version
kubectl get secretproviderclasspodstatus busybox-secrets-store-inline-default-vault-database -o yaml
# apiVersion: secrets-store.csi.x-k8s.io/v1
# kind: SecretProviderClassPodStatus
# metadata:
#   creationTimestamp: "2022-02-10T02:53:40Z"
#   generation: 1
#   labels:
#     internal.secrets-store.csi.k8s.io/node-name: aks-agentpool-21566404-vmss00003o
#   name: busybox-secrets-store-inline-default-vault-database
#   namespace: default
#   ownerReferences:
#   - apiVersion: v1
#     kind: Pod
#     name: busybox-secrets-store-inline
#     uid: c31afb1c-238d-47ed-bc57-02031e13315b
#   resourceVersion: "16170051"
#   selfLink: /apis/secrets-store.csi.x-k8s.io/v1/namespaces/default/secretproviderclasspodstatuses/busybox-secrets-store-inline-default-vault-database
#   uid: 825ce2f1-3391-41fd-886c-c7abc4b13208
# status:
#   mounted: true
#   objects:
#   - id: 'db-password:secret/data/db-pass:'
#     version: "0"
#   podName: busybox-secrets-store-inline
#   secretProviderClassName: vault-database
#   targetPath: /var/lib/kubelet/pods/c31afb1c-238d-47ed-bc57-02031e13315b/volumes/kubernetes.io~csi/secrets-store-inline/mount

# Update secret in Vault UI
# my-new-updated-password

# Read secret from pod
kubectl exec busybox-secrets-store-inline -- cat /mnt/secrets-store/db-password
# my-new-updated-password

# Get Secret Version
kubectl get secretproviderclasspodstatus busybox-secrets-store-inline-default-vault-database -o yaml
# apiVersion: secrets-store.csi.x-k8s.io/v1
# kind: SecretProviderClassPodStatus
# metadata:
#   creationTimestamp: "2022-02-10T02:53:40Z"
#   generation: 1
#   labels:
#     internal.secrets-store.csi.k8s.io/node-name: aks-agentpool-21566404-vmss00003o
#   name: busybox-secrets-store-inline-default-vault-database
#   namespace: default
#   ownerReferences:
#   - apiVersion: v1
#     kind: Pod
#     name: busybox-secrets-store-inline
#     uid: c31afb1c-238d-47ed-bc57-02031e13315b
#   resourceVersion: "16170051"
#   selfLink: /apis/secrets-store.csi.x-k8s.io/v1/namespaces/default/secretproviderclasspodstatuses/busybox-secrets-store-inline-default-vault-database
#   uid: 825ce2f1-3391-41fd-886c-c7abc4b13208
# status:
#   mounted: true
#   objects:
#   - id: 'db-password:secret/data/db-pass:'
#     version: "0"
#   podName: busybox-secrets-store-inline
#   secretProviderClassName: vault-database
#   targetPath: /var/lib/kubelet/pods/c31afb1c-238d-47ed-bc57-02031e13315b/volumes/kubernetes.io~csi/secrets-store-inline/mount

# Doesn't look like this changes?

# 🤔 Bug? https://secrets-store-csi-driver.sigs.k8s.io/topics/secret-auto-rotation.html#how-to-view-the-current-secret-versions-loaded-in-pod-mount