FROM envoyproxy/envoy:v1.31-latest

# envoy.yaml is bind-mounted at runtime (generated from envoy.yaml.tpl)

# Override the stock docker-entrypoint.sh which does chown on /dev/stdout
# and /dev/stderr — this fails under rootless Podman.
ENTRYPOINT ["envoy"]
CMD ["-c", "/etc/envoy/envoy.yaml"]

EXPOSE 10000 10001 9901
