# History of this script

## 1. Create a directory

```sh
mkdir grafana-metrics-archive
cd grafana-metrics-archive

mkdir -p data
```

Eventually, we'll have

```
grafana-metrics-archive/
├── .env
├── Dockerfile
├── compose.yaml
├── archive.sh
└── data/
    ├── state/
    └── tsdb/
```

Don't create the files yet except as we reach them.

---

## 2. Get the Grafana Cloud values

Go to your Grafana Cloud stack. Ours was at found it at https://grafana.com/orgs/donorteam.

Find the Prometheus card and click **Details** on that card.

Locate the **Remote Write Endpoint**. Our Remote Write Endpoint will look roughly like:

```
https://prometheus-prod-XX-prod-eu-west-X.grafana.net/api/prom/push
```

From that we want the host portion:

```
https://prometheus-prod-XX-prod-eu-west-2.grafana.net
```

Grafana documents that Mimir-specific endpoints can be derived from the remote-write endpoint by removing `/api/prom/push` and adding `/prometheus`. See [Grafana Labs](https://grafana.com/docs/grafana-cloud/send-data/metrics/metrics-prometheus/query-http-api/).

Our Remote Read endpoint is:

```
https://prometheus-prod-24-prod-eu-west-2.grafana.net/prometheus/api/v1/read
```

Mimir itself exposes Remote Read at the Prometheus API's `/api/v1/read` endpoint. See [Grafana Labs](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/).

---

## 3. Create a read-only token

Go to your Grafana Cloud stack. Ours was at found it at https://grafana.com/orgs/donorteam.

In the left menu, go to **Access Policies** (under **SECURITY**).

Click **New access policy**.

Give it a name such as `local-metrics-archive`.

Under **Scopes**, enable **Read** for **Metrics** only. This corresponds to `metrics:read`. You don't need `metrics:write`, logs, traces, etc. See [Grafana Labs](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/kubernetes-monitoring/configuration/control-access/?utm_source=chatgpt.com).

Create the policy.

On the resulting policy, click **Add token**.

Give the token a name such as `local-metrics-archive-token`.

Create it and **copy the token immediately**; you'll use it as environment variable `MIMIR_API_KEY`. The token is the password, while your Metrics instance ID is the username. See [Grafana Labs](https://grafana.com/docs/grafana-cloud/security-and-account-management/authentication-and-permissions/access-policies/using-an-access-policy-token/?utm_source=chatgpt.com).

---

## 4. Find Username / Instance ID

Go to your Grafana Cloud stack again. 

Find the Prometheus card and click **Details** on that card.

Look for **Username / Instance ID** (sometimes shown simply as **User**).

---

## 5. Create `.env`-file

Create:

```sh
touch .env
chmod 600 .env
````

Put this in it:

```dotenv
MIMIR_ADDRESS=https://prometheus-prod-XX-prod-eu-west-2.grafana.net
MIMIR_TENANT_ID=...
MIMIR_API_KEY=...

SELECTOR={__name__=~".+"}

# Config
SYNC_INTERVAL_SECONDS=21600 # 6 hours
LAG_SECONDS=600 # 10 minutes
INITIAL_LOOKBACK_SECONDS=1123200 # 13 days
WINDOW_SECONDS=21600 # 6 hours
```

Replace:

```
MIMIR_ADDRESS
MIMIR_TENANT_ID
MIMIR_API_KEY
```

with your actual values.

> [!note] Note
> `1123200` seconds is 13 days. Our Grafana Cloud retention is two weeks, so starting 13 days back gives us a little safety margin rather than trying to hit the retention boundary exactly.

> [!note] Note
> I've deliberately used `MIMIR_TENANT_ID` here. Remote-read historically uses the tenant ID as its Basic Auth username rather than the general `MIMIR_API_USER`; a Grafana maintainer specifically documented that behavior for `mimirtool remote-read`. See [GitHub](https://github.com/grafana/mimir/discussions/11435?utm_source=chatgpt.com). For Grafana Cloud, that tenant ID is your Metrics instance ID anyway, so it fits perfectly.

> [!danger] Danger
> Do **not** commit `.env`.
>
> Add:
> 
> ```
> echo '.env' > .gitignore
> echo 'data/' >> .gitignore
> ```

