# Loki configuration for BPP deployment.
#
# Retention strategy (per-stream via `service` label wstawiany przez Alloy
# z `com.docker.compose.service`):
#   - appserver, dbserver  -> 90 dni
#   - webserver            -> 180 dni
#   - wszystko inne        -> 30 dni (default)
#
# Compactor dziala w tle, usuwa chunki starsze niz retention_period.
# Bez compactor.retention_enabled = true chunki zostaja w volume
# na zawsze - limits_config samo nie kasuje.

auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: warn

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  # Wbudowana detekcja poziomu logu w Loki — WYLACZONA. Zrodlem `detected_level`
  # jest wylacznie Alloy (defaults/alloy/config.alloy), bo tylko on umie odczytac
  # trafienia WAF-a. Przy dwoch detektorach pod ta sama nazwa dropdown "Log Level"
  # w Grafanie pokazywal sume dwoch slownikow, a w szczegolach linii pojawial sie
  # `detected_level_extracted`.
  #
  # Ten klucz dziala tylko na SWIEZYCH instalacjach (plik jest copy_if_missing).
  # Dla istniejacych to samo robi flaga -validation.discover-log-levels=false
  # w docker-compose.monitoring.yml — i to ona jest wlasciwym mechanizmem;
  # ten wpis jest tu dla jawnosci i musi byc z nia ZGODNY.
  #
  # UWAGA: blizniaczego `discover_service_name` (dokleja `service_name`
  # duplikujacy nasz label `service`) NIE da sie wylaczyc analogiczna flaga —
  # `-validation.discover-service-name=` dopisuje pusty wpis do listy domyslnej
  # zamiast ja czyscic. Zostaje wiec wlaczone wszedzie, zeby swieze i istniejace
  # instalacje zachowywaly sie tak samo. To kosmetyczny duplikat, nie problem.
  discover_log_levels: false

  # Default retention dla wszystkich strumieni bez dopasowania ponizej.
  # WARTOSCI POCHODZA Z .env — ten plik jest RENDEROWANY i force-syncowany
  # przy kazdym `make up`. Nie edytuj $BPP_CONFIGS_DIR/loki/local-config.yaml,
  # bo zmiana zniknie przy najblizszym git pull. Strojenie: LOKI_RETENTION_*
  # w $BPP_CONFIGS_DIR/.env (patrz docs/monitoring/logowanie.md).
  retention_period: __RETENTION_DEFAULT__

  # Per-stream overrides. Priority = kolejnosc dopasowania (wyzszy wygrywa).
  # Selector uzywa labela `service` ustawianego przez Alloy z
  # com.docker.compose.service (zob. defaults/alloy/config.alloy).
  retention_stream:
    - selector: '{service="appserver"}'
      priority: 1
      period: __RETENTION_APPSERVER__

    - selector: '{service="dbserver"}'
      priority: 1
      period: __RETENTION_DBSERVER__

    - selector: '{service="webserver"}'
      priority: 1
      period: __RETENTION_WEBSERVER__

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150
  delete_request_store: filesystem

ruler:
  alertmanager_url: http://localhost:9093

analytics:
  reporting_enabled: false
