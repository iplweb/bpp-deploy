# Monitoring — przegląd

Stack monitoringu dzieli się na dwie nogi: **metryki** (Netdata) i **logi**
(Alloy → Loki → Grafana). Dozzle daje live tail kontenerów.

| Usługa | Rola | Ścieżka |
|---|---|---|
| **netdata** | Metryki hosta / kontenerów / PostgreSQL / nginx, 1s rozdzielczość, gotowe alerty, push na ntfy.sh | `/netdata/` |
| **loki** | Agregacja i retencja logów (per service) | — (tylko przez Grafanę) |
| **alloy** | Kolektor logów z kontenerów Docker → Loki | — |
| **grafana** | Frontend do Loki/LogQL + dashboardy PostgreSQL | `/grafana/` |
| **dozzle** | Live tail logów kontenerów | `/dozzle/` |
| **flower** | UI monitorowania Celery | `/flower/` |

## Dwie nogi obserwowalności

- **Metryki @1s (Netdata)** — host, Docker, PostgreSQL (kolektor `go.d/postgres`),
  nginx (`stub_status` + `web_log`). Wbudowane setki reguł health; alerty push na telefon
  przez ntfy.sh. Szczegóły: [Netdata i alerty](netdata-alerty.md).
- **Logi (Alloy → Loki → Grafana)** — surowe linie logów do przeszukiwania w LogQL,
  retencja czasowa per service. Szczegóły: [Logowanie](logowanie.md).

To **nie** dubluje: Loki trzyma surowe linie do forensyki, Netdata liczy metryki i alertuje.

## Dostęp i uwierzytelnianie

Wszystkie panele są **za nginx + authserver** (Django auth proxy):

```
https://<domena>/netdata/
https://<domena>/grafana/
https://<domena>/flower/
https://<domena>/dozzle/
```

Loki **nie jest** publicznie wystawiony — odpytywany tylko przez Grafanę.

Grafana działa w trybie **auth proxy** za nginx + authserver. Nagłówki: `X-WEBAUTH-USER`,
`X-WEBAUTH-EMAIL`, `X-WEBAUTH-NAME`. Auto-signup jako Admin.

## CLI

```bash
make logs-<service>   # logi konkretnej usługi
make logs-netdata     # logi Netdaty
make celery-stats     # statystyki zadań Celery
make celery-status    # status workerów
make health           # healthcheck wszystkich usług
make ps               # lista kontenerów
make ntfy-test        # test pushu na ntfy
```

Netdata ma wbudowany healthcheck (Docker `HEALTHCHECK` w obrazie) — `make ps` pokazuje
jego stan.
