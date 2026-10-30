# Sentinelix production image (based on `mix phx.gen.release --docker`).
#
#   docker build -t sentinelix .
#
# Images:
#   - builder: https://hub.docker.com/r/hexpm/elixir/tags
#   - runner:  https://hub.docker.com/_/debian/tags
#
# Keep ELIXIR_VERSION/OTP_VERSION in step with .tool-versions and the CI image
# in .forgejo/workflows/ci.yml. Builder and runner use the same Debian release.

ARG ELIXIR_VERSION=1.19.4
ARG OTP_VERSION=28.3
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# build-essential: C toolchain for NIFs (bcrypt_elixir); git: git deps
# (heroicons, daisyui)
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# The final image only contains the release and runtime dependencies.
FROM ${RUNNER_IMAGE} AS final

# iputils-ping: ping monitors run the system `ping`. It gets CAP_NET_RAW as a
# *permitted* file capability (no effective bit), so it can open raw sockets
# while the container has NET_RAW (Docker's default) and otherwise falls back
# to unprivileged ICMP sockets (net.ipv4.ping_group_range) instead of failing
# to start. curl: health check. tini: init process (signal forwarding,
# reaping).
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 locales ca-certificates \
    iputils-ping libcap2-bin curl tini \
  && chmod u-s /usr/bin/ping \
  && setcap cap_net_raw+p /usr/bin/ping \
  && apt-get purge -y libcap2-bin \
  && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"
ENV PORT=4000

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/sentinelix ./

USER nobody

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/healthz" > /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]

# Runs pending migrations (unless SKIP_MIGRATIONS=true), then the server.
CMD ["/app/bin/start"]
