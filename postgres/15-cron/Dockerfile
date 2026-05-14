ARG PG_BASE_TAG=15-bookworm
FROM postgres:${PG_BASE_TAG}

RUN buildDeps='' && imageDeps='postgresql-15-cron' && apt update && apt install -y $imageDeps --no-install-recommends --reinstall ca-certificates

EXPOSE 5432
CMD ["postgres"]