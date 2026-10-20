# Deploy and tear down cluster-01 on the management cluster (current kubectl context).
#
#   make up       images -> namespace -> calico -> cluster -> wait until Available
#   make down     delete the Cluster, wait for its machines to go, then the rest
#   make render   print exactly what `make cluster` applies
#   make dry-run  server-side dry run of everything `make up` applies
#   make status   cluster, machines and disks
#   make kubeconfig  write the workload cluster's admin kubeconfig to $(CLUSTER).kubeconfig
#   make pods     kubectl get po -A in the workload cluster
#   make nodes    kubectl get nodes in the workload cluster

CLUSTER := cluster-01
# Workload cluster credentials (cluster-admin); gitignored, mode 0600.
WORKLOAD_KUBECONFIG := $(CLUSTER).kubeconfig

KUBECTL ?= kubectl
# Disk image the machine templates clone, read from their source.pvc.name in
# the rendered manifest; manifest/images/$(IMAGE).yaml must define it.
IMAGES = $(shell $(KUBECTL) kustomize manifest/$(CLUSTER) | awk '/^ +pvc:$$/{getline; if ($$1=="name:") print $$2}' | sort -u)
IMAGE = $(IMAGES)
# Full resource name: the "cluster"/"kcp" short names can match other CRDs here.
CAPI_CLUSTER := clusters.cluster.x-k8s.io/$(CLUSTER)

.PHONY: up down check-image images namespace calico cluster wait render dry-run status kubeconfig pods nodes

up: images namespace calico cluster wait

# Fail early if the templates and manifest/images disagree.
check-image:
	@test "$(words $(IMAGES))" = 1 || { echo "expected one source.pvc image in manifest/$(CLUSTER), found: '$(IMAGES)'" >&2; exit 1; }
	@test -f manifest/images/$(IMAGE).yaml || { echo "manifest/images/$(IMAGE).yaml not found" >&2; exit 1; }
	@grep -q '^  name: $(IMAGE)$$' manifest/images/$(IMAGE).yaml || { echo "manifest/images/$(IMAGE).yaml does not define DataVolume $(IMAGE)" >&2; exit 1; }
	@echo "image: $(IMAGE)"

images: check-image
	$(KUBECTL) apply -f manifest/images/capk-images.yaml
	$(KUBECTL) apply -f manifest/images/$(IMAGE).yaml
	$(KUBECTL) wait dv/$(IMAGE) -n capk-images --for=condition=Ready --timeout=20m

# Not in the manifests: Calico's ConfigMap/CRS and the cluster live in it.
namespace:
	$(KUBECTL) create namespace $(CLUSTER) --dry-run=client -o yaml | $(KUBECTL) apply -f -

# Before the cluster, so the CRS installs the current Calico on first boot.
# Server-side: the Calico ConfigMap exceeds the client-side apply limit.
calico:
	$(KUBECTL) apply --server-side -k manifest/$(CLUSTER)/calico

cluster:
	$(KUBECTL) apply -k manifest/$(CLUSTER)

wait:
	$(KUBECTL) wait $(CAPI_CLUSTER) -n $(CLUSTER) --for=condition=Available --timeout=20m

# Delete the Cluster first and let Cluster API remove machines and VMs, then
# the templates and the clone RoleBinding. Images, Calico and the namespace stay.
down:
	$(KUBECTL) delete $(CAPI_CLUSTER) -n $(CLUSTER) --ignore-not-found --timeout=15m
	$(KUBECTL) delete -k manifest/$(CLUSTER) --ignore-not-found

render:
	@$(KUBECTL) kustomize manifest/$(CLUSTER)

dry-run: check-image
	$(KUBECTL) apply --dry-run=server -f manifest/images/capk-images.yaml
	$(KUBECTL) apply --dry-run=server -f manifest/images/$(IMAGE).yaml
	$(KUBECTL) apply --dry-run=server --server-side -k manifest/$(CLUSTER)/calico
	$(KUBECTL) apply --dry-run=server -k manifest/$(CLUSTER)

status:
	@$(KUBECTL) get $(CAPI_CLUSTER) -n $(CLUSTER)
	@$(KUBECTL) get machines.cluster.x-k8s.io -n $(CLUSTER)
	@$(KUBECTL) get dv -n $(CLUSTER)

# Refreshed on every run: each rebuild issues a new CA and credentials.
# The API endpoint is a ClusterIP, so this only works where that is reachable.
kubeconfig:
	@umask 077; data=$$($(KUBECTL) get secret $(CLUSTER)-kubeconfig -n $(CLUSTER) -o jsonpath='{.data.value}') \
		&& echo "$$data" | base64 -d > $(WORKLOAD_KUBECONFIG) \
		&& echo "wrote $(WORKLOAD_KUBECONFIG)"

pods: kubeconfig
	$(KUBECTL) --kubeconfig $(WORKLOAD_KUBECONFIG) get po -A

nodes: kubeconfig
	$(KUBECTL) --kubeconfig $(WORKLOAD_KUBECONFIG) get nodes
