FROM arm32v7/debian:stretch-slim

COPY build /usr/src/
WORKDIR /usr/src/

RUN dpkg --add-architecture amd64 && apt-get update && apt-get -y install --allow-downgrades --no-install-recommends ./*.deb && apt-get -y install --no-install-recommends libc6-dev libgcc1:amd64 libgomp1:amd64 libatomic1:amd64 libasan3:amd64 libubsan0:amd64 libgcc-6-dev:amd64 libisl15:amd64 libmpc3:amd64 zlib1g:amd64 && apt-get -y install build-essential && apt-get clean
