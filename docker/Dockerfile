#####################
#     ARGUMENTS     #
#####################
ARG TZ_PREF="Europe/London"

ARG PG_VERSION="17.5" \
    DEB_RELEASE="trixie"


#####################
#   BASE IMAGE(S)   #
#####################
#> Postgres: Build base
FROM postgres:${PG_VERSION}-${DEB_RELEASE} AS pg-base
ARG TZ_PREF
ARG PG_VERSION

ENV TZ="${TZ_PREF}"

RUN export PG_MAJOR="$(echo "${PG_VERSION}" | sed 's/\([0-9]\{1,\}\).*$/\1/')"


#####################
#      BUILDER      #
#####################
#> Postgres: Build ext(s)
FROM pg-base AS pg-builder

RUN apt-get update -y \
    && apt-get -y upgrade \
    && apt-get install -y \
      curl build-essential libpq-dev "postgresql-server-dev-${PG_MAJOR}"

RUN cd "$(mktemp -d)" \
    && curl -L "https://github.com/fboulnois/pg_uuidv7/archive/v1.6.0.tar.gz" > pg_uuidv7.tar.gz \
    && mkdir pg_uuidv7 \
    && tar -zxf pg_uuidv7.tar.gz -C pg_uuidv7 --strip-components=1 \
    && make -f pg_uuidv7/Makefile \
    && make -f pg_uuidv7/Makefile install \
    && ls -la

RUN find /tmp -type f -atime +10 -delete


#####################
#      TARGETS      #
#####################
#> Postgres: Build target
FROM pg-base AS postgres-pipeline

## Copy ext(s)
COPY --from=pg-builder "/usr/lib/postgresql/${PG_MAJOR}/lib/pg_uuidv7.so" "/usr/lib/postgresql/${PG_MAJOR}/lib"
COPY --from=pg-builder "/usr/share/postgresql/${PG_MAJOR}/extension/pg_uuidv7.control" "/usr/share/postgresql/${PG_MAJOR}/extension"
COPY --from=pg-builder "/usr/share/postgresql/${PG_MAJOR}/extension/pg_uuidv7--1.6.sql" "/usr/share/postgresql/${PG_MAJOR}/extension"

## Copy hunspell
COPY ./docker/lang/en_gb.dict "/usr/share/postgresql/${PG_MAJOR}/tsearch_data/en_gb.dict"
COPY ./docker/lang/en_gb.affix "/usr/share/postgresql/${PG_MAJOR}/tsearch_data/en_gb.affix"

## Copy gen. ontology thesaurus
COPY ./.output/en_ontology.ths "/usr/share/postgresql/${PG_MAJOR}/tsearch_data/en_ontology.ths"

## Init DB
COPY ./docker/sql/init.lang.sql /docker-entrypoint-initdb.d/
