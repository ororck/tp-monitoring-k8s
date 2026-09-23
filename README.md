# TP monitoring Kubernetes

Stack de supervision (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics)
sur un cluster kind multi-noeuds, deployee entierement via ArgoCD a partir de manifests YAML
ecrits a la main (pas de Helm, pas d'operateur).

## Architecture

- Namespace `monitoring` pour tous les composants.
- `node-exporter` en DaemonSet (une instance par noeud, y compris le control-plane via toleration).
- `kube-state-metrics` en Deployment, avec le seul ClusterRole du TP (nodes/pods/deployments en lecture seule).
- `prometheus`, `alertmanager`, `grafana` en Deployment, chacun avec sa propre ServiceAccount dediee.
  Seul Prometheus a besoin d'un Role namespace (decouverte des endpoints a scraper) : Alertmanager
  et Grafana n'ont aucune permission RBAC.
- Alertmanager envoie les alertes vers Discord via `discord_configs` et `webhook_url_file`, l'URL du webhook
  etant lue depuis un fichier monte a partir d'un Secret Kubernetes cree manuellement, jamais commite.
- Deux dashboards Grafana provisionnes par ConfigMap (etat des noeuds, etat des pods).
- Ordre de deploiement impose via `argocd.argoproj.io/sync-wave` sur les Deployment/DaemonSet :
  Prometheus (0) puis Alertmanager (1) puis Grafana (2) puis les exporters (3).

Le seul objet du cluster qui n'est jamais gere par Git ni par ArgoCD est le Secret `discord-webhook`.

## Prerequis

- `kind`, `kubectl`, `docker`
- Un webhook Discord reel (URL au format `https://discord.com/api/webhooks/<id>/<token>`)

## 1. Creer le cluster

```bash
kind create cluster --config kind/kind-config.yaml
kubectl config use-context kind-tp-monitoring
kubectl wait --for=condition=Ready nodes --all --timeout=120s
```

## 2. Installer ArgoCD (v3.5.3)

```bash
kubectl create namespace argocd

# Le CRD applicationsets.argoproj.io depasse la limite de 262144 octets
# en client-side apply : passer en server-side apply.
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/manifests/install.yaml

kubectl -n argocd wait --for=condition=Available deployment --all --timeout=180s
```

## 3. Creer le Secret Discord (hors GitOps, jamais dans Git)

Le namespace `monitoring` doit exister avant que ArgoCD ne monte le Secret dans le pod Alertmanager.
Le creer manuellement, avec l'URL reelle du webhook Discord :

```bash
kubectl create namespace monitoring

kubectl -n monitoring create secret generic discord-webhook \
  --from-literal=url='https://discord.com/api/webhooks/REMPLACER_PAR_VOTRE_ID/REMPLACER_PAR_VOTRE_TOKEN'
```

La valeur ci-dessus est un placeholder. Sans un vrai webhook, Alertmanager tentera l'envoi et
recevra une erreur 400 de l'API Discord (`webhook_id ... is not snowflake`), ce qui prouve que le
pipeline d'alerte fonctionne jusqu'au bout sans exposer de vrai secret dans ce depot.

Attention : ArgoCD gere le namespace `monitoring` avec `prune: true` et un finalizer de cascade.
Supprimer l'Application (`kubectl delete -f argocd/application.yaml` ou depuis l'UI) supprime le
namespace entier, donc ce Secret avec. Il faudra le recreer avec cette meme commande apres toute
suppression de l'Application.

## 4. Deployer la stack via ArgoCD

```bash
kubectl apply -f argocd/application.yaml
```

ArgoCD synchronise automatiquement tout le contenu de `k8s/` dans le namespace `monitoring`,
dans l'ordre impose par les sync-waves.

## 5. Verifier le deploiement

```bash
# Etat de l'Application ArgoCD
kubectl -n argocd get application monitoring-stack
# Attendu : SYNC STATUS = Synced, HEALTH STATUS = Healthy

# Tous les pods du namespace monitoring
kubectl -n monitoring get pods
# Attendu : 7 pods Running (prometheus, alertmanager, grafana,
# kube-state-metrics, 3x node-exporter)
```

### Verifier que Prometheus scrape bien les exporters

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090
# Dans un autre terminal
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'
# Attendu : node-exporter (x3), kube-state-metrics, prometheus, tous "up"
```

### Verifier que Prometheus connait Alertmanager

```bash
curl -s localhost:9090/api/v1/alertmanagers | jq
# Attendu : alertmanager.monitoring.svc:9093 dans activeAlertmanagers
```

### Verifier le datasource Grafana

```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000
# Dans un autre terminal
curl -s localhost:3000/api/datasources/uid/prometheus/health
# Attendu : {"status":"OK", ...}
```

Ouvrir http://localhost:3000 dans un navigateur (authentification anonyme activee en lecture seule)
pour voir les deux dashboards provisionnes : "Etat des noeuds" et "Etat des pods".

## 6. Tester l'alerte CrashLoopBackOff de bout en bout

```bash
kubectl apply -f tests/crashloop-pod.yaml

