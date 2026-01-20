kubectl port-forward -n gw-poc-app svc/poc-app-only-webui --address 0.0.0.0 8081:80 > /dev/null 2>&1 &
PF_PID=$!
echo "Port-forward aktív (PID: $PF_PID)"
