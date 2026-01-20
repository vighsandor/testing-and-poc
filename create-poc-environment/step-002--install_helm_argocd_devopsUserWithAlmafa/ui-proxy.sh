kubectl port-forward -n argocd svc/argocd-server --address 0.0.0.0 8080:443 > /dev/null 2>&1 &
PF_PID=$!
echo "Port-forward aktív (PID: $PF_PID)"
