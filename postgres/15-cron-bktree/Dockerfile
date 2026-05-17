FROM postgres:15-trixie

RUN apt update && \
    imageDeps='postgresql-15-cron' && \
    buildDeps='git make gcc postgresql-server-dev-15' && \
    apt install -y $imageDeps $buildDeps --no-install-recommends --reinstall ca-certificates && \
    git clone https://github.com/fake-name/pg-spgist_hamming.git && \
    make -C pg-spgist_hamming/bktree && \
    make -C pg-spgist_hamming/bktree install && \
    rm -rf pg-spgist_hamming && \
    apt purge -y --auto-remove $buildDeps

EXPOSE 5432
CMD ["postgres"]
