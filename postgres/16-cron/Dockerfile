FROM postgres:16-trixie

RUN buildDeps='' && imageDeps='postgresql-16-cron' && apt update && apt install -y $imageDeps --no-install-recommends --reinstall ca-certificates

EXPOSE 5432
CMD ["postgres"]