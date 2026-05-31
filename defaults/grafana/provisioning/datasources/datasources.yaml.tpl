apiVersion: 1

# Czyszczenie pozostalosci po migracji Prometheus -> Netdata. Grafana trzyma
# sprovisionowane datasource'y tez we wlasnej bazie (wolumen grafana_data) —
# samo usuniecie wpisu z tego pliku NIE kasuje datasource'a z UI. deleteDatasources
# usuwa go jawnie przy starcie. Bezpieczne dla swiezych instalacji (nie istnieje
# = no-op), naprawia upgrade'owane (znika martwy datasource Prometheus).
deleteDatasources:
  - name: Prometheus
    orgId: 1

datasources:
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    isDefault: true
    editable: false

  - name: PostgreSQL
    uid: postgresql
    type: grafana-postgresql-datasource
    access: proxy
    url: ${DJANGO_BPP_DB_HOST}:${DJANGO_BPP_DB_PORT}
    isDefault: false
    editable: false
    jsonData:
      database: ${DJANGO_BPP_DB_NAME}
      sslmode: disable
      maxOpenConns: 5
      maxIdleConns: 2
      connMaxLifetime: 14400
    secureJsonData:
      password: ${DJANGO_BPP_DB_PASSWORD}
    user: ${DJANGO_BPP_DB_USER}
