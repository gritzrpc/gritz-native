#!/bin/sh
set -eu

grpcurl_version=$(awk '$1 == "grpcurl" { print $2 }' /tmp/tool-versions)
ghz_version=$(awk '$1 == "ghz" { print $2 }' /tmp/tool-versions)
case "$(dpkg --print-architecture)" in
  amd64) grpcurl_arch=x86_64; ghz_arch=x86_64 ;;
  arm64) grpcurl_arch=arm64; ghz_arch=arm64 ;;
  *) exit 1 ;;
esac
cd /tmp
curl -fLO "https://github.com/fullstorydev/grpcurl/releases/download/v${grpcurl_version}/grpcurl_${grpcurl_version}_linux_${grpcurl_arch}.tar.gz"
curl -fLO "https://github.com/fullstorydev/grpcurl/releases/download/v${grpcurl_version}/grpcurl_${grpcurl_version}_checksums.txt"
grep "grpcurl_${grpcurl_version}_linux_${grpcurl_arch}.tar.gz" "grpcurl_${grpcurl_version}_checksums.txt" | sha256sum -c -
tar -xzf "grpcurl_${grpcurl_version}_linux_${grpcurl_arch}.tar.gz" -C /usr/local/bin grpcurl
curl -fLO "https://github.com/bojand/ghz/releases/download/v${ghz_version}/ghz-linux-${ghz_arch}.tar.gz"
curl -fLO "https://github.com/bojand/ghz/releases/download/v${ghz_version}/ghz-linux-${ghz_arch}.tar.gz.sha256"
expected=$(awk '{print $1}' "ghz-linux-${ghz_arch}.tar.gz.sha256")
printf '%s  %s\n' "$expected" "ghz-linux-${ghz_arch}.tar.gz" | sha256sum -c -
tar -xzf "ghz-linux-${ghz_arch}.tar.gz" -C /usr/local/bin ghz
grpcurl -version
ghz --version
