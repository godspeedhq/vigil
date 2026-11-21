# The certificate each broker presents on the listener this pack connects
# to: how many days until it expires, and whether it is trusted (by
# KAFKA_CACERT, or the system's CAs) and names the broker. The brokers are
# those the cluster lists, as it tells clients to reach them; or
# KAFKA_TLS_ENDPOINTS, host:port, comma-separated. Without TLS: tls 0.
case $security in SSL | SASL_SSL) ;; *) [ -n "${KAFKA_TLS_ENDPOINTS-}" ] || { echo 'metric tls 0'; exit 0; } ;; esac
command -v openssl > /dev/null 2>&1 || { echo "@JOB@: openssl not found: install it to read the brokers' certificates" >&2; exit 1; }
if [ -n "${KAFKA_TLS_ENDPOINTS-}" ]; then
    eps=${KAFKA_TLS_ENDPOINTS//,/ }
else
    # The brokers as the cluster lists them; when it cannot be asked (a
    # certificate it does not trust is what this job is for), the bootstrap
    # list.
    lenient=1 brokers_list
    case $? in
        0) eps=$(printf '%s\n' "$out" | sed -n 's/^\([^ ]*:[0-9][0-9]*\) (id: .*/\1/p' | sort -u) ;;
        2) exit 0 ;;
        *) eps=${bootstrap//,/ } ;;
    esac
fi
echo 'metric tls 1'
now=$(date +%s)
hostcheck=''
openssl s_client -help 2>&1 | grep -q -- '-verify_hostname' && hostcheck=yes
n=0
for ep in $eps; do
    host=${ep%:*}
    opts=(-connect "$ep")
    case $host in
        *[!0-9.]*) opts+=(-servername "$host"); [ -n "$hostcheck" ] && opts+=(-verify_hostname "$host") ;;
        *) [ -n "$hostcheck" ] && opts+=(-verify_ip "$host") ;;
    esac
    [ -n "${KAFKA_CACERT-}" ] && opts+=(-CAfile "$KAFKA_CACERT")
    # A handshake that never ends is ended after 15 seconds.
    openssl s_client "${opts[@]}" < /dev/null > "$work/tls" 2>&1 &
    pid=$!
    ( sleep 15; kill "$pid" 2> /dev/null ) > /dev/null 2>&1 &
    dog=$!
    wait "$pid" 2> /dev/null
    # The watchdog, no longer needed, ended and waited for: bash says
    # "Terminated" of a job it reaps, on the stderr of its wait.
    kill "$dog" 2> /dev/null
    wait "$dog" 2> /dev/null
    n=$((n + 1))
    tag="endpoint=$(tagv "$ep")"
    end=$(openssl x509 -noout -enddate < "$work/tls" 2> /dev/null | sed 's/^notAfter=//')
    if [ -z "$end" ]; then
        echo "metric reachable 0 $tag"
        continue
    fi
    echo "metric reachable 1 $tag"
    end=$(printf '%s' "$end" | tr -s ' ')
    t=$(date -u -d "$end" +%s 2> /dev/null || date -u -j -f '%b %d %T %Y %Z' "$end" +%s 2> /dev/null)
    if [ -n "$t" ]; then
        echo "metric expires_days $(( (t - now) / 86400 )) $tag"
    fi
    if grep -q 'Verify return code: 0 ' "$work/tls"; then
        echo "metric trusted 1 $tag"
    else
        echo "metric trusted 0 $tag"
    fi
done
echo "metric endpoints $n"
exit 0
