# load.sh - the load averages, from /proc/loadavg.
read -r one five fifteen rest < /proc/loadavg
echo "metric load1 $one"
echo "metric load5 $five"
echo "metric load15 $fifteen"
