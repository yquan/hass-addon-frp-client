#!/usr/bin/env bashio
WAIT_PIDS=()
CONFIG_PATH='/share/frpc.toml'
DEFAULT_CONFIG_PATH='/frpc.toml'

function toml_string() {
    jq -Rn --arg value "$1" '$value'
}

function stop_frpc() {
    bashio::log.info "Shutdown frpc client"
    if [[ ${#WAIT_PIDS[@]} -gt 0 ]]; then
        kill -15 "${WAIT_PIDS[@]}" 2>/dev/null || true
    fi
}

bashio::log.info "Copying configuration."
cp $DEFAULT_CONFIG_PATH $CONFIG_PATH
sed -i "s/serverAddr = \"your_server_addr\"/serverAddr = \"$(bashio::config 'serverAddr')\"/" $CONFIG_PATH
sed -i "s/serverPort = 7000/serverPort = $(bashio::config 'serverPort')/" $CONFIG_PATH
sed -i "s/auth.token = \"123456789\"/auth.token = \"$(bashio::config 'authToken')\"/" $CONFIG_PATH
sed -i "s/webServer.port = 7500/webServer.port = $(bashio::config 'webServerPort')/" $CONFIG_PATH
sed -i "s/webServer.user = \"admin\"/webServer.user = \"$(bashio::config 'webServerUser')\"/" $CONFIG_PATH
sed -i "s/webServer.password = \"123456789\"/webServer.password = \"$(bashio::config 'webServerPassword')\"/" $CONFIG_PATH
sed -i "s/customDomains = \[\"your_domain\"\]/customDomains = [\"$(bashio::config 'customDomain')\"]/" $CONFIG_PATH
sed -i "s/name = \"your_proxy_name\"/name = \"$(bashio::config 'proxyName')\"/" $CONFIG_PATH

extra_proxies=$(bashio::config 'extraProxies' '{"name":"app-8099","protocol":"tcp","localPort":8099,"remotePort":8099}')
printf "%s\n" "${extra_proxies}" | while read -r proxy; do
    proxy_name=$(bashio::jq "${proxy}" '.name // empty')
    protocol=$(bashio::jq "${proxy}" '.protocol // "tcp"')
    local_port=$(bashio::jq "${proxy}" '.localPort // empty')
    remote_port=$(bashio::jq "${proxy}" '.remotePort // empty')
    custom_domain=$(bashio::jq "${proxy}" '.customDomain // empty')

    if [[ -z "${proxy_name}" || -z "${local_port}" ]]; then
        bashio::log.warning "Skipping proxy with missing name or localPort"
        continue
    fi

    case "${protocol}" in
        tcp|udp)
            if [[ -z "${remote_port}" ]]; then
                bashio::log.warning "Skipping ${proxy_name}: ${protocol} proxies require remotePort"
                continue
            fi

            cat >> $CONFIG_PATH <<EOF

[[proxies]]
name = $(toml_string "$(bashio::config 'proxyName')-${proxy_name}")
type = "${protocol}"
transport.useEncryption = true
transport.useCompression = true
localPort = ${local_port}
localIP = "0.0.0.0"
remotePort = ${remote_port}
EOF
            ;;
        http|https)
            if [[ -z "${custom_domain}" ]]; then
                custom_domain=$(bashio::config 'customDomain')
            fi

            cat >> $CONFIG_PATH <<EOF

[[proxies]]
name = $(toml_string "$(bashio::config 'proxyName')-${proxy_name}")
type = "${protocol}"
customDomains = [$(toml_string "${custom_domain}")]
transport.useEncryption = true
transport.useCompression = true
localPort = ${local_port}
localIP = "0.0.0.0"
EOF
            ;;
        *)
            bashio::log.warning "Skipping ${proxy_name}: unsupported protocol '${protocol}'"
            continue
            ;;
    esac
done

bashio::log.info "Starting frp client"

cat $CONFIG_PATH

cd /usr/src
./frpc -c $CONFIG_PATH & WAIT_PIDS+=($!)

tail -f /share/frpc.log &

trap "stop_frpc" SIGTERM SIGHUP
wait "${WAIT_PIDS[@]}"
