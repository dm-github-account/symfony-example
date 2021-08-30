FROM alpine:3.11

RUN set -ex \
  && apk add --no-cache rsync sshpass openssh-client jq httpie pwgen coreutils

RUN set -ex \
  && echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories \
  && apk add --no-cache yq

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
