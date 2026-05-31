# Netdata main config (v2.x idiom).
#
# UWAGA: ten plik jest RENDEROWANY i FORCE-SYNCOWANY z defaults/netdata/netdata.conf.tpl
# przez scripts/ensure-config-files.sh przy kazdym make up/refresh/run. NIE edytuj
# wyrenderowanej kopii w $BPP_CONFIGS_DIR/netdata/netdata.conf - zostanie nadpisana.
# Tunowalne knoby (retencja dbengine) ustawiaj przez .env (patrz nizej), a strukturalne
# zmiany w samym .tpl w repo.
#
# Bind do wszystkich interfejsow w sieci Dockera (nginx dosiega
# po nazwie DNS `netdata:19999`). Port nie jest expose-owany na hosta.
[global]
    run as user = netdata

[db]
    # Domyslna rozdzielczosc 1s.
    update every = 1
    # dbengine = on-disk time-series, przezywa restart kontenera.
    mode = dbengine
    # Limit przestrzeni dla tier 0 (najwyzsza rozdzielczosc), w MB.
    # 512 = ~2-3 tygodnie danych przy ~20 kontenerach. Strojenie:
    # NETDATA_DBENGINE_TIER0_RETENTION_MB w .env (przezywa force-sync).
    dbengine tier 0 retention size = __DBENGINE_TIER0_RETENTION_MB__
    # Page cache w RAM (MB) - 32 wystarcza dla naszej skali. Strojenie:
    # NETDATA_DBENGINE_PAGE_CACHE_MB w .env.
    dbengine page cache size = __DBENGINE_PAGE_CACHE_MB__

[web]
    bind to = 0.0.0.0:19999
    # ACL: wpuszczamy tylko sieci Dockera + localhost. Reverse-proxy
    # (nginx) zywa po Docker bridge IP (172.*).
    allow connections from = localhost 10.* 172.* 192.168.*
    allow dashboard from = localhost 10.* 172.* 192.168.*
    # Badges/streaming zawezone do sieci Dockera + localhost (jak reszta ACL).
    # To single-agent deployment - brak topologii parent/child, wiec streaming
    # nie jest nikomu potrzebny z zewnatrz; '*' pozwalalby kazdemu kontenerowi
    # w sieci wstrzykiwac metryki.
    allow badges from = localhost 10.* 172.* 192.168.*
    allow streaming from = localhost
    allow netdata.conf from = localhost

[registry]
    # Lokalny rejestr wlasnego node'a. Wlaczony PO TO, by przycisk "View node"
    # w powiadomieniu ntfy przekierowywal do TEJ netdaty (https://<host>/netdata),
    # a nie do publicznego registry.my-netdata.io. Skrypt powiadomien Netdaty
    # buduje link jako ${NETDATA_REGISTRY_URL}/registry-alert-redirect.html, gdzie
    # NETDATA_REGISTRY_URL = `registry to announce`. Singl-node = ten sam host jest
    # i rejestrem, i jedynym wezlem (standardowy self-hosted registry pattern).
    #
    # Rozwiazanie URL-a wymaga, byś przynajmniej raz odwiedzil dashboard
    # (https://<host>/netdata/) z tej przegladarki, w ktorej ntfy otwiera link -
    # rejestr zapisuje wtedy URL dla Twojego cookie. Dostep i tak jest za auth proxy.
    #
    # Host ponizej podstawiany host-side z DJANGO_BPP_HOSTNAMES[0] /
    # DJANGO_BPP_HOSTNAME. Gdy brak hosta w .env -> enabled=no + announce na
    # registry.my-netdata.io (degradacja do zachowania sprzed tej zmiany).
    enabled = __REGISTRY_ENABLED__
    registry to announce = __REGISTRY_ANNOUNCE__
    registry hostname = __REGISTRY_HOSTNAME__

[health]
    enabled = yes
