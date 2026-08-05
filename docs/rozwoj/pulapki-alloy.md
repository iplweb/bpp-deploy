# Pułapki przy edycji pipeline'u Alloy

Strona dla osoby zmieniającej `defaults/alloy/config.alloy` — plik, który
nadaje logom `detected_level` i rozkłada trafienia WAF-a na pola `modsec_*`.
Opis wyniku (słownik poziomów, retencja, tabela pól) jest osobno:
[Logowanie](../monitoring/logowanie.md).

Plik jest [force-syncowany](../konfiguracja/architektura.md#configalloy-dlaczego-force-sync)
— zmiana w repo trafia na wdrożenia przez `git pull && make up`, ale też: nikt
nie stroi go u siebie, więc nie ma tu żadnych „wartości użytkownika" do
uszanowania. To kod.

## Weryfikacja: `make test-alloy`

```bash
make test-alloy
```

Przepuszcza **prawdziwy** `config.alloy` przez **prawdziwe** linie logów
(`tests/fixtures/alloy-loglines.txt`) przez `loki.echo` i sprawdza wynikowe
etykiety. Uruchamiaj po każdej zmianie w tym pliku — wszystkie opisane niżej
błędy są dla oka niewidoczne, a ten test je łapie.

## Kolejne `stage.regex` nadpisują ten sam klucz — wygrywa OSTATNI

To jest przyczyna, dla której `detected_level` liczy się bramką, a nie łańcuchem
poprawek.

!!! bug "Plik był ułożony odwrotnie, niż zakładał jego autor"

    Detektory stały w kolejności **od najbardziej zaufanego**, co jest naturalną
    intuicją — i było dokładnie odwrotne do tego, co robi silnik. Ostatni
    detektor, najmniej wiarygodny, nadpisywał wynik pierwszego.

Dlatego obowiązuje układ:

1. każdy detektor pisze do **własnego** klucza `lvl_*` (nigdy do wspólnego),
2. jedna `stage.template` na końcu wybiera **pierwszy niepusty** w kolejności
   zaufania i mapuje go na słownik.

!!! danger "Nie dokładaj normalizacji jako kolejnego `stage.replace`"
    Nowa wartość ma dojść przez **rozszerzenie bramki**. `stage.replace`
    dopisany za nią działa poza kontrolą słownika i przywraca dokładnie ten
    problem, który układ `lvl_*` rozwiązał. Wartość spoza
    [zamkniętego zbioru siedmiu](../monitoring/logowanie.md#poziom-logu-detected_level)
    nie ma prawa trafić na label — nierozpoznana zostaje `unknown`.

## `stage.template` **zawsze** tworzy swój klucz `source`

Odwołanie do klucza, którego `stage.json` nie utworzył, nie daje pustej
wartości — renderuje **dosłowny łańcuch `<no value>`**, który potem jedzie do
Loki jako treść etykiety.

Każdy szablon dotykający pola opcjonalnego musi mieć więc jawną osłonę:

```alloy
stage.template {
  source   = "modsec_attack"
  template = "{{ if .modsec_attack }}{{ .modsec_attack }}{{ end }}"
}
```

Dotyczy to całej rodziny `modsec_*`, bo
[wpis audytowy i linia error.log nie mają tego samego zestawu pól](../architektura/waf.md#dwa-wpisy-na-jedno-zadanie).

## `\berror\b` łapie się wewnątrz ścieżki URL

Access log zawiera ścieżki takie jak `GET /raport/error-summary.html`. Granica
słowa `\b` **nie odróżnia** tego od komunikatu aplikacji, więc zwykłe żądanie
raportu było raportowane jako błąd aplikacji i zaśmiecało dashboard błędów.

Wzorzec wymaga dziś, żeby przed słowem-poziomem **nie stał `/`**. Dokładając
nowy detektor po treści linii, sprawdź go na liniach access logu z fixture'a —
nie tylko na logach Django.

## Trafienia WAF-a: dwa wpisy, piętnaście pól, zero labeli strumienia

Jedno żądanie zablokowane przez ModSecurity daje **dwa** wpisy w Loki i oba
niosą pola `modsec_*`. Rozróżnia je `modsec_src` (`audit` / `nginx`).
Konsekwencje dla agregatów i dla dashboardów są opisane przy WAF-ie:
[Dwa wpisy na jedno żądanie](../architektura/waf.md#dwa-wpisy-na-jedno-zadanie).

Dwie rzeczy, o które łatwo się potknąć **po stronie Alloya**:

- **15 pól `modsec_*` idzie do structured metadata, nigdy do labeli strumienia.**
  `modsec_uri` × `modsec_client` jako labele wysadziłyby kardynalność indeksu.
- **Poziom trafienia to `warn`, nie `error`** — ta sama decyzja co przy
  `limit_req_log_level`: powódź zdarzeń bezpieczeństwa nie ma zalewać dashboardu
  błędów aplikacji. Trafienia mają
  [własny dashboard](../monitoring/dashboardy-grafany.md#waf-modsecurity-owasp-crs).

## Jedno źródło `detected_level`

Wbudowane `discover_log_levels` w Loki jest wyłączone — inaczej dwa detektory
pod tą samą nazwą dają w Grafanie sumę dwóch słowników. Szczegóły i powód,
dla którego bliźniaczego `discover_service_name` wyłączyć się **nie da**:
[Logowanie](../monitoring/logowanie.md#poziom-logu-detected_level).

Dokładając cokolwiek, co ustawia `detected_level`, pamiętaj, że ten plik ma
pozostać jego **jedynym** producentem.
