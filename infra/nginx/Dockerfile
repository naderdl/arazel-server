FROM nginx:1.30.5-alpine@sha256:0985e772fb9f729e6fa0980da05fca5d9c468e870eed43071545afa9d2e27d94

ARG DOCKER_GEN_VERSION=0.17.2
ARG DOCKER_GEN_SHA256=d68f826715b14781edaee26dc15dd07dd648e89d4f4f6f20114a57ad2970f935

LABEL org.opencontainers.image.title="arazel-nginx" \
      org.opencontainers.image.version="nginx-1.30.5+docker-gen-${DOCKER_GEN_VERSION}" \
      org.opencontainers.image.description="Pinned stock NGINX ingress with docker-gen ${DOCKER_GEN_VERSION}"

RUN apk add --no-cache bash ca-certificates curl flock procps \
    && curl --fail --location --silent --show-error \
        "https://github.com/nginx-proxy/docker-gen/releases/download/${DOCKER_GEN_VERSION}/docker-gen-alpine-linux-amd64-${DOCKER_GEN_VERSION}.tar.gz" \
        --output /tmp/docker-gen.tar.gz \
    && echo "${DOCKER_GEN_SHA256}  /tmp/docker-gen.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/docker-gen.tar.gz -C /usr/local/bin docker-gen \
    && rm /tmp/docker-gen.tar.gz \
    && mkdir -p /run/nginx-config /run/nginx-runtime /var/www/certbot /opt/ingress /etc/docker-gen

COPY nginx.conf.tmpl /opt/ingress/nginx.conf.tmpl
COPY discovery.tmpl /etc/docker-gen/discovery.tmpl
COPY docker-gen.cfg docker-gen-once.cfg /etc/docker-gen/
COPY entrypoint.sh activate.sh controller.sh /usr/local/sbin/
COPY transparent-routing.sh /usr/local/sbin/arazel-transparent-routing
COPY certificates.sh /opt/ingress/certificates.sh

RUN chmod 0755 /usr/local/bin/docker-gen /usr/local/sbin/entrypoint.sh /usr/local/sbin/activate.sh /usr/local/sbin/controller.sh /usr/local/sbin/arazel-transparent-routing /opt/ingress/certificates.sh
EXPOSE 80/tcp 443/tcp
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
