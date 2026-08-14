FROM grafana/mimirtool:3.1.4 AS mimirtool

FROM alpine:3.22

RUN apk add --no-cache \
    ca-certificates \
    coreutils

COPY --from=mimirtool /bin/mimirtool /usr/local/bin/mimirtool
COPY archive.sh /usr/local/bin/archive

RUN chmod +x /usr/local/bin/archive

ENTRYPOINT ["/bin/sh", "/usr/local/bin/archive"]

