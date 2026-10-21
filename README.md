# kube-cluster-api

Manifests and a Makefile for building Kubernetes workload clusters as KubeVirt
virtual machines on a single-node management cluster (`monster`), using
[Cluster API](https://cluster-api.sigs.k8s.io/) with the KubeVirt
infrastructure provider (CAPK).

The repo currently defines one cluster, `cluster-01`:

- **Nodes:** one control-plane node and one worker, each a KubeVirt VM with
  2 cores, 4 GiB of memory and a 25 GiB disk.
- **Kubernetes:** v1.34.1 on Ubuntu 24.04, bootstrapped with kubeadm. Each
  node reserves 512 MiB and 200m CPU for the kubelet and system, plus a 200 MiB
  eviction threshold.
- **Networking:** Calico v3.32.2 in VXLAN mode, installed automatically by a
  ClusterResourceSet. Pods use 10.243.0.0/16 and Services 10.95.0.0/16.
- **API endpoint:** a ClusterIP Service on the management cluster, so the
  workload cluster is reachable only from inside it or from `monster`.

How a build works: the VM disk image is imported once into the `capk-images`
namespace with CDI, and every VM gets a local copy of it. Cluster API then
creates the VMs, kubeadm turns them into nodes, and Calico is installed once the
control plane is up. `make up` runs the whole sequence in order and `make down`
removes it; a full build takes about four minutes.

The setup is meant for a lab, and is rebuilt freely rather than upgraded in
place:

- One host and one control-plane node, on node-local storage, with no etcd
  backups. Losing `monster`'s disk loses the cluster.
- Control-plane rollouts need about 4.5 GiB of spare memory on `monster`; see
  [Gotchas](#gotchas).
- Kubernetes 1.34 reaches end of life on 2026-10-27, and CAPK publishes no
  disk image newer than v1.34.1. Moving to a newer version means building an
  image with [image-builder](https://github.com/kubernetes-sigs/image-builder).

## Resource map

How the objects in `manifest/` refer to each other, what the controllers create
from them, and what kustomize fills in before anything is applied.

### What refers to what

Every arrow is a field in the source object that names the target. Two links
work by label instead of by name, so they keep working when objects are
renamed, and they silently match nothing if the label is missing.

![Declared objects: the Cluster points at the KubeadmControlPlane and KubevirtCluster; the control plane and MachineDeployment point at their templates; both machine templates clone the DataVolume in capk-images; the ClusterResourceSet and MachineHealthCheck select by label.](docs/resource-refs.svg)

- Solid arrow: names the target in a field.
- Dashed, coloured arrow: matches by label selector.

The Cluster is the root. The control plane and the MachineDeployment each name
their templates, and both machine templates name the same shared disk image in
`capk-images`. The two RoleBindings are what allow that cross-namespace clone.

### What the controllers create

None of these objects are in the repo. Cluster API, CAPK, KubeVirt and CDI
create them from the declared objects above, and `make down` lets them clean up
in the same order.

![Runtime chain: the control plane and MachineDeployment create Machines, Machines create VirtualMachines, each VM clones its disk from the shared DataVolume and runs one node of the workload cluster. The ClusterResourceSet installs Calico into that cluster. The KubevirtCluster creates the cluster-01-lb Service, the API endpoint.](docs/resource-runtime.svg)

- Solid box: declared in the repo.
- Dashed box: created by a controller.
- Dotted box: outside the cluster.
- Dashed, coloured arrow: matches by label.

The image is downloaded from quay.io once; every VM after that gets a local
copy of it. The MachineHealthCheck replaces a worker Machine whose node isn't
Ready for 600 s. The Service's ClusterIP is written into the API certificate
and every node's settings, so replacing that Service breaks the cluster.

### What kustomize fills in

These links exist only in the repo. They're resolved when the kustomizations
are built, so the server only ever sees the finished objects. That's why
`cluster-01.yaml` has to be applied with `-k`.

![Build time: kubelet-config.yaml is copied into the files of the control plane and the worker KubeadmConfigTemplate; the control-plane machine template's spec is copied into the worker template; calico-v3.32.2.yaml is turned into the calico ConfigMap.](docs/resource-build.svg)

Each setting has a single source. The kubelet patch is written once for all
nodes, workers reuse the control plane's VM spec, and the Calico manifest
becomes a ConfigMap. Calico's ConfigMap comes from a separate kustomization
that is applied server-side, because it's too large for a normal apply.

### Where each object is defined

`manifest/cluster-01/`:

| Object | Namespace | Defined in | Role |
|---|---|---|---|
| Cluster `cluster-01` | cluster-01 | `cluster-01.yaml` | Root object. Names the control plane and infrastructure; its `cni=calico` label gets it Calico. |
| KubeadmControlPlane `cluster-01-control` | cluster-01 | `cluster-01.yaml` + `kubelet-config.yaml` | Creates, upgrades and replaces the single control-plane machine. |
| KubevirtCluster `cluster-01` | cluster-01 | `cluster-01.yaml` | Creates the `cluster-01-lb` Service that serves as the API endpoint. |
| KubevirtMachineTemplate `cluster-01-control-v1-34` | cluster-01 | `cluster-01.yaml` | VM spec: 2 cores, 4 GiB, 25 GiB disk cloned from the shared image. |
| KubevirtMachineTemplate `cluster-01-worker-v1-34` | cluster-01 | `cluster-01.yaml`, spec copied by kustomize | Worker VM spec, identical to the control plane's. |
| KubeadmConfigTemplate `cluster-01-worker-v1-34` | cluster-01 | `cluster-01.yaml` + `kubelet-config.yaml` | kubeadm join settings for workers, including the kubelet reservations. |
| MachineDeployment `cluster-01-worker` | cluster-01 | `cluster-01.yaml` | Keeps one worker. Rolls delete-first (`maxSurge: 0`). |
| MachineHealthCheck `cluster-01-worker` | cluster-01 | `cluster-01.yaml` | Replaces a worker whose node isn't Ready for 600 s. |
| RoleBinding `cluster-01-clone-sourcer` | capk-images | `cluster-01.yaml` | Lets cluster-01's VMs clone the shared image. |
| ClusterResourceSet `calico` | cluster-01 | `calico/clusterresourceset.yaml` | Installs Calico in clusters labelled `cni=calico`, and re-applies it when the ConfigMap changes. |
| ConfigMap `calico` | cluster-01 | `calico/kustomization.yaml` from `calico-v3.32.2.yaml` | The Calico manifest, with pod CIDR 10.243.0.0/16 and MTU 1430. |

`manifest/images/`:

| Object | Namespace | Defined in | Role |
|---|---|---|---|
| Namespace `capk-images` | — | `capk-images.yaml` | Holds the shared disk images. |
| RoleBinding `capk-manager-clone-sourcer` | capk-images | `capk-images.yaml` | Lets CAPK clone the shared images. |
| DataVolume `ubuntu-2404-v1-34-1` | capk-images | `ubuntu-2404-v1-34-1.yaml` | Ubuntu 24.04 / Kubernetes v1.34.1 disk, imported once from quay.io. |

Not in the repo:

| Object | Namespace | Created by | Role |
|---|---|---|---|
| Namespace `cluster-01` | — | `make namespace` | Holds the cluster's objects and the Calico ConfigMap. |
| Machines, VMs, disks `cluster-01-…` | cluster-01 | Cluster API, CAPK, KubeVirt, CDI | One per node. Names change on every rebuild. |
| Service `cluster-01-lb` | cluster-01 | CAPK | ClusterIP API endpoint, built into the certificate and every node's settings. |
| Secret `cluster-01-kubeconfig` | cluster-01 | Cluster API | Admin kubeconfig for the workload cluster, read by `make kubeconfig`. |

## Prerequisites

Installed on the management cluster (versions as deployed on `monster`):

| Component | Version | Used for | Docs |
|---|---|---|---|
| Cluster API, with the kubeadm bootstrap and control-plane providers | v1.14.1 | Cluster, MachineDeployment, MachineHealthCheck, KubeadmControlPlane, KubeadmConfigTemplate, ClusterResourceSet | [cluster-api.sigs.k8s.io](https://cluster-api.sigs.k8s.io/) ([kubeadm bootstrap](https://cluster-api.sigs.k8s.io/tasks/bootstrap/kubeadm-bootstrap/), [kubeadm control plane](https://cluster-api.sigs.k8s.io/tasks/control-plane/kubeadm-control-plane), [ClusterResourceSet](https://cluster-api.sigs.k8s.io/tasks/cluster-resource-set)) |
| Cluster API Provider KubeVirt (CAPK) | v0.11.2 | KubevirtCluster, KubevirtMachineTemplate | [kubernetes-sigs/cluster-api-provider-kubevirt](https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt) |
| KubeVirt | v1.9.0 | The VirtualMachines that run the nodes | [kubevirt.io/user-guide](https://kubevirt.io/user-guide/) |
| Containerized Data Importer (CDI) | v1.66.0 | DataVolume image import and disk clones | [kubevirt/containerized-data-importer](https://github.com/kubevirt/containerized-data-importer) ([user guide](https://kubevirt.io/user-guide/storage/containerized_data_importer/)) |
| Local Path Provisioner | `local-path` storage class | VM disks and the shared image | [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) |

On the machine running `make`:

| Tool | Version | Used for | Docs |
|---|---|---|---|
| kubectl, with built-in kustomize | kustomize v5.7.1 | Every Makefile target | [kubectl](https://kubernetes.io/docs/reference/kubectl/), [kustomize](https://kubectl.docs.kubernetes.io/) |
| GNU Make | 4.3 | The Makefile | [GNU Make manual](https://www.gnu.org/software/make/manual/) |

Installed by this repo, not a prerequisite: [Calico](https://docs.tigera.io/calico/3.32/about/)
v3.32.2, in the workload cluster.

## Make targets

All targets act on the management cluster in the current kubectl context,
except `pods` and `nodes`, which talk to the workload cluster.

| Target | What it does |
|---|---|
| **Deploy and tear down** | |
| `make up` | Runs `images`, `namespace`, `calico`, `cluster` and `wait`, in that order. |
| `make down` | Deletes the Cluster and waits (up to 15 min) for Cluster API to remove its machines and VMs, then deletes the templates and clone RoleBinding with `kubectl delete -k`. |
| **Steps of `make up`** | Each also runs on its own. |
| `make images` | Runs `check-image`, applies `capk-images.yaml` and the image DataVolume, and waits (up to 20 min) for the import. |
| `make namespace` | Creates the `cluster-01` namespace if it doesn't exist. |
| `make calico` | Applies the Calico ConfigMap and ClusterResourceSet, server-side. |
| `make cluster` | `kubectl apply -k manifest/cluster-01`. |
| `make wait` | Waits (up to 20 min) for the Cluster's `Available` condition. |
| **Read-only checks** | None of these change anything. |
| `make render` | Prints the complete cluster manifest, exactly as `make cluster` applies it. |
| `make dry-run` | Runs `check-image`, then a server-side dry run of everything `make up` applies. |
| `make check-image` | Reads the image from the templates' `source.pvc.name` and fails unless there is exactly one and `manifest/images/<image>.yaml` defines it. |
| `make status` | Shows the Cluster, its machines and their disks. |
| **Workload cluster** | |
| `make kubeconfig` | Writes the admin kubeconfig from the `cluster-01-kubeconfig` Secret to `cluster-01.kubeconfig` (mode 0600, gitignored). Rewritten every run, since each rebuild issues new credentials. |
| `make pods` | Runs `kubeconfig`, then `kubectl get po -A` in the workload cluster. |
| `make nodes` | Runs `kubeconfig`, then `kubectl get nodes` in the workload cluster. |

The order in `make up` matters: the image must be imported before VMs can clone
it, and the Calico ConfigMap must be current before the cluster boots.

`make down` keeps the image, Calico and the `cluster-01` namespace, so the next
`make up` only creates the cluster.

The workload cluster's API endpoint is a ClusterIP, so `pods`, `nodes` and the
kubeconfig work only where that address is reachable (e.g. on `monster`).

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
