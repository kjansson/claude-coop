admin:
  address:
    socket_address:
      address: 0.0.0.0
      port_value: 9901

static_resources:
  listeners:
    # ──────────────────────────────────────────────
    # HTTP listener (port 10000)
    # Lua filter enforces domain whitelist, then
    # dynamic forward proxy resolves Host header.
    # ──────────────────────────────────────────────
    - name: http_listener
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 10000
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: http_outbound
                use_remote_address: false
                route_config:
                  name: http_route
                  virtual_hosts:
                    - name: forward
                      domains: ["*"]
                      routes:
                        - match:
                            prefix: "/"
                          route:
                            cluster: dynamic_forward_proxy_cluster_http
                            timeout: 30s
                http_filters:
                  # 1. Whitelist check
                  - name: envoy.filters.http.lua
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
                      default_source_code:
                        inline_string: |
                          local allowed = {
{{LUA_ALLOWED_DOMAINS}}
                          }

                          local wildcard_suffixes = {
{{LUA_WILDCARD_SUFFIXES}}
                          }

                          function check(domain)
                            local host = domain:match("^([^:]+)")
                            if allowed[host] then return true end
                            for _, suffix in ipairs(wildcard_suffixes) do
                              if host:sub(-#suffix) == suffix then return true end
                            end
                            return false
                          end

                          function envoy_on_request(handle)
                            local host = handle:headers():get(":authority")
                                      or handle:headers():get("host")
                            if not host or not check(host) then
                              handle:logWarn("BLOCKED HTTP -> " .. (host or "unknown"))
                              handle:respond({[":status"] = "403"},
                                "Blocked: " .. (host or "unknown"))
                            else
                              handle:logInfo("ALLOWED HTTP -> " .. host)
                            end
                          end
                  # 2. Dynamic forward proxy (resolves Host to upstream)
                  - name: envoy.filters.http.dynamic_forward_proxy
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.dynamic_forward_proxy.v3.FilterConfig
                      dns_cache_config:
                        name: dns_cache_http
                        dns_lookup_family: V4_ONLY
                  # 3. Router
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

    # ──────────────────────────────────────────────
    # HTTPS listener (port 10001) – TLS passthrough
    # tls_inspector reads SNI from ClientHello.
    # Only whitelisted SNI names are forwarded;
    # everything else hits the blackhole cluster.
    # ──────────────────────────────────────────────
    - name: https_listener
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 10001
      listener_filters:
        - name: envoy.filters.listener.tls_inspector
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.listener.tls_inspector.v3.TlsInspector
      filter_chains:
        # Whitelisted domains – forwarded via SNI dynamic forward proxy
        - filter_chain_match:
            server_names:
{{SNI_SERVER_NAMES}}
          filters:
            - name: envoy.filters.network.sni_dynamic_forward_proxy
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.sni_dynamic_forward_proxy.v3.FilterConfig
                dns_cache_config:
                  name: dns_cache_https
                  dns_lookup_family: V4_ONLY
                port_value: 443
            - name: envoy.filters.network.tcp_proxy
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
                stat_prefix: https_passthrough
                cluster: dynamic_forward_proxy_cluster_https
                access_log:
                  - name: envoy.access_loggers.stdout
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
                      log_format:
                        text_format: "[%START_TIME%] ALLOWED HTTPS SNI=%REQUESTED_SERVER_NAME% -> %UPSTREAM_HOST% tx=%BYTES_SENT% rx=%BYTES_RECEIVED% dur=%DURATION%ms\n"
        # Default chain – blocked (no SNI match)
        - filters:
            - name: envoy.filters.network.tcp_proxy
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
                stat_prefix: https_blocked
                cluster: blackhole
                access_log:
                  - name: envoy.access_loggers.stdout
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
                      log_format:
                        text_format: "[%START_TIME%] BLOCKED HTTPS SNI=%REQUESTED_SERVER_NAME% dur=%DURATION%ms\n"

  clusters:
    # ── HTTP dynamic forward proxy cluster ───────
    - name: dynamic_forward_proxy_cluster_http
      lb_policy: CLUSTER_PROVIDED
      cluster_type:
        name: envoy.clusters.dynamic_forward_proxy
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.clusters.dynamic_forward_proxy.v3.ClusterConfig
          dns_cache_config:
            name: dns_cache_http
            dns_lookup_family: V4_ONLY

    # ── HTTPS dynamic forward proxy cluster ──────
    - name: dynamic_forward_proxy_cluster_https
      lb_policy: CLUSTER_PROVIDED
      cluster_type:
        name: envoy.clusters.dynamic_forward_proxy
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.clusters.dynamic_forward_proxy.v3.ClusterConfig
          dns_cache_config:
            name: dns_cache_https
            dns_lookup_family: V4_ONLY

    # ── Blackhole – rejects blocked connections ──
    - name: blackhole
      type: STATIC
      connect_timeout: 0.25s
      load_assignment:
        cluster_name: blackhole
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: 127.0.0.1
                      port_value: 1
