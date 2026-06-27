# Consumed by Ansible: the inventory (one server, N agents) and the kubeconfig server rewrite.
output "server_public_ip" {
  description = "Public IP of the k3s server — SSH target and kubeconfig API endpoint."
  value       = module.compute.server_public_ip
}

output "server_private_ip" {
  description = "Private IP of the k3s server — agents join over this."
  value       = module.compute.server_private_ip
}

output "worker_public_ips" {
  description = "Public IPs of the worker nodes — SSH targets."
  value       = module.compute.worker_public_ips
}

output "worker_private_ips" {
  description = "Private IPs of the worker nodes."
  value       = module.compute.worker_private_ips
}
