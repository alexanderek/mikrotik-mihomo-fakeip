# mikrotik-mihomo-fakeip

> Поддерживаемый форк архивированного исходного проекта. Репозиторий продолжает
> сопровождение контейнерной обвязки, а Mihomo при сборке берётся из
> [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo).

Репозиторий собирает Mihomo со встроенной генерацией конфигурации для запуска
в контейнере MikroTik RouterOS. Контейнер выдаёт fake-IP через DNS, принимает
возвращённый на него трафик в режиме TUN или TPROXY и передаёт его напрямую.
Настройка конкретного маршрутизатора и его фактическое состояние не являются
источником истины этого репозитория.

## Модель релиза

У релиза нет автоматически выбранной «последней» версии upstream. Исходный код
каждой сборки задаётся обязательной парой ручных входов workflow
`.github/workflows/manual_push.yml`:

- `mihomo_tag` — стабильный тег upstream строго в формате `vX.Y.Z`;
- `mihomo_ref` — полный 40-символьный lowercase SHA коммита, на который должен
  разрешаться этот тег.

`Dockerfile` разрешает именно `refs/tags/<mihomo_tag>^{commit}` и прекращает
сборку, если тег отсутствует, SHA имеет неверный формат или пара не совпадает.
В собранный образ записываются OCI labels `org.opencontainers.image.version`
и `org.opencontainers.image.revision`.

Последняя пара, которую можно подтвердить только локальной историей этого
репозитория (`Dockerfile` в теге репозитория `v0.1.2`):

```text
v1.19.26
fc8c5a24b16991f98cd736950c17d1aa306a5041
```

Это запись в metadata репозитория, а не утверждение о текущем содержимом
upstream или GHCR. Для нового релиза оператор отдельно проверяет актуальную
пару и явно вводит оба значения.

Workflow публикует только два адресуемых тега одного multi-arch manifest:

```text
ghcr.io/alexanderek/mikrotik-mihomo-fakeip:<mihomo_tag>
ghcr.io/alexanderek/mikrotik-mihomo-fakeip:sha-<full_mihomo_ref>
```

Перед публикацией workflow проверяет отсутствие обоих тегов в GHCR и
останавливается, если тег уже есть или его отсутствие нельзя
доказать. Тег `latest` не создаётся и для развёртывания не используется.

### Ручной выпуск и проверка

1. В upstream определите стабильный `vX.Y.Z` и полный SHA коммита, на который
   разрешается этот тег. Не используйте branch, сокращённый SHA или prerelease.
2. Запустите `Manual Build and Publish Multi-Arch Docker Images` через
   `workflow_dispatch` и введите оба значения без преобразований.
3. Убедитесь, что шаг `Validate release inputs` завершился успешно, а сборка не
   сообщила `does not resolve` или `expected MIHOMO_REF`.
4. После публикации проверьте, что version-тег и `sha-<full_mihomo_ref>` указывают
   на один manifest digest, а OCI labels содержат введённые version и revision.
5. Для развёртывания закрепляйте точный version-тег (`vX.Y.Z`), как везде в
   HL: workflow не перевыпускает существующий тег, поэтому он неизменяем.
   `sha-<full_mihomo_ref>` указывает на ту же сборку и тоже годится.

После публикации workflow анализирует GHCR и при `DELETE_UNTAGGED=true` удаляет
версии пакета без тега, которые не распознаны как manifest или его дочерний
digest. Manifest с тегом и связанные с ним platform images не удаляются.
Удаление происходит на стороне GHCR и не откатывается; ошибка чтения списка
пакетов или manifest с тегом останавливает очистку, а непрочитанная версия без
тега в список удаления не попадает.

Обновление выполняется выпуском новой проверенной пары, проверкой нового образа
в безопасном контуре и явной заменой закреплённого SHA/digest в принадлежащей
маршрутизатору конфигурации. Для отката верните предыдущий сохранённый
`sha-<full_mihomo_ref>` или digest; повторный push поверх прежнего тега workflow
запрещает.

### Локальная проверка исходников

Проверка не требует RouterOS, Docker или доступа к upstream. Она читает
shell-код и синтетически запускает генерацию конфигурации:

```bash
shellcheck entrypoint.sh tests/entrypoint-smoke.sh
tests/entrypoint-smoke.sh
```

`shellcheck` обязателен в CI, локально может отсутствовать; пропущенный
`shellcheck` — не пройденная проверка. Smoke-тест работает на локальных
заглушках, проверяет `tun`/`tproxy`, политики QUIC, фильтр fake-IP,
`NAMESERVER_POLICY` и отказ при некорректной политике.

## Переменные окружения

Контейнер поддерживает следующие переменные:

| Переменная | Назначение | Значение по умолчанию | Пример |
|---|---|---|---|
| `FAKE_IP_RANGE` | Пул fake-IP для `dns.fake-ip-range` | `198.18.0.0/15` | `198.18.0.0/15` |
| `FAKE_IP_TTL` | TTL fake-IP для `dns.fake-ip-ttl` | `1` | `60` |
| `LOGLEVEL` | Значение `log-level` в конфигурации Mihomo | `error` | `warning` |
| `FAKE_IP_FILTER` | Необязательный CSV-список для YAML-массива `dns.fake-ip-filter` | пусто | `localhost,*.lan,*.local` |
| `NAMESERVER_POLICY` | Необязательный CSV-список `domain#dns` для `dns.nameserver-policy` | пусто | `*.example.com#tls://9.9.9.9:853` |
| `BLOCK_QUIC` | Необязательная политика блокировки UDP/443 в правилах Mihomo | `off` | `youtube` |
| `INBOUND_MODE` | Режим входящего трафика: `auto`, `tun` или `tproxy` | `auto` | `tproxy` |

