# kube-cluster-api

Cluster API manifests for workload clusters running as KubeVirt VMs on the
management cluster (single node, `monster`).

## Layout

```
manifest/
  images/                  shared VM disk images (namespace capk-images)
    capk-images.yaml         namespace + clone RoleBinding for capk-manager
    ubuntu-2404-v1-34-1.yaml DataVolume imported once from quay.io/capk
  cluster-01/              cluster-01, as a kustomization
    cluster-01.yaml          Cluster, control plane, workers, health check
    kubelet-config.yaml      kubelet patch shared by all nodes
    kustomization.yaml       fills placeholders in cluster-01.yaml
    calico/                  Calico via ClusterResourceSet; separate kustomization,
                             applied server-side before the cluster
Makefile                   deploy order
.gitignore                 keeps *.kubeconfig (cluster-admin credentials) out of git
```

`cluster-01.yaml` contains placeholders and is not valid on its own: always
use `kubectl apply -k manifest/cluster-01` (or `make cluster`), never `-f`.
`make render` shows the complete manifest.

## Prerequisites

Management cluster with Cluster API v1.14 (kubeadm providers), CAPK v0.11,
KubeVirt v1.9, CDI v1.66 and the `local-path` storage class.

## Deploy and tear down

```
make up       # images, namespace, Calico, cluster; waits until Available
make status
make down     # deletes the Cluster first, then templates and RoleBinding
make dry-run  # server-side dry run of everything `make up` applies
```

The order matters: the image must be imported before VMs can clone it, and the
Calico ConfigMap must be current before the cluster boots.

`make down` keeps the image, Calico and the `cluster-01` namespace, so the next
`make up` only creates the cluster.

`make kubeconfig` writes the workload cluster's admin kubeconfig (from the
`cluster-01-kubeconfig` Secret) to `cluster-01.kubeconfig`, mode 0600 and
gitignored; `make pods` and `make nodes` refresh it and run `kubectl get po -A`
or `kubectl get nodes` in the workload cluster. The API endpoint is a ClusterIP,
so this works only where that address is reachable (e.g. on `monster`).

## Changing the cluster

- Machine and bootstrap templates are treated as immutable. To change one on a
  running cluster, add a copy with a new name (e.g. `-v1-35`) and point the
  control plane / MachineDeployment at it; that is what triggers a rollout.
- Workers copy the control plane's VM spec (`kustomization.yaml`). To give
  workers a different spec, remove that replacement and write it out in
  `cluster-01.yaml`.
- New Kubernetes version: add `manifest/images/<image>.yaml` (file name and
  DataVolume name both `<image>`) and point new templates' `source.pvc.name` at
  it. The Makefile reads the image from the templates; `make check-image`
  confirms they agree.

## Gotchas

- Control-plane rollouts create the new VM before deleting the old one, so
  `monster` needs about 4.5 GiB of unrequested memory for them. Workers roll
  delete-first (`maxSurge: 0`) and need no headroom.
- CDI checks disk clones against the target namespace's `default` service
  account. Each cluster manifest carries its own RoleBinding in `capk-images`.
- `kubectl get kcp` matches a Kong resource on this cluster; use
  `kubeadmcontrolplanes.controlplane.cluster.x-k8s.io`.
