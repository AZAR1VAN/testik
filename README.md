# Тестове завдання

> **Кандидат**: Іван | **Репозиторій**: https://github.com/AZAR1VAN/testik

---

##  Швидкий старт в одну команду 🚀 :

```bash
git clone https://github.com/AZAR1VAN/testik.git
cd testik
chmod +x setup.sh cleanup.sh
./setup.sh
```

Скрипт автоматично розгортає повну інфраструктуру:
**Minikube (Calico CNI) → ArgoCD → spam2000 → VictoriaMetrics → Grafana**

Після завершення всі облікові дані зберігаються у файлі `credentials.txt` (не потрапляє в Git).

### 🧹 Очищення (перед повторним деплоєм)

```bash
./cleanup.sh   # Видаляє: Minikube, Docker containers/images, iptables, credentials
./setup.sh     # Розгортає все заново
```

---

## Системні вимоги 📋 :

### Апаратні вимоги (мінімум)

| Параметр | Значення |
|----------|----------|
| CPU | 4 vCPU |
| RAM | 8 GB |
| Диск | 30 GB (SSD рекомендовано) |

### Підтримувані ОС

| ОС | Версія | Статус |
|----|--------|--------|
| Ubuntu | 24.04 LTS | ✅ Протестовано |
| Ubuntu | 22.04 LTS | ✅ Підтримується |
| Debian | 11 / 12 | ⚠️ Має працювати |

### Програмне забезпечення

> `setup.sh` автоматично встановлює все необхідне ПЗ, якщо його немає:

| Компонент | Версія | Встановлення |
|-----------|--------|--------------|
| Docker | latest | `get.docker.com` |
| kubectl | latest stable | `dl.k8s.io` |
| Minikube | latest | `storage.googleapis.com` |
| Helm | v3 | `get-helm-3` script |
| iptables | системний | `apt-get install` |
| openssl | системний | Для генерації паролів |
| curl, git | системний | Мають бути встановлені заздалегідь |

---

## Технологічний стек 🏗️ :  

| Компонент | Технологія | Namespace | Опис |
|-----------|-----------|-----------|------|
| Kubernetes | Minikube (Docker driver, 4 CPU, 8GB RAM) | — | Локальний кластер |
| CNI | Calico | `kube-system` | Мережевий плагін з підтримкою NetworkPolicy |
| GitOps | ArgoCD (polling 30s) | `argocd` | Автоматичний деплой з Git |
| Додаток | spam2000 (`andriiuni/spam2000:1.1394.355`) | `apps` | Генератор метрик (порт 3000) |
| Метрики | VictoriaMetrics | `monitoring` | Збір та зберігання метрик |
| Дашборди | Grafana (sidecar provisioning) | `monitoring` | Візуалізація метрик |

### Мережева конфігурація 🌐

| Параметр | Значення |
|----------|----------|
| Pod subnet (CIDR) | `10.244.0.0/16` |
| Service subnet (CIDR) | `10.96.0.0/16` |
| CNI | Calico (NetworkPolicy enforcement) |

---

## Що робить `setup.sh` покроково 💡 :

| Крок | Що відбувається |
|------|----------------|
| 0 | DNS fix (`/etc/resolv.conf` → `8.8.8.8/1.1.1.1`) + створення deploy юзера |
| 1 | Перевірка та встановлення залежностей (Docker, kubectl, minikube, helm, iptables) |
| 2 | Додавання Helm репозиторіїв (VictoriaMetrics, Grafana, ArgoCD) |
| 3 | Запуск Minikube з Calico CNI, pod/service subnet |
| 4 | Створення namespaces: `argocd`, `apps`, `monitoring` |
| 4.5 | **PersistentVolumes** — `kubectl apply -f monitoring/persistent-volumes.yaml` |
| 5 | **CoreDNS fix** — патч DNS на `8.8.8.8/1.1.1.1` (щоб ArgoCD міг дістатись до GitHub) |
| 6 | Встановлення ArgoCD + зменшення polling до 30s |
| 7 | Деплой spam2000 через Helm chart (`charts/spam2000/`) |
| 8 | RBAC — `kubectl apply -f monitoring/rbac.yaml` |
| 9 | VictoriaMetrics + scrape config (`monitoring/victoria-scrape-config.yaml`) |
| 10 | Grafana (пароль через `--set adminPassword`) |
| 11 | Dashboard ConfigMaps (sidecar provisioning, persist across restarts) |
| 12 | ArgoCD Application для spam2000 (GitOps auto-sync) |
| 13 | Expose сервісів: NodePort + `monitoring/victoria-nodeport-svc.yaml` |
| 14 | **Зовнішній доступ** — iptables DNAT/FORWARD/MASQUERADE |
| 15 | Збереження облікових даних у `credentials.txt` |

