
kubectl  get pods -n keycloak 
kubectl  delete pvc postgresql -n keycloak 
kubectl delete pv postgresql

#kubectl  apply -f pv.yaml
kubectl apply -f pvc.yaml
kubectl delete pod postgresql-0
