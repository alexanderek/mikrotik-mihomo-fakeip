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
fail-closed завершает работу при существующем теге или если отсутствие нельзя
доказать. Mutable-тег `latest` не создаётся и не является контрактом
развёртывания.

### Ручной выпуск и проверка

1. В upstream определите стабильный `vX.Y.Z` и полный SHA коммита, на который
   разрешается этот тег. Не используйте branch, сокращённый SHA или prerelease.
2. Запустите `Manual Build and Publish Multi-Arch Docker Images` через
   `workflow_dispatch` и введите оба значения без преобразований.
3. Убедитесь, что шаг `Validate release inputs` завершился успешно, а сборка не
   сообщила `does not resolve` или `expected MIHOMO_REF`.
4. После публикации проверьте, что version-тег и `sha-<full_mihomo_ref>` указывают
   на один manifest digest, а OCI labels содержат введённые version и revision.
5. Для развёртывания зафиксируйте `sha-<full_mihomo_ref>` либо manifest digest.
   Version-тег остаётся удобным указателем на ту же неизменяемую сборку.

Обновление выполняется выпуском новой проверенной пары, проверкой нового образа
в безопасном контуре и явной заменой закреплённого SHA/digest в принадлежащей
маршрутизатору конфигурации. Для отката верните предыдущий сохранённый
`sha-<full_mihomo_ref>` или digest; повторный push поверх прежнего тега workflow
запрещает.

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
и документирована отдельно в репозитории `wg-failover`. Таблица `fakeip` ниже —
пример самостоятельного развёртывания, а не контракт failover-интеграции.

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

## Пример конфигурации RouterOS

Следующие команды — шаблон самостоятельного развёртывания, а не описание
текущего состояния какого-либо маршрутизатора. Перед применением замените
примерные адреса и закрепите проверенный SHA-тег образа.

### 1. Создать контейнерный интерфейс

```routeros
/interface/veth/add name=fakeip address=192.168.255.1/31 gateway=192.168.255.0
/ip/address/add address=192.168.255.0/31 interface=fakeip
```

### 2. Создать DNS forwarder

```routeros
/ip/dns/forwarders/add name=fakeip dns-servers=192.168.255.1 verify-doh-cert=no
```

### 3. Добавить переменные окружения

```routeros
/container/envs
add key=FAKE_IP_RANGE list=fakeip value=198.18.0.0/15
add key=LOGLEVEL list=fakeip value=error
add key=FAKE_IP_TTL list=fakeip value=1
add key=BLOCK_QUIC list=fakeip value=off
add key=FAKE_IP_FILTER list=fakeip value="localhost,*.lan,*.local"
add key=NAMESERVER_POLICY list=fakeip value="*.example.com#tls://9.9.9.9:853"
```

### 4. Добавить контейнер с закреплённым образом

```routeros
/container/add remote-image="ghcr.io/alexanderek/mikrotik-mihomo-fakeip:sha-<FULL_40_CHARACTER_MIHOMO_REF>" envlists=fakeip interface=fakeip root-dir=Containers/fakeip start-on-boot=yes
```

В зависимости от версии RouterOS CLI может показывать `envlists` или `envlist`;
проверяйте доступный параметр через tab-completion. Workflow собирает
`linux/amd64` с `GOAMD64=v3`, а также `linux/arm64` и `linux/arm/v7`.

### 5. Добавить маршрут для fake-IP

```routeros
/ip/route/add dst-address=198.18.0.0/15 gateway=192.168.255.1
```

### 6. Исключить upstream DNS из дальнейшей маршрутизации

```routeros
/ip/firewall/address-list
add address=1.1.1.1 list=DNS
add address=9.9.9.9 list=DNS
add address=149.112.112.112 list=DNS
add address=104.16.248.249 list=DNS
add address=104.16.249.249 list=DNS
add address=8.8.8.8 list=DNS
add address=8.8.4.4 list=DNS
```

### 7. Создать routing table и mangle rules

```routeros
/routing/table/add name=fakeip fib
/ip/firewall/mangle
add action=mark-connection chain=prerouting connection-mark=no-mark dst-address-list=!DNS dst-address-type=!local new-connection-mark=fakeip src-address=192.168.255.1
add action=mark-routing chain=prerouting connection-mark=fakeip in-interface=fakeip new-routing-mark=fakeip passthrough=no
```

### 8. Передать выбранные домены в контейнер

```routeros
/ip/dns/static/add type=FWD forward-to=fakeip match-subdomain=yes name=video.example
/ip/dns/static/add type=FWD forward-to=fakeip match-subdomain=yes name=service.example
/ip/dns/static/add type=FWD forward-to=fakeip match-subdomain=yes name=updates.example.net
```

Для исходящего трафика таблице нужен маршрут через выбранный gateway:

```routeros
/ip/route/add dst-address=0.0.0.0/0 gateway=<EGRESS_GATEWAY> routing-table=fakeip
```

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