---

## Persistent Volumes 💾 :

Файл `monitoring/persistent-volumes.yaml` створює явні PV з `hostPath` в Minikube-persistent директорії `/data/`:

| PV | PVC | Розмір | hostPath | Для чого |
|----|-----|--------|----------|----------|
| `grafana-pv` | `grafana-pvc` | 1Gi | `/data/grafana` | Grafana config/plugins |
| `victoria-metrics-pv` | `victoria-metrics-pvc` | 5Gi | `/data/victoria-metrics` | Метрики (retention 7d) |

> Використано `storageClassName: ""` з явним `volumeName` для manual binding (не auto-provisioned).
>
> Шляхи `/data/*` зберігаються при перезавантаженні Minikube ([документація](https://minikube.sigs.k8s.io/docs/handbook/persistent_volumes/)).

---

## Безпека 🔐 :

- **Calico CNI** — підтримка NetworkPolicy (ArgoCD створює NetworkPolicies автоматично)
- **Окремий користувач** — `setup.sh` створює `deployer` (docker + sudo), не використовує root
- **Паролі не зберігаються в Git** — генеруються при деплої через `openssl rand -hex 12`
- **Grafana password** — передається через `--set adminPassword` при Helm install
- **ArgoCD password** — автоматично генерується ArgoCD при першому запуску
- **ArgoCD polling** — зменшено до **30 секунд** (дефолт 3 хвилини)
- **credentials.txt** — файл з усіма паролями, створюється після `setup.sh`, додано в `.gitignore`
- Можна задати свій пароль: `GRAFANA_ADMIN_PASS=mypass ./setup.sh`

---

##  GitOps демонстрація 🔄 :

ArgoCD слідкує за цим репозиторієм та автоматично застосовує зміни (polling кожні 30 секунд):

```bash
# Змінити кількість реплік spam2000
vim charts/spam2000/values.yaml   # replicaCount: 1 → 2
git add . && git commit -m "scale: spam2000 to 2 replicas"
git push

# ArgoCD автоматично підхопить зміни протягом ~30 секунд
kubectl get pods -n apps -w
```

> Через ArgoCD управляється **тільки spam2000** (GitOps).
> Grafana та VictoriaMetrics — інфраструктура, managed через `setup.sh` / Helm.

---

##  Grafana Дашборди 📊 :

Дашборди provisioned через **ConfigMap sidecar** — зберігаються при рестартах подів.

### Kubernetes Cluster Overview (`k8s-cluster`)
| Панель | Метрика | Опис |
|--------|---------|------|
| Scrape Targets Status | `up` | Стан всіх scrape цілей (таблиця) |
| Total Time Series | `vm_rows{type="indexdb"}` | Кількість серій у VictoriaMetrics |
| Active Time Series | `vm_cache_entries` | Кількість активних серій |
| Ingestion Rate | `rate(vm_rows_inserted_total[5m])` | Швидкість вставки метрик |
| CPU by Pod | `rate(container_cpu_usage_seconds_total)` | ТОП-5 подів за CPU |
| Memory by Pod | `container_memory_working_set_bytes` | ТОП-5 подів за RAM |
| Network by Interface | `rate(container_network_*_bytes_total)` | Мережевий трафік |
| Filesystem by Device | `container_fs_usage_bytes` | Використання диску |

### spam2000 Application Metrics (`spam2000-app`)
| Панель | Метрика | Опис |
|--------|---------|------|
| Up Status | `up{job="spam2000"}` | Стан додатку (UP/DOWN) |
| Total Unique Series | `count(random_gauge_1)` | Кількість унікальних серій |
| Scrape Duration | `scrape_duration_seconds` | Час збору метрик |
| Scraped Samples | `scrape_samples_scraped` | Кількість зібраних семплів |
| By Country (top 10) | `topk(10, sum by (country)(random_gauge_1))` | Метрики по країнах |
| By Platform (pie) | `sum by (platform)(random_gauge_1)` | Розподіл по платформах |
| Pod CPU Usage | `rate(container_cpu_usage_seconds_total{pod=~"spam2000.*"})` | CPU spam2000 |
| Pod Memory Usage | `container_memory_working_set_bytes{pod=~"spam2000.*"}` | RAM spam2000 |

---

##  Ключові знахідки під час роботи 🔑 :

| Параметр | Значення | Як знайшов |
|----------|----------|------------|
| spam2000 image tag | `1.1394.355` (єдиний доступний тег) | Docker Hub |
| spam2000 порт | `3000` (Node.js процес) | `ss -tlnp` всередині контейнера |
| spam2000 метрика | `random_gauge_1{product, platform, email, name, country}` | `/metrics` endpoint |
| OOMKilled fix | Збільшив memory 128Mi → 512Mi | Под падав з OOMKilled |
| cAdvisor label | `pod` (не `name`) | `curl /api/v1/labels?match[]=container_cpu_usage_seconds_total` |
| Network label | `interface` і `id="/"` (per-pod недоступний) | Перевірка VictoriaMetrics API |
| VictoriaMetrics config | `/config/scrape.yaml` (не `/scrapeconfig/`) | CrashLoopBackOff debug |
| search.maxUniqueTimeseries | 5M (default 536K замало) | Error 422 на histogram |

---

##  Структура проєкту 📁 :

```
testik/
├── setup.sh                             # Головний скрипт деплою (одна команда)
├── cleanup.sh                           # Повне очищення кластера
├── README.md                            # Цей файл
├── .gitignore                           # Ігнорує credentials.txt, secrets
├── credentials.txt                      # Генерується setup.sh (НЕ в Git!)
│
├── argocd/apps/
│   └── spam2000-app.yaml                # ArgoCD Application (GitOps auto-sync)
│
├── charts/spam2000/                     # Helm chart додатку
│   ├── Chart.yaml
│   ├── values.yaml                      # ← GitOps контроль (replicas, tag, port, memory)
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── _helpers.tpl
│
└── monitoring/
    ├── persistent-volumes.yaml          # PV/PVC (hostPath /data/grafana, /data/victoria-metrics)
    ├── rbac.yaml                        # ClusterRole/Binding для kubelet/cAdvisor scraping
    ├── victoria-values.yaml             # VictoriaMetrics Helm values
    ├── victoria-scrape-config.yaml      # Scrape ConfigMap (spam2000, kubelet, cAdvisor, pods)
    ├── victoria-nodeport-svc.yaml       # NodePort 30428 сервіс
    ├── grafana-values.yaml              # Grafana Helm values (datasource, sidecar, persistence)
    └── dashboards/
        ├── cluster-dashboard.json       # Kubernetes Cluster Overview
        └── spam2000-dashboard.json      # spam2000 Application Metrics
```

---

##  Виконані вимоги ✅ :  

- [x] GitHub репозиторій з README
- [x] Деплой однією командою (`./setup.sh`)
- [x] Calico CNI з явними pod/service підмережами
- [x] Persistent Volumes з hostPath та вказаними розмірами
- [x] GitOps: push в Git → ArgoCD автоматично синхронізує (30s polling)
- [x] Моніторинг: VictoriaMetrics збирає метрики (spam2000, kubelet, cAdvisor)
- [x] Дашборди: cluster overview + spam2000 (persistent via ConfigMap sidecar)
- [x] Безпека: паролі не в репо, окремий deploy user, `.gitignore`

---

##  Доступ до сервісів 🌐 :

Після `./setup.sh` всі URL та паролі зберігаються в `credentials.txt`.

| Сервіс | Зовнішній порт | Внутрішній NodePort | Логін |
|--------|---------------|---------------------|-------|
| Grafana | `:3001` | `30300` | admin / (з credentials.txt) |
| ArgoCD | `:8080` (HTTPS) | `30080` | admin / (з credentials.txt) |
| VictoriaMetrics | `:8428` | `30428` | — |

### Варіант 1: Прямий доступ (якщо сервер має зовнішню IP)

`setup.sh` автоматично налаштовує iptables forwarding:

```
http://<EXTERNAL_IP>:3001       → Grafana
https://<EXTERNAL_IP>:8080      → ArgoCD
http://<EXTERNAL_IP>:8428       → VictoriaMetrics
```

### Варіант 2: SSH тунель

```bash
ssh -L 3001:<MINIKUBE_IP>:30300 \
    -L 8080:<MINIKUBE_IP>:30080 \
    -L 8428:<MINIKUBE_IP>:30428 \
    user@<SERVER_IP>

# Після цього локально:
# Grafana:         http://localhost:3001
# ArgoCD:          https://localhost:8080
# VictoriaMetrics: http://localhost:8428
```
