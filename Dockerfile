FROM gliderlabs/alpine:edge

VOLUME /var/acme-webroot

RUN \
  apk --no-cache upgrade \
  && apk --no-cache add certbot bash

ENV \
  LE_EMAIL="" \
  LE_RSA_KEY_SIZE=4096 \
  LE_EXTRA_ARGS=""

COPY root/ /

ENTRYPOINT "/entrypoint.sh"
CMD ["help"]
