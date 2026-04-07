apiVersion: 1

datasources:
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    isDefault: false
    editable: false

  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: "15s"

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