# Attendre l'etat CrashLoopBackOff (quelques secondes)
kubectl -n monitoring get pod crashloop-test -w
```

Apres environ 2 a 5 minutes (le temps que kube-state-metrics expose la metrique et que la regle
`for: 2m` se declenche), verifier l'alerte :

Si un port-forward de la section precedente tourne encore en arriere-plan, l'arreter avant
(`kill %1` ou `pkill -f 'port-forward svc/prometheus'`), ou utiliser des ports locaux differents
comme ci-dessous.

```bash
kubectl -n monitoring port-forward svc/prometheus 19090:9090 &
curl -s localhost:19090/api/v1/alerts | jq '.data.alerts[] | select(.labels.alertname=="KubePodCrashLooping")'
# Attendu : state = "firing"

kubectl -n monitoring port-forward svc/alertmanager 19093:9093 &
curl -s localhost:19093/api/v2/alerts | jq
# Attendu : l'alerte KubePodCrashLooping presente, receiver "discord"

kubectl -n monitoring logs deployment/alertmanager --tail=20
# Avec un vrai webhook : pas d'erreur, message recu sur Discord
# Avec le placeholder ci-dessus : erreur 400 "webhook_id ... is not snowflake"
```

Nettoyer ensuite le pod de test, qui n'est jamais gere par ArgoCD :

```bash
kubectl delete -f tests/crashloop-pod.yaml
```

## 7. Verification mecanique des manifests

```bash
yamllint .
kubectl kustomize k8s/overlays/kind | kubeconform -summary -kubernetes-version 1.36.0
kubectl kustomize k8s/overlays/kind | kube-linter lint -
```

## 8. Tout supprimer

```bash
kind delete cluster --name tp-monitoring
```

---

# Overlay AKS

Variante Azure de la meme stack, sur `k8s/overlays/aks` : meme base, PVC sur StorageClass Azure Disk
(`managed-csi`) pour Prometheus/Alertmanager/Grafana, webhook Discord lu depuis Azure Key Vault via
workload identity et le Secrets Store CSI Driver (aucun Secret Kubernetes cree a la main). Acces par
port-forward uniquement, pas d'Ingress. Infrastructure geree par Terraform (`terraform/`).

## Prerequis

- `az` (connecte, sur l'abonnement cible), `terraform`, `kubectl`
- Resource group existant avec droits Owner/Contributor
- Cluster AKS avec OIDC issuer + workload identity actives (fait par Terraform)

## 1. Provisionner l'infrastructure Azure

```bash
cd terraform
terraform init
terraform apply
```

Variables dans `terraform.tfvars` (non versionne) : `resource_group_name`, `aks_cluster_name`,
`key_vault_name`.

## 2. Recuperer les credentials du cluster

```bash
az aks get-credentials --resource-group <resource_group_name> --name <aks_cluster_name> \
  --context aks-tp-monitoring
```

## 3. Deposer le webhook Discord dans Key Vault

```bash
az keyvault secret set --vault-name <key_vault_name> \
  --name discord-webhook-url --value '<url du webhook>'
```

## 4. Installer ArgoCD

```bash
kubectl --context aks-tp-monitoring create namespace argocd

kubectl --context aks-tp-monitoring apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/manifests/install.yaml

kubectl --context aks-tp-monitoring -n argocd wait --for=condition=Available deployment --all --timeout=180s
```

## 5. Deployer l'overlay AKS

```bash
kubectl --context aks-tp-monitoring apply -f argocd/application-aks.yaml
```

## 6. Verifier le deploiement

```bash
kubectl --context aks-tp-monitoring -n argocd get application monitoring-stack-aks
# Attendu : SYNC STATUS = Synced, HEALTH STATUS = Healthy

kubectl --context aks-tp-monitoring -n monitoring get pods,pvc
# Attendu : tous les pods Running, toutes les PVC Bound sur managed-csi
```

### Verifier l'acces par port-forward

```bash
kubectl --context aks-tp-monitoring -n monitoring port-forward svc/prometheus 9090:9090 &
kubectl --context aks-tp-monitoring -n monitoring port-forward svc/alertmanager 9093:9093 &
kubectl --context aks-tp-monitoring -n monitoring port-forward svc/grafana 3000:3000 &
```

### Verifier la lecture du webhook depuis Key Vault

```bash
kubectl --context aks-tp-monitoring -n monitoring exec deploy/alertmanager -- \
  sh -c 'wc -c < /etc/alertmanager-discord/url'
# Attendu : taille non nulle, sans afficher le contenu
```

## 7. Verification mecanique de l'overlay

```bash
kubectl kustomize k8s/overlays/aks | kubeconform -strict -summary
kubectl kustomize k8s/overlays/aks | kube-linter lint -
cd terraform && terraform fmt -check && terraform validate
```

## 8. Tout supprimer

```bash
kubectl --context aks-tp-monitoring -n argocd delete application monitoring-stack-aks

cd terraform
terraform destroy

az keyvault purge --name <key_vault_name>
```