`198.18.0.0/15` — зарезервированный RFC2544 диапазон для тестов и стандартный
fake-IP pool Mihomo. Не используйте для fake-IP диапазоны RFC1918, например
`10.0.0.0/8`: они могут пересечься с адресами LAN или VPN.

Фиксированные DNS-параметры, которые генерирует `entrypoint.sh`:

- `dns.listen: 0.0.0.0:53`;
- `dns.enhanced-mode: fake-ip`;
- `dns.default-nameserver: [8.8.8.8, 9.9.9.9, 1.1.1.1]`;
- `ipv6: false`.

## Контракт DNS listener

Контейнер слушает DNS на `0.0.0.0:53`. В режиме `enhanced-mode: fake-ip`
запросы, переданные downstream DNS forwarder, получают адреса из
`FAKE_IP_RANGE`.

DNS forwarder и проверки должны обращаться к IP контейнерного интерфейса и
ожидать fake-IP внутри `FAKE_IP_RANGE`.

Интеграция с WG egress failover помещает контейнер в одну egress routing table
и документирована отдельно в репозитории `wg-failover`.

## NAMESERVER_POLICY

Формат:

```bash
NAMESERVER_POLICY="domain1#dns1,domain2#dns2"
```

- Элементы разделяются запятыми.
- Внутри элемента ровно один `#` отделяет `domain` от upstream `dns`.
- Пустые `domain` и `dns` отклоняются при старте контейнера.
- Допустимые примеры upstream: `1.1.1.1`, `tls://9.9.9.9:853`.

```bash
NAMESERVER_POLICY="*.example.com#tls://9.9.9.9:853"
NAMESERVER_POLICY="service.example#tls://9.9.9.9:853,updates.example.net#tls://9.9.9.9:853"
NAMESERVER_POLICY="video.example#1.1.1.1,*.example.org#1.1.1.1"
```

Некорректный элемент `NAMESERVER_POLICY` останавливает запуск вместо генерации
невалидной конфигурации.

## BLOCK_QUIC

`BLOCK_QUIC` управляет необязательными reject-правилами UDP/443. По умолчанию
политика отключена и не участвует в выборе failover.

- `off` — не блокировать QUIC;
- `youtube` — блокировать UDP/443 только для
  `DOMAIN-SUFFIX,googlevideo.com`, чтобы трафик мог перейти на TCP;
- `all` — блокировать весь UDP/443.

Политика одинакова для режимов `tun` и `tproxy`.

## INBOUND_MODE

- `auto` — выбрать `tproxy`, если внутри контейнера виден `nft_tproxy`, иначе
  выбрать `tun`;
- `tun` — принудительно использовать TUN;
- `tproxy` — принудительно использовать nftables TPROXY.

Перед запуском Mihomo entrypoint выбирает нужный набор `iptables-legacy` или
`nftables`. Если пакета нет в образе, он выполняет `apk add`; при переходе на
`nftables` удаляет `iptables` и `iptables-legacy`. Поэтому такой старт зависит
от доступности репозитория пакетов Alpine и завершается ошибкой, если сменить
пакеты не удалось.

В режиме `tproxy` каждый старт выполняет `nft flush ruleset` внутри контейнера,
затем создаёт собственную таблицу `mihomo_tproxy`, policy routing rule и local
route. Не размещайте в том же контейнере независимые nftables rules: entrypoint
их удалит. Для отката верните предыдущий закреплённый тег или digest образа;
настройки конкретного RouterOS живут в каталоге роутера.

## Настройка RouterOS

Настройка роутера в этом репозитории не хранится: она живёт в репозитории
состояния роутеров рядом с его `operations.md`. Интеграция с failover описана в
репозитории `wg-failover`. Образ закрепляйте по точному version-тегу
(допустим и `sha-<full_mihomo_ref>`), не по `latest`.

## Проверка контейнера

1. Убедитесь, что контейнер запущен.
2. Проверьте наличие сгенерированного `/root/.config/mihomo/config.yaml` без
   публикации его потенциально чувствительного содержимого.
3. Если задан `NAMESERVER_POLICY`, убедитесь, что запуск не завершился ошибкой
   валидации.
4. С клиентского устройства запросите через DNS маршрутизатора тестовый домен,
   который попадает под `type=FWD`, и проверьте, что ответ находится внутри
   `FAKE_IP_RANGE`.
5. Для HTTP end-to-end проверки можно использовать `neverssl.com`: он работает
   по plain HTTP и не добавляет неоднозначности от HTTPS redirect или CDN.

Пример прямого запроса к контейнеру и HTTP-запроса на полученный fake-IP:

```routeros
:put [:resolve neverssl.com server=<CONTAINER_IP>]
/tool/fetch url="http://<FAKE_IP>/" http-header-field="Host: neverssl.com" output=none duration=15s
```

Полученный адрес должен входить в `FAKE_IP_RANGE`, а логи Mihomo — содержать TCP
flow к `neverssl.com:80`.
