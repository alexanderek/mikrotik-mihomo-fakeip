# Этап сборки
FROM --platform=$BUILDPLATFORM golang:alpine AS builder
ARG TARGETOS
ARG TARGETARCH
ARG TAG=v1.19.26
ARG MIHOMO_REF=fc8c5a24b16991f98cd736950c17d1aa306a5041
ARG WITH_GVISOR=0  # 1 - включить тег with_gvisor
ARG BUILDTIME
ARG AMD64VERSION

RUN test -n "$TAG" || { echo "TAG build arg must not be empty"; exit 1; }
RUN test -n "$MIHOMO_REF" || { echo "MIHOMO_REF build arg must not be empty"; exit 1; }

# Устанавливаем зависимости
RUN apk add --no-cache git make
RUN mkdir -p /final

# Клонируем репозиторий
RUN git clone https://github.com/MetaCubeX/mihomo.git /src
WORKDIR /src

# Переключаемся на pinned upstream ref и проверяем, что version tag ему соответствует.
RUN resolved_ref=$(git rev-parse "${TAG}^{commit}") && \
    test "$resolved_ref" = "$MIHOMO_REF" || { \
      echo "TAG ${TAG} resolves to ${resolved_ref}, expected pinned MIHOMO_REF ${MIHOMO_REF}"; \
      exit 1; \
    } && \
    git switch "$MIHOMO_REF" --detach
RUN echo "Updating version.go with TAG=${TAG}-fakeip-ros and BUILDTIME=${BUILDTIME}" && \
    sed -i "s|Version\s*=.*|Version = \"${TAG}-fakeip-ros\"|" constant/version.go && \
    sed -i "s|BuildTime\s*=.*|BuildTime = \"${BUILDTIME}\"|" constant/version.go

# Формируем список build tags и собираем
RUN BUILD_TAGS="" && \
    if [ "$WITH_GVISOR" = "1" ]; then BUILD_TAGS="with_gvisor"; fi && \
    echo "Building with tags: $BUILD_TAGS" && \
    if [ "$TARGETARCH" = "amd64" ]; then \
        echo "Setting GOAMD64=$AMD64VERSION for amd64"; \
        CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOAMD64=$AMD64VERSION \
        go build -tags "$BUILD_TAGS" -trimpath -ldflags "-w -s -buildid=" -o /final/mihomo .; \
    else \
        CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
        go build -tags "$BUILD_TAGS" -trimpath -ldflags "-w -s -buildid=" -o /final/mihomo .; \
    fi

COPY entrypoint.sh /final/entrypoint.sh
RUN chmod +x /final/entrypoint.sh /final/mihomo

# Финальный образ
FROM alpine:latest
ARG TARGETARCH
COPY --from=builder /final /
RUN if [ "$TARGETARCH" = "arm64" ] || [ "$TARGETARCH" = "amd64" ]; then \
        apk add --no-cache tzdata ca-certificates iptables iptables-legacy nftables; \
    elif [ "$TARGETARCH" = "arm" ]; then \
        apk add --no-cache tzdata ca-certificates iptables iptables-legacy; \
    else \
        echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi && \
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore && \
    ln -s /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -s /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore;
ENTRYPOINT ["/entrypoint.sh"]
