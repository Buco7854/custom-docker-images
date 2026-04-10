FROM postgres:15-bookworm

RUN buildDeps='' && imageDeps='postgresql-15-cron' && apt update && apt install -y $imageDeps --no-install-recommends --reinstall ca-certificates

EXPOSE 5432
CMD ["postgres"]